"""2.9 rolling maintenance against the real stored procedures, with SSH and Azure faked: a run
advanced end to end, a forced sign-out at the deadline, and the return-to-service guard."""

import json
import types

import pytest


class PatchHost:
    """patch-host.sh as the API sees it: start records the token, status reports it. Every other
    command goes to the scripted RemoteHost."""

    def __init__(self, remote):
        self.remote = remote
        self.runs = {}
        self.outcome = "succeeded"
        self.started = []

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        if "patch-host.sh" not in command:
            return self.remote(hostname, command, stdin_input=stdin_input, timeout=timeout)
        words = command.split("patch-host.sh", 1)[1].split()
        if words[0] == "start":
            self.started.append((hostname, words[1], words[2]))
            self.runs[hostname] = words[2]
            stdout = f"__PATCH_HOST_RESULT=started\n__PATCH_HOST_STATE=running\n__PATCH_HOST_TOKEN={words[2]}\n"
        else:
            token = self.runs.get(hostname, "")
            state = self.outcome if token else "none"
            stdout = (f"__PATCH_HOST_STATE={state}\n__PATCH_HOST_TOKEN={token}\n"
                      f"__PATCH_HOST_EXIT_CODE={0 if state == 'succeeded' else 1}\n"
                      "__PATCH_HOST_REBOOT_REQUIRED=yes\n__PATCH_HOST_MANAGER=dnf\n")
        return types.SimpleNamespace(returncode=0, stdout=stdout, stderr=""), f"avdadmin@{hostname}"


@pytest.fixture
def patch_host(app_module, monkeypatch, remote):
    fake = PatchHost(remote)
    monkeypatch.setattr(app_module, "run_remote_command", fake)
    return fake


class Compute:
    def __init__(self):
        self.calls = []
        self.virtual_machines = self

    def __getattr__(self, name):
        if name.startswith("begin_"):
            return lambda group, hostname: self.calls.append((name[len("begin_"):], hostname))
        raise AttributeError(name)


@pytest.fixture
def azure(app_module, monkeypatch):
    compute = Compute()
    monkeypatch.setattr(app_module, "VM_SUBSCRIPTION_ID", "sub")
    monkeypatch.setattr(app_module, "VM_RESOURCE_GROUP", "rg")
    monkeypatch.setattr(app_module, "get_compute_client", lambda: compute)
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)
    return compute


def advance(client):
    response = client.post("/api/maintenance/advance", json={})
    assert response.status_code == 200, response.get_json()
    return response.get_json()


def run_hosts(client, run_id):
    return {h["Hostname"]: h for h in client.get(f"/api/maintenance/runs/{run_id}").get_json()["Hosts"]}


def heartbeat(client, hostname, uptime=60, sessions=None):
    response = client.post(f"/api/hosts/{hostname}/heartbeat", data=json.dumps({
        "agentVersion": "1.1.0", "uptimeSeconds": uptime, "xrdp": {"active": True}, "sessions": sessions or [],
    }), content_type="application/json")
    assert response.status_code == 200, response.get_json()


def come_back(client, db, hostname, run_id):
    """The restart finished: the probe reaches the host and its agent reports a fresh boot."""
    db.run("UPDATE dbo.MaintenanceRunHosts SET RestartRequestedAt = DATEADD(MINUTE, -5, RestartRequestedAt) "
           "WHERE RunID = %s AND Hostname = %s", (run_id, hostname))
    vm = db.vm(hostname)
    assert client.post(f"/api/vms/{vm['VMID']}/network-status", json={"networkstatus": "Reachable"}).status_code == 200
    heartbeat(client, hostname, uptime=60)


def test_a_run_patches_each_host_in_turn_and_puts_it_back(client, db, remote, patch_host, azure):
    patch = patch_host
    for name in ("lnx-01", "lnx-02", "lnx-03"):
        db.add_vm(name)
    created = client.post("/api/maintenance/runs/create", json={
        "hostnames": ["lnx-01", "lnx-02"], "patchMode": "Security", "batchSize": 1, "minReady": 1,
    })
    assert created.status_code == 201, created.get_json()
    run_id = created.get_json()["RunID"]

    # Admitted, out of rotation and patching in the same advance.
    advance(client)
    hosts = run_hosts(client, run_id)
    assert hosts["lnx-01"]["State"] == "Patching" and hosts["lnx-02"]["State"] == "Pending"
    assert db.vm("lnx-01")["VmStatus"] == "Maintenance"
    assert patch.started == [("lnx-01", "security", f"lb{run_id}-{hosts['lnx-01']['RunHostID']}-1")]

    # Patched: restarted through Azure, then waiting for proof it came back.
    advance(client)
    assert azure.calls == [("restart", "lnx-01")]
    hosts = run_hosts(client, run_id)
    assert hosts["lnx-01"]["State"] == "Verifying" and hosts["lnx-01"]["RebootRequired"] == "yes"
    assert db.vm("lnx-01")["NetworkStatus"] == "Unreachable"

    come_back(client, db, "lnx-01", run_id)
    advance(client)
    hosts = run_hosts(client, run_id)
    assert hosts["lnx-01"]["State"] == "Succeeded" and hosts["lnx-01"]["Detail"] == "Patched and restarted."
    assert db.vm("lnx-01")["VmStatus"] == "Available"

    # The next host is admitted on the following advance.
    advance(client)
    advance(client)
    come_back(client, db, "lnx-02", run_id)
    final = advance(client)
    assert final["Status"] == "Completed"
    run = client.get(f"/api/maintenance/runs/{run_id}").get_json()["Run"]
    assert run["Status"] == "Completed" and run["Counts"]["Succeeded"] == 2 and run["EndedAtUtc"]
    assert db.vm("lnx-02")["VmStatus"] == "Available"

    # The broker's own actions are audited whoever advanced the run.
    actions = [row["Action"] for row in db.run("SELECT Action FROM dbo.AuditLog")]
    for action in ("maintenance.host_admitted", "maintenance.host_patched", "maintenance.host_completed",
                   "maintenance.run_completed"):
        assert action in actions, action


def test_a_failed_patch_stops_the_run_and_leaves_the_host_out(client, db, remote, patch_host, azure):
    patch = patch_host
    patch.outcome = "failed"
    for name in ("lnx-01", "lnx-02", "lnx-03"):
        db.add_vm(name)
    run_id = client.post("/api/maintenance/runs/create", json={
        "hostnames": ["lnx-01", "lnx-02"], "patchMode": "All", "batchSize": 1, "minReady": 0,
    }).get_json()["RunID"]

    advance(client)
    stopped = advance(client)

    hosts = run_hosts(client, run_id)
    assert hosts["lnx-01"]["State"] == "Failed" and "Patching failed (exit 1)" in hosts["lnx-01"]["Detail"]
    assert hosts["lnx-02"]["State"] == "Cancelled"
    assert stopped["Status"] == "Stopping"
    assert advance(client)["Status"] == "Failed"
    assert db.vm("lnx-01")["VmStatus"] == "Maintenance"

    attention = client.get("/api/metrics/attention").get_json()["Items"]
    assert any(item["Kind"] == "maintenance-failed" and item["Hostname"] == "lnx-01" for item in attention)


def test_a_user_is_warned_and_signed_out_at_the_deadline(client, db, remote, patch_host, azure):
    db.add_vm("lnx-spare")
    db.add_vm("lnx-01")
    assert client.post("/api/vms/checkout", json={"username": "alice", "avdhost": "avd-01"}).status_code == 200
    busy = [name for name in ("lnx-spare", "lnx-01") if db.vm(name)["Username"] == "alice"][0]
    heartbeat(client, busy, uptime=86400, sessions=[{"username": "alice", "state": "active"}])
    db.run("UPDATE dbo.VirtualMachines SET LastCheckoutDate = DATEADD(HOUR, -1, GETDATE()) WHERE Hostname = %s", (busy,))

    run_id = client.post("/api/maintenance/runs/create", json={
        "hostnames": [busy], "patchMode": "Security", "batchSize": 1, "minReady": 0,
        "signOutDeadlineMinutes": 5, "warningMinutes": 2,
    }).get_json()["RunID"]
    advance(client)
    assert db.vm(busy)["DrainRequested"] is True and run_hosts(client, run_id)[busy]["State"] == "Draining"

    db.run("UPDATE dbo.MaintenanceRunHosts SET AdmittedAt = DATEADD(MINUTE, -4, AdmittedAt) WHERE RunID = %s", (run_id,))
    advance(client)
    assert ("message-all" in [kind for _, kind in remote.calls])
    assert run_hosts(client, run_id)[busy]["WarningSentAtUtc"]

    db.run("UPDATE dbo.MaintenanceRunHosts SET AdmittedAt = DATEADD(MINUTE, -2, AdmittedAt), "
           "WarningSentAt = DATEADD(MINUTE, -2, WarningSentAt) WHERE RunID = %s", (run_id,))
    advance(client)
    kinds = [kind for _, kind in remote.calls]
    assert "signout" in kinds and "userdel" in kinds
    vm = db.vm(busy)
    assert vm["Username"] is None and vm["VmStatus"] == "Maintenance" and vm["CleanupPending"] is False

    advance(client)
    assert run_hosts(client, run_id)[busy]["State"] == "Patching"


def test_a_host_being_patched_cannot_be_put_back_by_hand(client, db, remote, patch_host, azure):
    db.add_vm("lnx-01")
    db.add_vm("lnx-02")
    run_id = client.post("/api/maintenance/runs/create", json={
        "hostnames": ["lnx-01", "lnx-02"], "patchMode": "Security", "batchSize": 2, "minReady": 0,
    }).get_json()["RunID"]
    advance(client)

    vm = db.vm("lnx-01")
    refused = client.post(f"/api/vms/{vm['VMID']}/undrain", json={})
    assert refused.status_code == 409 and f"maintenance run {run_id}" in refused.get_json()["error"]
    assert client.post(f"/api/vms/{vm['VMID']}/maintenance", json={"enabled": False}).status_code == 409

    # Cancelling lets the hosts being patched finish.
    cancelled = client.post(f"/api/maintenance/runs/{run_id}/cancel", json={})
    assert cancelled.status_code == 200 and cancelled.get_json()["Run"]["Status"] == "Stopping"
    assert advance(client)["Status"] == "Stopping"


def test_scaling_surges_while_a_run_waits_for_a_spare(client, db, remote, patch_host, azure):
    db.add_vm("lnx-01")
    db.add_vm("lnx-02")
    db.add_vm("lnx-spare", power="Off", network="Unreachable")
    run_id = client.post("/api/maintenance/runs/create", json={
        "hostnames": ["lnx-01", "lnx-02"], "patchMode": "Security", "batchSize": 1,
    }).get_json()["RunID"]

    advance(client)
    run = client.get("/api/maintenance/runs").get_json()["Active"]
    assert run["RunID"] == run_id and run["SurgeRequested"] is True and "spare ready host" in run["WaitReason"]
    assert run["MinReadyInForce"] == 2 and run["ReadyNow"] == 2

    preview = client.get("/api/scaling/preview").get_json()
    assert preview["Phase"]["MaintenanceSurge"] is True and preview["Phase"]["MinVMs"] == 3
    scaled = client.post("/api/scaling/trigger", json={})
    assert scaled.status_code == 200 and scaled.get_json()["PoweredOnVMs"] == ["lnx-spare"]
