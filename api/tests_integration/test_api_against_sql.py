"""End-to-end checks of the handlers against the real stored procedures and driver."""

import json
import types
from pathlib import Path

import pytest

SQL_DIR = Path(__file__).resolve().parents[2] / "sql_queries"


def _checkout(client, username="alice", avdhost="avd-01"):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost})


def test_checkout_with_no_ready_host_is_a_conflict_not_a_server_error(client, db, remote):
    db.add_vm("lnxhost-01", power="Off", network="Unreachable")
    response = _checkout(client)
    assert response.status_code == 409, response.get_json()


def test_checkout_provisions_the_user_and_records_the_assignment(client, db, remote):
    db.add_vm("lnxhost-01")

    response = _checkout(client)

    assert response.status_code == 200, response.get_json()
    body = response.get_json()
    assert body["Hostname"] == "lnxhost-01" and body["password"]
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "CheckedOut" and vm["Username"] == "alice"
    assert str(vm["LeaseId"]).lower() == body["LeaseId"]
    assert remote.calls == [("lnxhost-01", "create")]
    assert db.one("SELECT uid FROM dbo.VmUsers WHERE username = 'alice'")["uid"] >= 2000


def test_a_user_keeps_the_same_uid_on_every_host(client, db, remote):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02")
    assert _checkout(client, "alice").status_code == 200
    assert _checkout(client, "bob").status_code == 200
    uids = {row["username"]: row["uid"] for row in db.run("SELECT username, uid FROM dbo.VmUsers")}
    assert len(set(uids.values())) == 2

    db.run("UPDATE dbo.VirtualMachines SET VmStatus='Available', Username=NULL, LeaseId=NULL")
    assert _checkout(client, "bob").status_code == 200
    assert db.one("SELECT uid FROM dbo.VmUsers WHERE username = 'bob'")["uid"] == uids["bob"]


def test_a_failed_provisioning_holds_the_vm_until_its_cleanup_succeeds(client, db, remote):
    db.add_vm("lnxhost-01")
    remote.reply("create", 1, "", "Failed to mount the NFS share.\n")
    remote.reply("clear", 0, "__LEASE_ACTION=in-use__\n")

    assert _checkout(client).status_code == 500
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Available" and vm["CleanupPending"] and vm["Username"] is None
    assert _checkout(client, "bob").status_code == 409, "a VM pending cleanup must not be handed out"

    remote.reply("clear", 0, "__LEASE_ACTION=cleared__\n")
    retry = client.post(f"/api/vms/{vm['VMID']}/cleanup")
    assert retry.status_code == 200, retry.get_json()
    assert not db.vm("lnxhost-01")["CleanupPending"]

    remote.replies.pop("create")
    assert _checkout(client, "bob").status_code == 200


def test_release_and_reconnect_keep_the_lease(client, db, remote):
    db.add_vm("lnxhost-01")
    first = _checkout(client).get_json()

    released = client.post("/api/vms/lnxhost-01/release", json={"username": "alice", "leaseId": first["LeaseId"]})
    assert released.status_code == 200, released.get_json()
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Released" and vm["ReleasedDate"] is not None

    again = _checkout(client).get_json()
    assert again["VMID"] == first["VMID"] and again["LeaseId"] == first["LeaseId"]
    assert db.vm("lnxhost-01")["ReleasedDate"] is None


def test_the_sweep_waits_for_the_grace_period_then_cleans_up(client, db, remote):
    db.add_vm("lnxhost-01")
    lease = _checkout(client).get_json()["LeaseId"]
    client.post("/api/vms/lnxhost-01/release", json={"username": "alice", "leaseId": lease})

    db.run("UPDATE dbo.VirtualMachines SET ReleasedDate = DATEADD(SECOND, -1300, GETDATE()) WHERE Hostname='lnxhost-01'")
    assert client.post("/api/vms/released", json={}).get_json() == []
    assert db.vm("lnxhost-01")["VmStatus"] == "Released"

    db.run("UPDATE dbo.VirtualMachines SET ReleasedDate = DATEADD(SECOND, -1330, GETDATE()) WHERE Hostname='lnxhost-01'")
    response = client.post("/api/vms/released", json={})

    assert response.status_code == 200, response.get_json()
    [row] = response.get_json()
    assert row["CleanupResult"] == "Completed" and row["CleanupPending"] is False
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Available" and not vm["CleanupPending"] and vm["Username"] is None


def test_the_sweep_keeps_a_host_pending_while_its_user_is_signed_in(client, db, remote):
    db.add_vm("lnxhost-01")
    lease = _checkout(client).get_json()["LeaseId"]
    client.post("/api/vms/lnxhost-01/release", json={"username": "alice", "leaseId": lease})
    db.run("UPDATE dbo.VirtualMachines SET ReleasedDate = DATEADD(HOUR, -1, GETDATE()) WHERE Hostname='lnxhost-01'")
    remote.reply("clear", 0, "__LEASE_ACTION=in-use__\n")

    [row] = client.post("/api/vms/released", json={}).get_json()

    assert row["CleanupResult"] == "InUse"
    assert db.vm("lnxhost-01")["CleanupPending"]
    assert _checkout(client, "bob").status_code == 409


def test_manual_return_cleans_up_and_frees_the_host(client, db, remote):
    db.add_vm("lnxhost-01")
    vmid = _checkout(client).get_json()["VMID"]

    response = client.post(f"/api/vms/{vmid}/return")

    assert response.status_code == 200, response.get_json()
    assert response.get_json()["CleanupResult"] == "Completed"
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Available" and not vm["CleanupPending"]
    assert [kind for _, kind in remote.calls[-2:]] == ["clear", "userdel"]


def test_maintenance_network_status_and_summary(client, db, remote):
    vmid = db.add_vm("lnxhost-01")["VMID"]
    db.add_vm("lnxhost-02", status="CheckedOut", Username="alice")

    assert client.post(f"/api/vms/{vmid}/maintenance", json={"enabled": True}).status_code == 200
    assert db.vm("lnxhost-01")["VmStatus"] == "Maintenance"
    assigned = db.vm("lnxhost-02")["VMID"]
    assert client.post(f"/api/vms/{assigned}/maintenance", json={"enabled": True}).status_code == 409

    changed = client.post(f"/api/vms/{vmid}/network-status", json={"networkstatus": "Unreachable"}).get_json()
    unchanged = client.post(f"/api/vms/{vmid}/network-status", json={"networkstatus": "Unreachable"}).get_json()
    assert changed["Changed"] is True and unchanged["Changed"] is False

    summary = client.get("/api/vms/summary").get_json()
    assert summary["TotalVMs"] == 2 and summary["Maintenance"] == 1 and summary["CheckedOut"] == 1
    assert summary["CleanupPending"] == 0 and summary["Ready"] == 0

    vms = client.get("/api/vms").get_json()
    assert {"ReleasedDate", "CleanupPending", "CleanupUsername", "PowerStateChangedDate"} <= set(vms[0])
    details = client.get(f"/api/vms/{vmid}").get_json()
    assert details["VmStatus"] == "Maintenance" and "CleanupPending" in details


def test_repairing_an_assignment_claims_its_cleanup(client, db, remote):
    vmid = db.add_vm("lnxhost-01", status="CheckedOut", Username="alice")["VMID"]

    response = client.post(f"/api/vms/{vmid}/update-attributes", json={"vmstatus": "Available"})

    assert response.status_code == 200, response.get_json()
    vm = db.vm("lnxhost-01")
    assert vm["Username"] is None and vm["CleanupPending"] and vm["CleanupUsername"] == "alice"


class _Compute:
    def __init__(self, states):
        self.states = states
        self.operations = []
        outer = self

        class _Vms:
            def instance_view(self, resource_group, name):
                return types.SimpleNamespace(statuses=[types.SimpleNamespace(code=outer.states[name])])

            def begin_start(self, resource_group, name):
                outer.operations.append(("start", name))

            def begin_power_off(self, resource_group, name):
                outer.operations.append(("power_off", name))

            def begin_deallocate(self, resource_group, name):
                outer.operations.append(("deallocate", name))

        self.virtual_machines = _Vms()


def test_scaling_starts_hosts_to_reach_the_minimum(app_module, client, db, remote, monkeypatch):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02", power="Off", network="Unreachable")
    db.add_vm("lnxhost-03", power="Off", network="Unreachable")
    compute = _Compute({
        "lnxhost-01": "PowerState/running",
        "lnxhost-02": "PowerState/deallocated",
        "lnxhost-03": "PowerState/deallocated",
    })
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)

    response = client.post("/api/scaling/trigger", json={})

    assert response.status_code == 200, response.get_json()
    assert compute.operations == [("start", "lnxhost-02")]
    vm = db.vm("lnxhost-02")
    assert vm["PowerState"] == "On" and vm["NetworkStatus"] == "Unreachable"
    log = db.one("SELECT TOP 1 * FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert log["ActionTaken"] == "Scale Up" and log["VMsPoweredOn"] == 1


def test_scaling_down_honours_the_deallocate_stop_mode(app_module, client, db, remote, monkeypatch):
    for index in range(1, 6):
        db.add_vm(f"lnxhost-0{index}")
    compute = _Compute({f"lnxhost-0{index}": "PowerState/running" for index in range(1, 6)})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)
    rule_id = client.get("/api/scaling/rules").get_json()[0]["RuleID"]
    assert client.post(f"/api/scaling/rules/{rule_id}/update", json={"stopmode": "Deallocate"}).status_code == 200

    response = client.post("/api/scaling/trigger", json={})

    assert response.status_code == 200, response.get_json()
    assert response.get_json()["DeallocatedVMs"] == ["lnxhost-05"]
    assert compute.operations == [("deallocate", "lnxhost-05")]
    assert db.vm("lnxhost-05")["PowerState"] == "Off"


def test_scaling_corrects_power_states_that_drifted_in_azure(app_module, client, db, remote, monkeypatch):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02")
    compute = _Compute({"lnxhost-01": "PowerState/running", "lnxhost-02": "PowerState/deallocated"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)

    body = client.post("/api/scaling/trigger", json={}).get_json()

    assert {"Hostname": "lnxhost-02", "PowerState": "Off"} in body["PowerStateCorrections"]


def test_only_one_scaling_rule_can_exist(client, db, remote):
    rules = client.get("/api/scaling/rules").get_json()
    assert len(rules) == 1 and rules[0]["IsActive"] is True and rules[0]["StopMode"] == "PowerOff"

    response = client.post("/api/scaling/rules/create", json={
        "minvms": 1, "maxvms": 5, "scaleupratio": 80, "scaleupincrement": 1,
        "scaledownratio": 20, "scaledownincrement": 1,
    })

    assert response.status_code == 409, response.get_json()
    assert response.get_json()["ActiveRuleID"] == rules[0]["RuleID"]


def test_a_rule_can_be_created_when_none_exists(client, db, remote):
    db.run("DELETE FROM dbo.VmScalingRules")
    response = client.post("/api/scaling/rules/create", json={
        "minvms": 1, "maxvms": 5, "scaleupratio": 80, "scaleupincrement": 1,
        "scaledownratio": 20, "scaledownincrement": 1, "stopmode": "Deallocate",
    })
    assert response.status_code == 201, response.get_json()
    rule = client.get(f"/api/scaling/rules/{response.get_json()['NewRuleID']}").get_json()
    assert rule["StopMode"] == "Deallocate"


def test_the_preserve_sessions_setting_round_trips(client, db, remote):
    before = client.get("/api/hosts/settings").get_json()
    assert "PreserveSessionsOnDisconnect" not in before, "hosts must not see the new key while it is off"

    response = client.post("/api/hosts/settings/update", json={"PreserveSessionsOnDisconnect": True})

    assert response.status_code == 200, response.get_json()
    after = client.get("/api/hosts/settings").get_json()
    assert after["PreserveSessionsOnDisconnect"] is True
    assert after["SettingsVersion"] == before["SettingsVersion"] + 1


def test_apply_now_records_the_version_each_host_applied(client, db, remote):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02", power="Off", network="Unreachable")

    body = client.post("/api/hosts/settings/apply", json={}).get_json()

    assert body["TargetCount"] == 1 and body["SucceededCount"] == 1
    version = client.get("/api/hosts/settings").get_json()["SettingsVersion"]
    assert db.vm("lnxhost-01")["SettingsVersion"] == version


def test_paged_history_reads_the_temporal_tables(client, db, remote):
    db.add_vm("lnxhost-01")
    _checkout(client)
    body = client.post("/api/vms/history?page=1&per_page=5", json={}).get_json()
    assert body["page"] == 1 and body["total"] >= 1
    assert client.post("/api/scaling/rules/history?page=1&per_page=5", json={}).status_code == 200
    assert client.post("/api/scaling/log?page=1&per_page=5", json={}).status_code == 200


def test_a_vm_added_in_the_portal_with_blank_fields_can_be_checked_out(client, db, remote):
    response = client.post("/api/vms/add", json={
        "hostname": "lnxhost-09", "ipaddress": "10.0.0.9", "powerstate": "On",
        "networkstatus": "Reachable", "vmstatus": "Available", "username": "", "avdhost": "",
    })
    assert response.status_code == 201, response.get_json()
    assert db.vm("lnxhost-09")["Username"] is None
    assert client.get("/api/vms/summary").get_json()["Ready"] == 1
    assert _checkout(client).get_json()["Hostname"] == "lnxhost-09"


def test_the_migration_repairs_available_hosts_left_with_an_assignment(sql, client, db, remote):
    """Earlier portal and repair paths left Username values on Available and Maintenance rows."""
    db.add_vm("lnxhost-01", Username="")
    db.add_vm("lnxhost-02", status="Maintenance", Username="bob", LeaseId="8ff6eb09-90ca-4efa-8ea1-695761f950f7")
    assert client.get("/api/vms/summary").get_json()["Ready"] == 0

    [migration] = sorted(SQL_DIR.glob("040_*.sql"))
    conn = sql(autocommit=True)
    try:
        _apply_single(conn, migration)
    finally:
        conn.close()

    blank = db.vm("lnxhost-01")
    assert blank["Username"] is None and not blank["CleanupPending"]
    stale = db.vm("lnxhost-02")
    assert stale["Username"] is None and stale["LeaseId"] is None
    assert stale["CleanupPending"] and stale["CleanupUsername"] == "bob"
    assert client.get("/api/vms/summary").get_json()["Ready"] == 1


def _apply_single(conn, path):
    """Apply one script the way deploy/Initialize-Database.ps1 does."""
    from apply_scripts import convert_sql_script_content, split_sql_batches

    content = convert_sql_script_content(path.read_text(encoding="utf-8"), path.name)
    cursor = conn.cursor()
    for batch in split_sql_batches(content):
        cursor.execute(batch)


def test_scaling_runs_do_not_write_scaling_rule_history(app_module, client, db, remote, monkeypatch):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02")
    compute = _Compute({"lnxhost-01": "PowerState/running", "lnxhost-02": "PowerState/running"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)
    before = db.one("SELECT COUNT(*) AS n FROM dbo.VmScalingRulesHistory")["n"]

    for _ in range(3):
        assert client.post("/api/scaling/trigger", json={}).status_code == 200

    assert db.one("SELECT COUNT(*) AS n FROM dbo.VmScalingRulesHistory")["n"] == before
