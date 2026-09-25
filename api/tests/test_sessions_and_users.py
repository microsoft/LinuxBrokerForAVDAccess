"""2.3 sessions and users: the Sessions reader, user search and details, sign-out, messages,
and profile resets requested in the portal and applied at checkout."""

import json
import types

import pytest


LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"
ADMIN_USER = {"roles": ["FullAccess"], "scp": "access_as_user", "oid": "oid-alice", "preferred_username": "alice@contoso.com"}
OPERATOR_USER = {"roles": ["Operator"], "scp": "access_as_user", "oid": "oid-olga", "preferred_username": "olga@contoso.com"}
READER_USER = {"roles": ["Reader"], "scp": "access_as_user", "oid": "oid-rita", "preferred_username": "rita@contoso.com"}


class Host:
    """Stands in for run_remote_command, answering each command with (returncode, stdout, stderr)."""

    def __init__(self, *responses, default=(0, "", "")):
        self.calls = []
        self._responses = list(responses)
        self._default = default

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        self.calls.append({"hostname": hostname, "command": command, "stdin": stdin_input, "timeout": timeout})
        returncode, stdout, stderr = self._responses.pop(0) if self._responses else self._default
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr), f"avdadmin@{hostname}"

    @property
    def commands(self):
        return [call["command"] for call in self.calls]


@pytest.fixture
def host(app_module, monkeypatch):
    fake = Host()
    monkeypatch.setattr(app_module, "run_remote_command", fake)
    return fake


def script(host, *responses):
    host._responses = list(responses)
    return host


def session_row(hostname, username, **values):
    row = {
        "VMID": 1, "Hostname": hostname, "Username": username, "AvdHost": "avd-01", "VmStatus": "CheckedOut",
        "PowerState": "On", "NetworkStatus": "Reachable", "DrainRequested": False, "HasAssignment": True,
        "BrokerTracked": True, "CleanupPending": False, "SessionState": "active", "SessionStartEpoch": 1790000000,
        "DisconnectedSinceEpoch": None, "DisconnectedForSeconds": None, "IdleSeconds": 12,
        "AssignedForSeconds": 600, "LastCheckoutAgeSeconds": 600, "GraceRemainingSeconds": None,
        "HeartbeatAgeSeconds": 20, "GracePeriodSeconds": 1200, "ReconcileIntervalSeconds": 60,
    }
    row.update(values)
    return row


VM = {
    "VMID": 5, "Hostname": "lnx-05", "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "CheckedOut",
    "Username": "bob", "LeaseId": LEASE_ID, "CleanupPending": False, "CleanupUsername": None, "DrainRequested": False,
}


def procs(fake_db):
    return [call["proc"] for call in fake_db.calls]


# ------------------------------------------------------------------------ reading


def test_sessions_are_given_a_state_an_operator_can_act_on(client, fake_db):
    fake_db.fetchall_rows["GetSessions"] = [
        session_row("h-active", "active1"),
        session_row("h-disc", "disc1", SessionState="disconnected", DisconnectedForSeconds=90),
        session_row("h-rel", "rel1", VmStatus="Released", SessionState=None, GraceRemainingSeconds=-5),
        session_row("h-conn", "conn1", SessionState=None, LastCheckoutAgeSeconds=30),
        session_row("h-stuck", "stuck1", SessionState=None, LastCheckoutAgeSeconds=3600),
        session_row("h-clean", "clean1", CleanupPending=True, HasAssignment=False, SessionState="active"),
        session_row("h-free", "mallory", HasAssignment=False, BrokerTracked=False, VmStatus="Available"),
        session_row("h-stale", "stale1", HeartbeatAgeSeconds=900),
        session_row("h-stale2", "ghost", HasAssignment=False, BrokerTracked=False, HeartbeatAgeSeconds=900),
    ]

    body = client.get("/api/sessions").get_json()

    states = {s["Username"]: s["State"] for s in body["Sessions"]}
    assert states == {
        "active1": "active", "disc1": "disconnected", "rel1": "released", "conn1": "connecting",
        "stuck1": "not-connected", "clean1": "cleanup-pending", "mallory": "unmanaged",
        "stale1": "unknown", "ghost": "unknown",
    }
    released = next(s for s in body["Sessions"] if s["Username"] == "rel1")
    assert released["GraceRemainingSeconds"] == 0
    active = body["Sessions"][0]
    assert active["SessionStartUtc"] == "2026-09-21T14:13:20Z" and active["HeartbeatFresh"] is True
    assert body["Summary"]["Total"] == 9 and body["Summary"]["unknown"] == 2 and body["Summary"]["active"] == 1


def test_sessions_filter_by_text_and_state(client, fake_db):
    fake_db.fetchall_rows["GetSessions"] = [
        session_row("lnx-01", "alice"), session_row("lnx-02", "bob", SessionState="disconnected"),
    ]
    assert [s["Username"] for s in client.get("/api/sessions?q=LNX-02").get_json()["Sessions"]] == ["bob"]
    filtered = client.get("/api/sessions?state=disconnected").get_json()
    assert [s["Username"] for s in filtered["Sessions"]] == ["bob"]
    # The summary always describes everything, so the page's counts do not change as you filter.
    assert filtered["Summary"]["Total"] == 2
    assert client.get("/api/sessions?state=sleeping").status_code == 400


def test_user_search_uses_the_form_checkout_produces(client, fake_db):
    fake_db.fetchall_rows["SearchUsers"] = [{"Username": "johnsmith", "Uid": 2001, "ProfileResetPending": False}]

    body = client.get("/api/users?q=John.Smith&limit=5000").get_json()

    assert body["Users"][0]["Username"] == "johnsmith" and body["Query"] == "JohnSmith"
    assert fake_db.latest_call("SearchUsers")["params"] == ("JohnSmith", 200)


def test_user_details_combine_assignments_sessions_history_and_activity(client, fake_db):
    fake_db.fetchone_rows["GetUserDetails"] = {
        "Username": "alice", "Uid": 2001, "FirstProvisionedDate": None,
        "ProfileResetRequestedAtUtc": "2026-09-24T10:00:00Z", "ProfileResetRequestedBy": "admin@contoso.com",
        "AssignmentsJson": json.dumps([{"VMID": 1, "Hostname": "lnx-01", "VmStatus": "CheckedOut"}]),
    }
    fake_db.fetchall_rows["GetUserHostHistory"] = [{"VMID": 1, "Hostname": "lnx-01", "Assignments": 3, "IsCurrent": True}]
    fake_db.fetchall_rows["GetSessions"] = [session_row("lnx-01", "alice"), session_row("lnx-02", "alicia")]
    fake_db.fetchall_rows["GetAuditLogPaged"] = [
        {"AuditId": 2, "Action": "session.signout", "TargetType": "user", "TargetId": "alice", "DetailJson": "{}", "TotalCount": 2},
        {"AuditId": 1, "Action": "session.signout", "TargetType": "user", "TargetId": "alicebob", "DetailJson": "{}", "TotalCount": 2},
    ]

    body = client.get("/api/users/alice").get_json()

    assert body["Uid"] == 2001 and body["Assignments"][0]["Hostname"] == "lnx-01"
    assert body["ProfileReset"] == {"RequestedAtUtc": "2026-09-24T10:00:00Z", "RequestedBy": "admin@contoso.com"}
    assert [s["Username"] for s in body["Sessions"]] == ["alice"]
    assert body["HostHistory"][0]["Assignments"] == 3
    assert [entry["AuditId"] for entry in body["RecentActivity"]] == [2]
    assert fake_db.latest_call("GetAuditLogPaged")["params"][:2] == ("user", "alice")


def test_user_details_validate_and_report_unknown_users(client, fake_db):
    assert client.get("/api/users/bad.name").status_code == 400
    assert client.get("/api/users/nobody").status_code == 404


# ------------------------------------------------------------------------ sign-out


def test_sign_out_ends_the_session_then_releases_the_host(auth_client, fake_db, host, audit_entries):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    fake_db.fetchone_rows["ReleaseVm"] = {"ReleaseStatus": "Released", "Hostname": "lnx-05"}
    script(host, (0, "__SESSION_CONTROL_RESULT=signed-out\n", ""))
    client = auth_client(OPERATOR_USER)

    response = client.post("/api/sessions/lnx-05/bob/signout", json={}, headers=auth_client.headers)

    assert response.status_code == 200
    body = response.get_json()
    assert body["Result"] == "SignedOut" and body["Released"] is True and body["Returned"] is False
    assert host.commands == ["sudo -n /usr/local/bin/session-control.sh signout bob"]
    assert fake_db.latest_call("ReleaseVm")["params"] == ("lnx-05", LEASE_ID, "bob")
    [entry] = audit_entries
    assert entry["action"] == "session.signout" and entry["targetType"] == "user" and entry["targetId"] == "bob"
    assert json.loads(entry["detailJson"])["hostname"] == "lnx-05"


def test_sign_out_and_return_ends_the_assignment(client, fake_db, host):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    fake_db.fetchone_rows["ReleaseVm"] = {"ReleaseStatus": "Released"}
    fake_db.fetchone_rows["ReturnVm"] = {"VMID": 5, "Hostname": "lnx-05", "ReturnedUsername": "bob", "ReturnedLeaseId": LEASE_ID}
    fake_db.fetchone_rows["CompleteVmCleanup"] = {"VMID": 5, "Hostname": "lnx-05", "VmStatus": "Available", "DrainCompleted": False}
    script(
        host,
        (0, "__SESSION_CONTROL_RESULT=signed-out\n", ""),
        (0, "__LEASE_ACTION=cleared__\n", ""),
        (0, "", ""),
    )

    body = client.post("/api/sessions/lnx-05/bob/signout", json={"returnHost": True}).get_json()

    assert body["Returned"] is True and body["CleanupResult"] == "Completed"
    assert fake_db.latest_call("ReturnVm")["params"] == (5, LEASE_ID)
    assert host.commands[1] == f"sudo /usr/local/bin/manage-lease.sh clear bob {LEASE_ID}"


def test_sign_out_is_bound_to_a_user_the_broker_has_on_the_host(client, fake_db, host):
    assert client.post("/api/sessions/bad host/bob/signout").status_code == 400
    assert client.post("/api/sessions/lnx-05/bob;rm/signout").status_code == 400
    assert client.post("/api/sessions/lnx-05/bob/signout").status_code == 404

    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM, Username="carol")
    fake_db.fetchone_rows["GetHostHealth"] = {
        "HeartbeatAgeSeconds": 30, "ReconcileIntervalSeconds": 60,
        "SessionsJson": json.dumps([{"username": "carol", "state": "active"}]),
    }
    response = client.post("/api/sessions/lnx-05/bob/signout")
    assert response.status_code == 409 and "no session for bob" in response.get_json()["error"]
    assert host.calls == []


def test_a_fresh_heartbeat_can_bind_an_unmanaged_session(client, fake_db, host):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM, Username=None, LeaseId=None, VmStatus="Available")
    fake_db.fetchone_rows["GetHostHealth"] = {
        "HeartbeatAgeSeconds": 30, "ReconcileIntervalSeconds": 60,
        "SessionsJson": json.dumps([{"username": "mallory", "state": "disconnected"}]),
    }
    script(host, (0, "__SESSION_CONTROL_RESULT=signed-out\n", ""))

    body = client.post("/api/sessions/lnx-05/mallory/signout").get_json()

    assert body["Result"] == "SignedOut" and body["Released"] is False
    assert "ReleaseVm" not in procs(fake_db)

    # The same report from a stale heartbeat does not count.
    fake_db.fetchone_rows["GetHostHealth"]["HeartbeatAgeSeconds"] = 3600
    assert client.post("/api/sessions/lnx-05/mallory/signout").status_code == 409


def test_sign_out_needs_a_running_host_and_a_current_agent(client, fake_db, host):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM, PowerState="Off")
    assert client.post("/api/sessions/lnx-05/bob/signout").status_code == 409

    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    script(host, (1, "", "sudo: a password is required\n"))
    response = client.post("/api/sessions/lnx-05/bob/signout")
    assert response.status_code == 409
    assert "older than 1.1.0" in response.get_json()["error"]
    assert "ReleaseVm" not in procs(fake_db)


@pytest.mark.parametrize("stdout,status", [
    ("__SESSION_CONTROL_RESULT=refused\n", 409),
    ("__SESSION_CONTROL_RESULT=signout-incomplete\n", 502),
    ("", 502),
])
def test_sign_out_failures_do_not_release_the_host(client, fake_db, host, stdout, status):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    script(host, (1, stdout, "boom"))
    assert client.post("/api/sessions/lnx-05/bob/signout").status_code == status
    assert "ReleaseVm" not in procs(fake_db)


def test_signing_out_someone_already_gone_still_releases(client, fake_db, host):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    fake_db.fetchone_rows["ReleaseVm"] = {"ReleaseStatus": "Released"}
    script(host, (0, "__SESSION_CONTROL_RESULT=no-session\n", ""))

    body = client.post("/api/sessions/lnx-05/bob/signout").get_json()

    assert body["Result"] == "NoSession" and body["Released"] is True


# ------------------------------------------------------------------------- messages


def test_messages_are_validated_before_anything_happens(client, fake_db, host):
    for message in (None, "   ", "x" * 501, 42):
        assert client.post("/api/sessions/lnx-05/bob/message", json={"message": message}).status_code == 400
    assert fake_db.calls == [] and host.calls == []


def test_a_message_is_sent_on_stdin_without_control_characters(auth_client, fake_db, host, audit_entries):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    script(host, (0, "__SESSION_CONTROL_RESULT=delivered\n__SESSION_CONTROL_SESSIONS=1\n__SESSION_CONTROL_DELIVERED=1\n", ""))
    client = auth_client(OPERATOR_USER)

    response = client.post("/api/sessions/lnx-05/bob/message", json={"message": "Save\x07 your work\tnow"}, headers=auth_client.headers)

    assert response.status_code == 200 and response.get_json()["Delivered"] == 1
    assert host.calls[0]["command"] == "sudo -n /usr/local/bin/session-control.sh message bob"
    assert host.calls[0]["stdin"] == "Save your work now"
    [entry] = audit_entries
    assert entry["action"] == "session.message" and json.loads(entry["detailJson"])["message"] == "Save your work now"


def test_a_message_with_nowhere_to_go_says_so(client, fake_db, host):
    fake_db.fetchone_rows["GetVmByHostname"] = dict(VM)
    script(host, (0, "__SESSION_CONTROL_RESULT=no-session\n__SESSION_CONTROL_SESSIONS=0\n__SESSION_CONTROL_DELIVERED=0\n", ""))
    body = client.post("/api/sessions/lnx-05/bob/message", json={"message": "Hello"}).get_json()
    assert body["Delivered"] == 0 and "no session" in body["message"]


# ---------------------------------------------------------------------- profile reset


@pytest.mark.parametrize("claims,status", [(READER_USER, 403), (OPERATOR_USER, 403)])
def test_only_administrators_can_reset_profiles(auth_client, fake_db, claims, status):
    client = auth_client(claims)
    assert client.post("/api/users/bob/reset-profile", json={"confirm": "bob"}, headers=auth_client.headers).status_code == status


def test_a_profile_reset_needs_the_username_typed(auth_client, fake_db):
    client = auth_client(ADMIN_USER)
    response = client.post("/api/users/bob/reset-profile", json={}, headers=auth_client.headers)
    assert response.status_code == 409 and response.get_json()["requiresConfirmation"] is True
    assert "RequestProfileReset" not in procs(fake_db)


def test_a_profile_reset_is_requested_for_the_next_sign_in(auth_client, fake_db, audit_entries):
    fake_db.fetchone_rows["RequestProfileReset"] = {
        "Result": "Requested", "Username": "bob", "ProfileResetRequestedAtUtc": "2026-09-24T10:00:00Z",
        "ProfileResetRequestedBy": "alice@contoso.com", "CurrentlyAssigned": True,
    }
    client = auth_client(ADMIN_USER)

    response = client.post("/api/users/bob/reset-profile", json={"confirm": "BOB"}, headers=auth_client.headers)

    assert response.status_code == 200
    assert "after the current session ends" in response.get_json()["message"]
    assert fake_db.latest_call("RequestProfileReset")["params"] == ("bob", "alice@contoso.com")
    [entry] = audit_entries
    assert entry["action"] == "user.reset_profile_requested" and entry["targetId"] == "bob"


def test_profile_reset_request_and_cancel_report_unknown_users(client, fake_db):
    fake_db.fetchone_rows["RequestProfileReset"] = {"Result": "NotFound"}
    assert client.post("/api/users/ghost/reset-profile", json={"confirm": "ghost"}).status_code == 404

    fake_db.fetchone_rows["CancelProfileReset"] = {"Result": "NotFound"}
    assert client.post("/api/users/ghost/reset-profile/cancel").status_code == 404
    fake_db.fetchone_rows["CancelProfileReset"] = {"Result": "NotPending"}
    assert "no profile reset pending" in client.post("/api/users/bob/reset-profile/cancel").get_json()["message"]
    fake_db.fetchone_rows["CancelProfileReset"] = {"Result": "Cancelled"}
    assert client.post("/api/users/bob/reset-profile/cancel").get_json()["Result"] == "Cancelled"


def checkout_row(**values):
    row = {
        "VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5", "Username": "bob", "AvdHost": "avd-01",
        "LeaseId": LEASE_ID, "VmStatus": "CheckedOut", "CheckoutType": "Assigned", "ProfileResetRequested": True,
    }
    row.update(values)
    return row


def test_a_pending_reset_is_applied_on_a_new_assignment_before_the_home_is_mounted(app_module, auth_client, fake_db, host, monkeypatch, audit_entries):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    fake_db.fetchone_rows["BeginProfileReset"] = {"Result": "Ready"}
    fake_db.fetchone_rows["CompleteProfileReset"] = {"Result": "Completed"}
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)
    script(
        host,
        (0, "__SESSION_CONTROL_RESULT=profile-reset\n__SESSION_CONTROL_RENAMED_TO=bob.reset-20260924T100000Z\n", ""),
        (0, "__CREATE_USER_RESULT=ok__\n", ""),
    )
    client = auth_client({"roles": ["AvdHost"], "xms_mirid": "/subscriptions/s/resourcegroups/r/providers/Microsoft.Compute/virtualMachines/avd-01"})

    response = client.post("/api/vms/checkout", json={"username": "bob", "avdhost": "avd-01"}, headers=auth_client.headers)

    assert response.status_code == 200
    assert host.commands[0] == "sudo -n /usr/local/bin/session-control.sh reset-profile /mnt/test bob"
    assert "create-user.sh --password-stdin" in host.commands[1]
    assert fake_db.latest_call("BeginProfileReset")["params"] == ("bob", 5)
    assert "CompleteProfileReset" in procs(fake_db)
    applied = [entry for entry in audit_entries if entry["action"] == "user.reset_profile_applied"]
    assert applied and applied[0]["outcome"] == "success"
    assert json.loads(applied[0]["detailJson"])["renamedTo"] == "bob.reset-20260924T100000Z"


@pytest.mark.parametrize("readiness,reply,completed", [
    ("InUseElsewhere", None, False),
    ("Ready", (0, "__SESSION_CONTROL_RESULT=failed\n", ""), False),
    ("Ready", (1, "", "sudo: /usr/local/bin/session-control.sh: command not found\n"), False),
    ("Ready", (0, "__SESSION_CONTROL_RESULT=profile-missing\n", ""), True),
])
def test_a_reset_that_cannot_be_applied_never_blocks_the_sign_in(app_module, client, fake_db, host, monkeypatch, readiness, reply, completed):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    fake_db.fetchone_rows["BeginProfileReset"] = {"Result": readiness}
    fake_db.fetchone_rows["CompleteProfileReset"] = {"Result": "Completed"}
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)
    responses = ([reply] if reply else []) + [(0, "__CREATE_USER_RESULT=ok__\n", "")]
    script(host, *responses)

    response = client.post("/api/vms/checkout", json={"username": "bob", "avdhost": "avd-01"})

    assert response.status_code == 200 and response.get_json()["Hostname"] == "lnx-05"
    assert ("CompleteProfileReset" in procs(fake_db)) is completed
    assert "create-user.sh --password-stdin" in host.commands[-1]


def test_a_reconnect_never_resets_the_profile(app_module, client, fake_db, host, monkeypatch):
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row(CheckoutType="Reused")]
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)
    script(host, (0, "__CREATE_USER_RESULT=ok__\n", ""))

    assert client.post("/api/vms/checkout", json={"username": "bob", "avdhost": "avd-01"}).status_code == 200
    assert "BeginProfileReset" not in procs(fake_db)
    assert len(host.calls) == 1
