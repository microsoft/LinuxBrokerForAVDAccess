"""2.3 sessions and users against the real stored procedures and driver."""

import json


def _checkout(client, username, avdhost="avd-01"):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost})


def _heartbeat(client, hostname, sessions):
    response = client.post(f"/api/hosts/{hostname}/heartbeat", data=json.dumps({"agentVersion": "1.1.0", "sessions": sessions}),
                           content_type="application/json")
    assert response.status_code == 200, response.get_json()


def _states(client):
    return {(s["Hostname"], s["Username"]): s for s in client.get("/api/sessions").get_json()["Sessions"]}


def test_a_session_moves_from_connecting_to_active_and_is_released_by_sign_out(client, db, remote):
    db.add_vm("lnxhost-01")
    assert _checkout(client, "alice").status_code == 200

    _heartbeat(client, "lnxhost-01", [])
    assert _states(client)[("lnxhost-01", "alice")]["State"] == "connecting"

    _heartbeat(client, "lnxhost-01", [{"username": "alice", "state": "active", "idleSeconds": 5}])
    active = _states(client)[("lnxhost-01", "alice")]
    assert active["State"] == "active" and active["IdleSeconds"] == 5 and active["AssignedForSeconds"] is not None

    signed_out = client.post("/api/sessions/lnxhost-01/alice/signout", json={})
    assert signed_out.status_code == 200, signed_out.get_json()
    assert signed_out.get_json()["Released"] is True
    assert db.vm("lnxhost-01")["VmStatus"] == "Released"

    _heartbeat(client, "lnxhost-01", [])
    released = _states(client)[("lnxhost-01", "alice")]
    assert released["State"] == "released" and 1100 <= released["GraceRemainingSeconds"] <= 1200


def test_sign_out_and_return_frees_the_host(client, db, remote):
    db.add_vm("lnxhost-01")
    _checkout(client, "bob")
    _heartbeat(client, "lnxhost-01", [{"username": "bob", "state": "disconnected"}])

    body = client.post("/api/sessions/lnxhost-01/bob/signout", json={"returnHost": True}).get_json()

    assert body["Returned"] is True and body["CleanupResult"] == "Completed", body
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Available" and vm["Username"] is None and vm["CleanupPending"] is False
    assert [kind for _, kind in remote.calls][-3:] == ["signout", "clear", "userdel"]


def test_a_requested_profile_reset_is_applied_at_the_next_new_assignment(client, db, remote):
    db.add_vm("lnxhost-01")
    first = _checkout(client, "carol").get_json()

    requested = client.post("/api/users/carol/reset-profile", json={"confirm": "carol"})
    assert requested.status_code == 200 and requested.get_json()["CurrentlyAssigned"] is True
    assert client.get("/api/users/carol").get_json()["ProfileReset"]["RequestedAtUtc"].endswith("Z")

    # A reconnect to the same host does not apply it.
    _checkout(client, "carol")
    assert "reset-profile" not in [kind for _, kind in remote.calls]

    returned = client.post(f"/api/vms/{first['VMID']}/return")
    assert returned.status_code == 200, returned.get_json()

    remote.calls.clear()
    assert _checkout(client, "carol").status_code == 200
    kinds = [kind for _, kind in remote.calls]
    assert kinds.index("reset-profile") < kinds.index("create")

    details = client.get("/api/users/carol").get_json()
    assert details["ProfileReset"] is None and details["Uid"] >= 2000
    assert [h["Hostname"] for h in details["HostHistory"]] == ["lnxhost-01"]
    applied = db.one("SELECT Outcome, DetailJson FROM dbo.AuditLog WHERE Action='user.reset_profile_applied'")
    assert applied["Outcome"] == "success" and json.loads(applied["DetailJson"])["renamedTo"] == "renamed"


def test_a_reset_left_pending_when_the_host_agent_is_old(client, db, remote):
    db.add_vm("lnxhost-01")
    db.run("INSERT INTO dbo.VmUsers (uid, username) VALUES (4100, 'dave')")
    client.post("/api/users/dave/reset-profile", json={"confirm": "dave"})
    remote.reply("reset-profile", 1, "", "sudo: a password is required\n")

    assert _checkout(client, "dave").status_code == 200
    assert db.one("SELECT ProfileResetRequestedAt FROM dbo.VmUsers WHERE username='dave'")["ProfileResetRequestedAt"] is not None


def test_user_search_finds_provisioned_users(client, db, remote):
    db.add_vm("lnxhost-01")
    _checkout(client, "erin")
    found = client.get("/api/users?q=eri").get_json()["Users"]
    assert found[0]["Username"] == "erin" and found[0]["CurrentHostname"] == "lnxhost-01"


def test_a_broadcast_reaches_the_hosts_in_use(client, db, remote):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02")
    db.add_vm("lnxhost-03")
    _checkout(client, "frank")
    _heartbeat(client, "lnxhost-02", [{"username": "admin1", "state": "active"}])

    body = client.post("/api/sessions/broadcast", json={"message": "Maintenance at 18:00"}).get_json()

    assert body["TargetCount"] == 2, body
    messaged = sorted(hostname for hostname, kind in remote.calls if kind == "message-all")
    assert messaged == ["lnxhost-01", "lnxhost-02"]
    assert "Maintenance at 18:00" in remote.stdin
