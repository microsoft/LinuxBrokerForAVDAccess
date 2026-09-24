"""Phase 2 foundations against the real stored procedures and driver: host actions and
drain, heartbeats and fleet health, and the audit log."""

import json
import types

import pytest


class Compute:
    def __init__(self, fail=()):
        self.operations = []
        self.fail = set(fail)
        compute = self

        class VirtualMachines:
            def _operate(self, operation, resource_group, name):
                if operation in compute.fail:
                    raise RuntimeError("refused")
                compute.operations.append((operation, name))

            def begin_start(self, resource_group, name):
                self._operate("start", resource_group, name)

            def begin_power_off(self, resource_group, name):
                self._operate("power_off", resource_group, name)

            def begin_deallocate(self, resource_group, name):
                self._operate("deallocate", resource_group, name)

            def begin_restart(self, resource_group, name):
                self._operate("restart", resource_group, name)

        self.virtual_machines = VirtualMachines()


@pytest.fixture
def compute(app_module, monkeypatch):
    fake = Compute()
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)
    return fake


@pytest.fixture
def as_admin(app_module, monkeypatch):
    # The client fixture bypasses token validation, so there is no role to check.
    monkeypatch.setattr(app_module, "caller_is_admin", lambda: True)


def _checkout(client, username, avdhost="avd-01"):
    return client.post("/api/vms/checkout", json={"username": username, "avdhost": avdhost})


def audit_actions(db):
    return [(row["Action"], row["TargetId"]) for row in db.run("SELECT Action, TargetId FROM dbo.AuditLog ORDER BY AuditId")]


def test_power_actions_record_the_state_and_restore_it_when_azure_refuses(app_module, client, db, compute, monkeypatch):
    vmid = db.add_vm("lnxhost-01", power="Off", network="Unreachable")["VMID"]

    started = client.post(f"/api/vms/{vmid}/start")
    assert started.status_code == 202, started.get_json()
    vm = db.vm("lnxhost-01")
    assert vm["PowerState"] == "On" and vm["NetworkStatus"] == "Unreachable" and vm["PowerStateChangedDate"]
    assert compute.operations == [("start", "lnxhost-01")]

    db.run("UPDATE dbo.VirtualMachines SET NetworkStatus='Reachable' WHERE Hostname='lnxhost-01'")
    refusing = Compute(fail={"restart"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: refusing)
    refused = client.post(f"/api/vms/{vmid}/restart")
    assert refused.status_code == 502, refused.get_json()
    vm = db.vm("lnxhost-01")
    assert vm["PowerState"] == "On" and vm["NetworkStatus"] == "Reachable"


def test_stopping_a_host_in_use_ends_the_assignment(client, db, remote, compute, as_admin):
    db.add_vm("lnxhost-01")
    first = _checkout(client, "alice").get_json()
    vmid = first["VMID"]

    unconfirmed = client.post(f"/api/vms/{vmid}/stop", json={})
    assert unconfirmed.status_code == 409 and unconfirmed.get_json()["Username"] == "alice"
    assert db.vm("lnxhost-01")["Username"] == "alice"

    stopped = client.post(f"/api/vms/{vmid}/stop", json={"confirm": "lnxhost-01", "mode": "Deallocate"})
    assert stopped.status_code == 202, stopped.get_json()
    assert stopped.get_json()["EndedAssignment"] is True
    vm = db.vm("lnxhost-01")
    assert vm["PowerState"] == "Off" and vm["Username"] is None and vm["VmStatus"] == "Available"
    assert vm["CleanupPending"] and vm["CleanupUsername"] == "alice"
    assert str(vm["CleanupLeaseId"]).lower() == first["LeaseId"]
    assert compute.operations == [("deallocate", "lnxhost-01")]

    # The user is given a different, running host when they come back.
    db.add_vm("lnxhost-02")
    assert _checkout(client, "alice").get_json()["Hostname"] == "lnxhost-02"


def test_a_refused_stop_of_a_host_in_use_keeps_the_user_on_it(app_module, client, db, remote, as_admin, monkeypatch):
    db.add_vm("lnxhost-01")
    first = _checkout(client, "alice").get_json()
    vmid = first["VMID"]
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: Compute(fail={"power_off", "deallocate"}))

    refused = client.post(f"/api/vms/{vmid}/stop", json={"confirm": "lnxhost-01"})

    assert refused.status_code == 502, refused.get_json()
    assert refused.get_json()["error"] == "Azure refused to stop lnxhost-01. Its recorded state was restored."
    vm = db.vm("lnxhost-01")
    assert vm["PowerState"] == "On" and vm["NetworkStatus"] == "Reachable"
    assert vm["Username"] == "alice" and vm["VmStatus"] == "CheckedOut" and not vm["CleanupPending"]
    # The user is still signed in there, and reconnects to it with the same lease.
    again = _checkout(client, "alice").get_json()
    assert again["VMID"] == vmid and again["LeaseId"] == first["LeaseId"]


def test_a_drained_host_keeps_its_user_then_leaves_rotation(client, db, remote):
    db.add_vm("lnxhost-01")
    vmid = _checkout(client, "alice").get_json()["VMID"]
    db.add_vm("lnxhost-02")

    drained = client.post(f"/api/vms/{vmid}/drain")
    assert drained.status_code == 200 and drained.get_json()["Result"] == "Draining"
    assert client.get("/api/vms/summary").get_json()["Draining"] == 1

    assert _checkout(client, "bob").get_json()["Hostname"] == "lnxhost-02"
    assert _checkout(client, "carol").status_code == 409
    assert _checkout(client, "alice").get_json()["VMID"] == vmid

    returned = client.post(f"/api/vms/{vmid}/return")
    assert returned.status_code == 200 and returned.get_json()["CleanupResult"] == "Completed"
    vm = db.vm("lnxhost-01")
    assert vm["VmStatus"] == "Maintenance" and not vm["DrainRequested"] and not vm["CleanupPending"]
    assert ("vm.drain_completed", "lnxhost-01") in audit_actions(db)

    back = client.post(f"/api/vms/{vmid}/undrain")
    assert back.status_code == 200 and back.get_json()["Result"] == "ReturnedToService"
    assert db.vm("lnxhost-01")["VmStatus"] == "Available"


def test_the_sweep_completes_drains_on_any_path(client, db, remote):
    db.add_vm("lnxhost-01", DrainRequested=1)

    assert client.post("/api/vms/released", json={}).status_code == 200

    assert db.vm("lnxhost-01")["VmStatus"] == "Maintenance"
    assert audit_actions(db) == [("vm.drain_completed", "lnxhost-01")]


def test_a_heartbeat_reaches_fleet_health(client, db):
    db.add_vm("lnxhost-01")
    db.add_vm("lnxhost-02", power="Off", network="Unreachable")
    settings_version = db.one("SELECT SettingsVersion FROM dbo.LinuxHostSettings")["SettingsVersion"]

    heartbeat = {
        "agentVersion": "1.0.0",
        "scriptVersions": {name: "1.0.0" for name in (
            "release-session.sh", "logind-session-watcher.sh", "xrdp-who-xorg.sh",
            "create-user.sh", "manage-lease.sh", "apply-host-settings.sh",
        )},
        "settingsVersion": settings_version,
        "os": {"id": "rhel", "version": "9.4", "name": "Red Hat Enterprise Linux 9.4"},
        "desktop": "gnome",
        "xrdp": {"version": "0.10.1", "active": True},
        "nfs": {"reachable": True, "mounts": 1},
        "loadAverage": 0.2, "cpuCount": 4, "memoryAvailableMb": 9000, "memoryTotalMb": 16000,
        "rootDiskFreePct": 70, "uptimeSeconds": 120,
        "sessions": [{"username": "alice", "state": "active", "sessionStart": 1790000000, "idleSeconds": 5}],
    }
    response = client.post("/api/hosts/lnxhost-01/heartbeat", json=heartbeat)
    assert response.status_code == 200, response.get_json()
    assert client.post("/api/hosts/unknown-host/heartbeat", json=heartbeat).status_code == 404

    health = client.get("/api/hosts/health").get_json()
    hosts = {host["Hostname"]: host for host in health["Hosts"]}
    assert hosts["lnxhost-01"]["Flags"] == [] and hosts["lnxhost-01"]["Status"] == "healthy"
    assert hosts["lnxhost-01"]["Sessions"][0]["username"] == "alice"
    assert hosts["lnxhost-01"]["AppliedSettingsVersion"] == settings_version
    assert hosts["lnxhost-02"]["Status"] == "off"
    assert health["Summary"]["Healthy"] == 1 and health["Summary"]["Off"] == 1

    one = client.get("/api/hosts/health?hostname=lnxhost-01").get_json()
    assert [host["Hostname"] for host in one["Hosts"]] == ["lnxhost-01"]

    vmid = db.vm("lnxhost-01")["VMID"]
    assert client.post(f"/api/vms/{vmid}/delete").status_code == 200
    assert db.one("SELECT COUNT(*) AS c FROM dbo.HostHeartbeats")["c"] == 0
    assert client.post(f"/api/vms/{vmid}/delete").status_code == 404


def test_audit_entries_are_stored_read_and_purged(app_module, client, db):
    with app_module.app.test_request_context("/api/vms/1/start", method="POST"):
        app_module.audit("vm.start", "vm", "lnxhost-01", "success", {"mode": None}, claims={
            "oid": "oid-alice", "scp": "access_as_user", "preferred_username": "alice@contoso.com",
        })
        app_module.audit("settings.update", "settings", "Global", "failure", {"status": 400})

    page = client.get("/api/audit?action=vm.&per_page=10").get_json()
    assert page["total"] == 1
    [entry] = page["items"]
    assert entry["ActorName"] == "alice@contoso.com" and entry["ActorType"] == "user"
    assert entry["Detail"] == {"mode": None} and entry["OccurredAtUtc"].endswith("Z")

    assert client.get("/api/audit?outcome=failure").get_json()["items"][0]["Action"] == "settings.update"

    purged = client.post("/api/audit/purge", json={})
    assert purged.status_code == 200 and purged.get_json()["Deleted"] == 0
    assert audit_actions(db)[-1] == ("audit.purge", None)


def test_settings_history_lists_saved_versions(client, db):
    before = client.get("/api/hosts/settings/history").get_json()
    db.run("EXEC dbo.UpdateLinuxHostSettings @GracePeriodSeconds=1800, @UpdatedBy='alice@contoso.com'")

    after = client.get("/api/hosts/settings/history?limit=5").get_json()
    assert after[0]["IsCurrent"] is True and after[0]["GracePeriodSeconds"] == 1800
    assert after[0]["UpdatedBy"] == "alice@contoso.com"
    assert after[0]["SettingsVersion"] == (before[0]["SettingsVersion"] if before else 0) + 1
