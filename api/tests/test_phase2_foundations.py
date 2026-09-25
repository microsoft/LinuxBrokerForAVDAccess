"""Phase 2 foundations: the audit log, host actions and drain, and host heartbeats."""

import json
import re
import types
from datetime import datetime
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]

ADMIN_USER = {
    "roles": ["FullAccess"], "scp": "access_as_user", "oid": "oid-alice",
    "preferred_username": "alice@contoso.com",
}
OPERATOR_USER = {
    "roles": ["Operator"], "scp": "access_as_user", "oid": "oid-olga",
    "preferred_username": "olga@contoso.com",
}
READER_USER = {"roles": ["Reader"], "scp": "access_as_user", "oid": "oid-rita", "preferred_username": "rita@contoso.com"}
LINUX_HOST_MIRID = "/subscriptions/sub/resourcegroups/rg/providers/Microsoft.Compute/virtualMachines/{}"

UNASSIGNED_VM = {
    "VMID": 5, "Hostname": "lnx-05", "PowerState": "Off", "NetworkStatus": "Unreachable",
    "VmStatus": "Available", "Username": None, "LeaseId": None,
}
ASSIGNED_VM = {
    "VMID": 5, "Hostname": "lnx-05", "PowerState": "On", "NetworkStatus": "Reachable",
    "VmStatus": "CheckedOut", "Username": "alice", "LeaseId": "8ff6eb09-90ca-4efa-8ea1-695761f950f7",
}


def power_row(result="Requested", **overrides):
    row = {
        "Result": result, "VMID": 5, "Hostname": "lnx-05", "Action": "Start",
        "PreviousPowerState": "Off", "PreviousNetworkStatus": "Unreachable", "PreviousVmStatus": "Available",
        "Username": None, "AvdHost": None, "PreviousLeaseId": None, "PreviousReleasedDate": None,
        "Assigned": False, "EndedAssignment": False, "StopMode": "PowerOff",
    }
    row.update(overrides)
    return row


class Compute:
    """Stands in for ComputeManagementClient and records what the API asked Azure to do."""

    def __init__(self, fail=(), power_states=None):
        self.operations = []
        self.fail = set(fail)
        self.power_states = power_states or {}
        compute = self

        class VirtualMachines:
            def _operate(self, operation, resource_group, name):
                if operation in compute.fail:
                    raise RuntimeError("AllocationFailed: internal detail that must not leak")
                compute.operations.append((operation, name))

            def begin_start(self, resource_group, name):
                self._operate("start", resource_group, name)

            def begin_power_off(self, resource_group, name):
                self._operate("power_off", resource_group, name)

            def begin_deallocate(self, resource_group, name):
                self._operate("deallocate", resource_group, name)

            def begin_restart(self, resource_group, name):
                self._operate("restart", resource_group, name)

            def instance_view(self, resource_group, name):
                code = compute.power_states.get(name)
                if code is None:
                    error = Exception("not found")
                    error.status_code = 404
                    raise error
                return types.SimpleNamespace(statuses=[types.SimpleNamespace(code=code)])

        self.virtual_machines = VirtualMachines()


@pytest.fixture
def compute(app_module, monkeypatch):
    fake = Compute()
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)
    return fake


def procs(fake_db):
    return [call["proc"] for call in fake_db.calls]


# ---------------------------------------------------------------------------
# 2.4 Audit log


AGENT_ONLY_ENDPOINTS = {"acknowledge_host_settings", "record_host_heartbeat", "purge_audit_log"}


def test_every_mutating_route_is_audited_or_agent_only(app_module):
    unaudited = []
    for rule in app_module.app.url_map.iter_rules():
        if "POST" not in rule.methods or rule.endpoint in app_module.READ_ONLY_POST_ENDPOINTS:
            continue
        view = app_module.app.view_functions[rule.endpoint]
        if not getattr(view, "_audit_action", None) and rule.endpoint not in AGENT_ONLY_ENDPOINTS:
            unaudited.append(rule.endpoint)
    assert unaudited == [], "a mutating route has no @audited action"


def test_a_portal_action_is_audited_with_the_signed_in_user(auth_client, fake_db, audit_entries):
    fake_db.fetchone_rows["DeleteVm"] = {"DeletedVMID": 5, "Hostname": "lnx-05", "VmStatus": "Available", "Username": None}
    client = auth_client(ADMIN_USER)

    assert client.post("/api/vms/5/delete", headers=auth_client.headers).status_code == 200

    [entry] = audit_entries
    assert entry["action"] == "vm.delete" and entry["outcome"] == "success"
    assert entry["targetType"] == "vm" and entry["targetId"] == "lnx-05"
    assert (entry["actorOid"], entry["actorName"], entry["actorType"]) == ("oid-alice", "alice@contoso.com", "user")
    assert json.loads(entry["detailJson"]) == {"status": 200, "vmid": 5, "vmStatus": "Available", "username": None}
    assert entry["correlationId"]


def test_a_failed_action_is_audited_with_the_curated_error(auth_client, fake_db, audit_entries):
    client = auth_client(ADMIN_USER)

    assert client.post("/api/vms/9/delete", headers=auth_client.headers).status_code == 404

    [entry] = audit_entries
    assert entry["outcome"] == "failure" and entry["targetId"] == "9"
    assert json.loads(entry["detailJson"])["error"] == "VM with VMID 9 could not be deleted or was not found."


def test_agents_routine_calls_are_not_audited(auth_client, fake_db, audit_entries):
    fake_db.fetchone_rows["ReleaseVm"] = {"ReleaseStatus": "Released", "Hostname": "lnx-05"}
    client = auth_client({"roles": ["LinuxHost"], "xms_mirid": LINUX_HOST_MIRID.format("lnx-05")})

    assert client.post("/api/vms/lnx-05/release", json={"username": "bob"}, headers=auth_client.headers).status_code == 200
    assert audit_entries == []


def test_denials_on_mutating_routes_are_audited_and_reads_are_not(auth_client, fake_db, audit_entries):
    client = auth_client(READER_USER)

    assert client.post("/api/vms/5/delete", headers=auth_client.headers).status_code == 403
    [denied] = audit_entries
    assert denied["action"] == "vm.delete" and denied["outcome"] == "denied"
    assert denied["actorName"] == "rita@contoso.com" and denied["targetId"] == "5"
    detail = json.loads(denied["detailJson"])
    assert detail["requiredRoles"] == ["FullAccess"] and detail["callerRoles"] == ["Reader"]
    assert fake_db.calls == []

    unassigned = auth_client({"scp": "access_as_user"})
    assert unassigned.get("/api/vms", headers=auth_client.headers).status_code == 403
    assert unassigned.post("/api/vms/history", json={}, headers=auth_client.headers).status_code == 403
    assert len(audit_entries) == 1


def test_a_flood_of_denials_is_capped_per_caller(app_module, auth_client, fake_db, audit_entries, monkeypatch):
    monkeypatch.setattr(app_module, "DENIAL_AUDITS_PER_MINUTE", 3)
    client = auth_client(READER_USER)

    for vmid in range(5):
        assert client.post(f"/api/vms/{vmid}/delete", headers=auth_client.headers).status_code == 403

    assert len(audit_entries) == 3
    other = auth_client({**READER_USER, "oid": "oid-someone-else"})
    assert other.post("/api/vms/1/delete", headers=auth_client.headers).status_code == 403
    assert len(audit_entries) == 4


def test_auditing_never_fails_the_operation(app_module, client, fake_db, audit_entries, monkeypatch):
    fake_db.raise_on_execute["WriteAuditEntry"] = "audit table is gone"
    assert audit_entries.original({
        "action": "vm.start", "targetType": "vm", "targetId": "lnx-01", "outcome": "success",
        "actorOid": None, "actorName": None, "actorType": "system", "detailJson": None, "correlationId": "c",
    }) is False

    def broken(entry):
        raise RuntimeError("unexpected")

    monkeypatch.setattr(app_module, "write_audit_entry", broken)
    fake_db.fetchall_rows["FinalizeVmDrains"] = [{"VMID": 3, "Hostname": "lnx-03", "VmStatus": "Maintenance"}]
    assert client.post("/api/vms/released", json={}).status_code == 200


def test_the_actor_is_named_from_its_token(app_module):
    assert app_module.audit_actor({"oid": "o", "scp": "access_as_user", "upn": "u@contoso.com"}) == ("o", "u@contoso.com", "user")
    assert app_module.audit_actor({"oid": "o", "xms_mirid": LINUX_HOST_MIRID.format("lnx-07")}) == ("o", "lnx-07", "service")
    assert app_module.audit_actor({
        "oid": "o", "xms_mirid": "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Web/sites/task-linuxbroker-prod",
    })[1] == "task-linuxbroker-prod"
    assert app_module.audit_actor({"oid": "o", "appid": "11111111-2222"}) == ("o", "11111111-2222", "service")
    assert app_module.audit_actor({}) == (None, None, "system")


def test_audit_detail_is_bounded(app_module):
    text = app_module.audit_detail_json({"blob": "x" * 20000})
    assert len(text) <= app_module.AUDIT_DETAIL_MAX_CHARS
    assert json.loads(text)["truncated"] is True
    assert app_module.audit_detail_json({}) is None


def test_the_audit_log_reads_with_filters_and_parses_detail(client, fake_db):
    fake_db.fetchall_rows["GetAuditLogPaged"] = [{
        "AuditId": 7, "OccurredAtUtc": "2026-01-02T03:04:05.123Z", "ActorOid": "o", "ActorName": "alice@contoso.com",
        "ActorType": "user", "Action": "vm.stop", "TargetType": "vm", "TargetId": "lnx-01", "Outcome": "failure",
        "DetailJson": '{"status": 502}', "CorrelationId": "abc", "TotalCount": 31,
    }]

    response = client.get(
        "/api/audit?from=2026-01-01&to=2026-01-31&actor=alice&action=vm.&targetType=vm&target=lnx"
        "&outcome=FAILURE&page=2&per_page=10"
    )

    assert response.status_code == 200
    body = response.get_json()
    assert body["total"] == 31 and body["total_pages"] == 4 and body["page"] == 2
    [item] = body["items"]
    assert item["Detail"] == {"status": 502} and "DetailJson" not in item and "TotalCount" not in item
    params = fake_db.latest_call("GetAuditLogPaged")["params"]
    assert params == (datetime(2026, 1, 1), datetime(2026, 2, 1), "alice", "vm.", "vm", "lnx", "failure", 10, 10)


@pytest.mark.parametrize("query,message", [
    ("from=yesterday", "from must be a date"),
    ("to=2026-13-01", "to must be a date"),
    ("outcome=maybe", "outcome must be success, failure or denied."),
])
def test_the_audit_log_rejects_unusable_filters(client, fake_db, query, message):
    response = client.get(f"/api/audit?{query}")
    assert response.status_code == 400
    assert message in response.get_json()["error"]
    assert fake_db.calls == []


def test_the_audit_log_accepts_iso_times(app_module):
    assert app_module.parse_audit_time("2026-01-02T03:04:05Z", "from") == datetime(2026, 1, 2, 3, 4, 5)
    assert app_module.parse_audit_time("2026-01-02T03:04", "to", end_of_day=True) == datetime(2026, 1, 2, 3, 4)
    assert app_module.parse_audit_time("", "from") is None


def test_the_purge_works_off_a_backlog_and_audits_itself(client, fake_db, audit_entries, app_module):
    fake_db.fetchall_sequence["PurgeAuditLog"] = [
        [{"Deleted": 2000, "MoreRemaining": True}],
        [{"Deleted": 12, "MoreRemaining": False}],
    ]

    body = client.post("/api/audit/purge", json={}).get_json()

    assert body == {"Deleted": 2012, "RetentionDays": app_module.AUDIT_RETENTION_DAYS, "MoreRemaining": False}
    calls = [call for call in fake_db.calls if call["proc"] == "PurgeAuditLog"]
    assert [call["params"] for call in calls] == [(app_module.AUDIT_RETENTION_DAYS, 2000)] * 2
    assert "@MaxBatches = 1" in calls[0]["sql"]
    # Every batch is committed before the next starts, so its locks are released.
    assert fake_db.commits >= 2
    [entry] = audit_entries
    assert entry["action"] == "audit.purge" and json.loads(entry["detailJson"])["deleted"] == 2012


def test_the_purge_stops_at_its_batch_limit(client, fake_db, app_module, monkeypatch):
    monkeypatch.setattr(app_module, "AUDIT_PURGE_MAX_BATCHES", 3)
    fake_db.fetchone_rows["PurgeAuditLog"] = {"Deleted": 2000, "MoreRemaining": True}

    body = client.post("/api/audit/purge", json={}).get_json()

    assert body["Deleted"] == 6000 and body["MoreRemaining"] is True
    assert procs(fake_db).count("PurgeAuditLog") == 3


def test_a_purge_that_fails_part_way_still_records_what_it_removed(client, fake_db, audit_entries):
    fake_db.fetchall_sequence["PurgeAuditLog"] = [[{"Deleted": 2000, "MoreRemaining": True}]]

    class FromTheSecondBatch(dict):
        def __contains__(self, proc):
            return proc == "PurgeAuditLog" and procs(fake_db).count("PurgeAuditLog") > 1

        def __getitem__(self, proc):
            return "connection lost"

    fake_db.raise_on_execute = FromTheSecondBatch()

    response = client.post("/api/audit/purge", json={})

    assert response.status_code == 500
    [entry] = audit_entries
    assert entry["action"] == "audit.purge" and entry["outcome"] == "failure"
    assert json.loads(entry["detailJson"])["deleted"] == 2000


SETTINGS_ROW = {
    "SettingsID": 1, "GracePeriodSeconds": 1200, "ReconcileIntervalSeconds": 60,
    "WatcherDebounceSeconds": 10, "WatcherSettleSeconds": 2, "IdleTimeoutSeconds": 0,
    "IdleWarningSeconds": 120, "ScreenLockEnabled": False, "DisableLockScreen": True,
    "ScreenIdleDelaySeconds": 0, "ScreenLockDelaySeconds": 0, "ScreenLockSettingsLocked": True,
    "PreserveSessionsOnDisconnect": False, "SettingsVersion": 4,
}


def test_settings_changes_are_attributed_to_the_signed_in_user(auth_client, fake_db, audit_entries):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = dict(SETTINGS_ROW)
    fake_db.fetchone_rows["UpdateLinuxHostSettings"] = {**SETTINGS_ROW, "GracePeriodSeconds": 1800, "SettingsVersion": 5}
    client = auth_client(ADMIN_USER)

    response = client.post(
        "/api/hosts/settings/update",
        json={"GracePeriodSeconds": 1800, "IdleWarningSeconds": 120, "updatedBy": "someone-else"},
        headers=auth_client.headers,
    )

    assert response.status_code == 200
    assert fake_db.latest_call("UpdateLinuxHostSettings")["params"][-1] == "alice@contoso.com"
    [entry] = audit_entries
    detail = json.loads(entry["detailJson"])
    assert entry["action"] == "settings.update" and entry["targetId"] == "Global"
    assert detail["changes"] == {"GracePeriodSeconds": {"from": 1200, "to": 1800}}
    assert detail["previousVersion"] == 4 and detail["settingsVersion"] == 5


def test_settings_history_is_normalized(client, fake_db):
    fake_db.fetchall_rows["GetLinuxHostSettingsHistory"] = [
        {**SETTINGS_ROW, "SettingsVersion": 5, "UpdatedBy": "alice@contoso.com",
         "ValidFromUtc": "2026-09-01T10:00:00Z", "ValidToUtc": None, "IsCurrent": True},
        {**SETTINGS_ROW, "ScreenLockEnabled": 1, "UpdatedBy": None,
         "ValidFromUtc": "2026-08-01T10:00:00Z", "ValidToUtc": "2026-09-01T10:00:00Z", "IsCurrent": False},
    ]

    response = client.get("/api/hosts/settings/history?limit=500")

    assert response.status_code == 200
    current, previous = response.get_json()
    assert current["SettingsVersion"] == 5 and current["IsCurrent"] is True and current["UpdatedBy"] == "alice@contoso.com"
    assert previous["ScreenLockEnabled"] is True and previous["ValidToUtc"] == "2026-09-01T10:00:00Z"
    assert "SettingsID" not in current
    assert fake_db.latest_call("GetLinuxHostSettingsHistory")["params"] == (200,)


def test_scaling_actions_and_corrections_are_audited(app_module, client, fake_db, audit_entries, monkeypatch):
    fake_db.fetchall_rows["GetVms"] = [{"VMID": 1, "Hostname": "lnx-01"}]
    fake_db.fetchall_rows["SyncVmPowerStates"] = [
        {"VMID": 1, "Hostname": "lnx-01", "PreviousPowerState": "On", "PowerState": "Off"},
    ]
    fake_db.fetchall_rows["TriggerScalingLogic"] = [
        {"ActionType": "PowerOn", "VMName": "lnx-02", "VMID": 2, "StopMode": None, "PreviousNetworkStatus": "Unreachable", "ActivityID": 4},
        {"ActionType": "PowerOff", "VMName": "lnx-03", "VMID": 3, "StopMode": "Deallocate", "PreviousNetworkStatus": "Reachable", "ActivityID": 4},
    ]
    fake = Compute(fail={"deallocate"}, power_states={"lnx-01": "PowerState/stopped"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)

    assert client.post("/api/scaling/trigger", json={}).status_code == 200

    summary = [(e["action"], e["targetId"], e["outcome"]) for e in audit_entries]
    assert summary == [
        ("vm.power_corrected", "lnx-01", "success"),
        ("scaling.power_on", "lnx-02", "success"),
        ("scaling.deallocate", "lnx-03", "failure"),
    ]
    assert json.loads(audit_entries[0]["detailJson"]) == {"vmid": 1, "from": "On", "to": "Off"}


def test_the_sweep_audits_what_it_changed(app_module, client, fake_db, audit_entries, monkeypatch):
    fake_db.fetchall_rows["ReturnReleasedVms"] = [
        {"VMID": 1, "Hostname": "lnx-01", "PowerState": "On", "NetworkStatus": "Reachable",
         "ReturnedUsername": "alice", "ReturnedLeaseId": None, "ResultType": "Expired"},
        {"VMID": 2, "Hostname": "lnx-02", "PowerState": "On", "NetworkStatus": "Reachable",
         "ReturnedUsername": "bob", "ReturnedLeaseId": None, "ResultType": "Retry"},
        {"VMID": 3, "Hostname": "lnx-03", "PowerState": "On", "NetworkStatus": "Reachable",
         "ReturnedUsername": "carol", "ReturnedLeaseId": None, "ResultType": "Retry"},
    ]
    outcomes = {"lnx-01": app_module.CLEANUP_IN_USE, "lnx-02": app_module.CLEANUP_COMPLETED, "lnx-03": app_module.CLEANUP_FAILED}
    monkeypatch.setattr(app_module, "cleanup_remote_user", lambda hostname, *a, **k: outcomes[hostname])
    fake_db.fetchone_rows["CompleteVmCleanup"] = {"VMID": 2, "Hostname": "lnx-02", "VmStatus": "Maintenance", "CleanupPending": False, "DrainCompleted": True}
    fake_db.fetchall_rows["FinalizeVmDrains"] = [{"VMID": 9, "Hostname": "lnx-09", "VmStatus": "Maintenance"}]

    assert len(client.post("/api/vms/released", json={}).get_json()) == 3

    summary = [(e["action"], e["targetId"]) for e in audit_entries]
    # A retry that still cannot clean its host changed nothing and is not recorded again.
    assert summary == [
        ("vm.release_expired", "lnx-01"),
        ("vm.drain_completed", "lnx-02"),
        ("vm.cleanup_completed", "lnx-02"),
        ("vm.drain_completed", "lnx-09"),
    ]
    assert json.loads(audit_entries[0]["detailJson"])["cleanupResult"] == app_module.CLEANUP_IN_USE


def test_the_sweep_tolerates_a_database_without_finalize(client, fake_db):
    fake_db.raise_on_execute["FinalizeVmDrains"] = "Could not find stored procedure 'FinalizeVmDrains'."
    response = client.post("/api/vms/released", json={})
    assert response.status_code == 200 and response.get_json() == []


# ---------------------------------------------------------------------------
# 2.1 Host actions and drain


def test_start_records_the_state_before_asking_azure(client, fake_db, compute, audit_entries):
    fake_db.fetchone_rows["GetVmDetails"] = dict(UNASSIGNED_VM)
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row()

    response = client.post("/api/vms/5/start")

    assert response.status_code == 202
    body = response.get_json()
    assert body["Hostname"] == "lnx-05" and body["Action"] == "Start" and "Mode" not in body
    assert compute.operations == [("start", "lnx-05")]
    assert fake_db.latest_call("BeginVmPowerAction")["params"] == (5, "Start", False)
    assert procs(fake_db).index("GetVmDetails") < procs(fake_db).index("BeginVmPowerAction")
    assert fake_db.commits == 1


@pytest.mark.parametrize("body,rule_mode,operation", [
    ({}, "PowerOff", "power_off"),
    ({}, "Deallocate", "deallocate"),
    ({"mode": "powerOff"}, "Deallocate", "power_off"),
    ({"mode": "Deallocate"}, "PowerOff", "deallocate"),
])
def test_stop_uses_the_requested_or_the_rule_stop_mode(client, fake_db, compute, body, rule_mode, operation):
    fake_db.fetchone_rows["GetVmDetails"] = {**UNASSIGNED_VM, "PowerState": "On", "NetworkStatus": "Reachable"}
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(Action="Stop", PreviousPowerState="On", StopMode=rule_mode)

    response = client.post("/api/vms/5/stop", json=body)

    assert response.status_code == 202
    assert compute.operations == [(operation, "lnx-05")]
    assert response.get_json()["Mode"] == ("Deallocate" if operation == "deallocate" else "PowerOff")


def test_an_unknown_stop_mode_is_rejected_before_anything_changes(client, fake_db, compute):
    response = client.post("/api/vms/5/stop", json={"mode": "Hibernate"})
    assert response.status_code == 400
    assert fake_db.calls == [] and compute.operations == []


def test_stopping_a_host_in_use_needs_an_admin_who_names_it(auth_client, fake_db, compute, audit_entries):
    fake_db.fetchone_rows["GetVmDetails"] = dict(ASSIGNED_VM)
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(
        Action="Stop", PreviousPowerState="On", Username="alice", Assigned=True, EndedAssignment=True,
    )

    operator = auth_client(OPERATOR_USER)
    refused = operator.post("/api/vms/5/stop", json={"confirm": "lnx-05"}, headers=auth_client.headers)
    assert refused.status_code == 403
    assert "Only an administrator" in refused.get_json()["error"]
    assert "BeginVmPowerAction" not in procs(fake_db)
    assert audit_entries[-1]["outcome"] == "denied" and audit_entries[-1]["targetId"] == "lnx-05"

    admin = auth_client(ADMIN_USER)
    unconfirmed = admin.post("/api/vms/5/stop", json={}, headers=auth_client.headers)
    assert unconfirmed.status_code == 409
    assert unconfirmed.get_json()["requiresConfirmation"] is True
    assert unconfirmed.get_json()["Username"] == "alice"
    assert admin.post("/api/vms/5/stop", json={"confirm": "wrong"}, headers=auth_client.headers).status_code == 409
    assert compute.operations == []

    confirmed = admin.post("/api/vms/5/stop", json={"confirm": "LNX-05"}, headers=auth_client.headers)
    assert confirmed.status_code == 202
    assert confirmed.get_json()["EndedAssignment"] is True
    assert "assignment ended" in confirmed.get_json()["message"]
    assert fake_db.latest_call("BeginVmPowerAction")["params"] == (5, "Stop", True)
    assert compute.operations == [("power_off", "lnx-05")]
    detail = json.loads(audit_entries[-1]["detailJson"])
    assert audit_entries[-1]["action"] == "vm.stop" and audit_entries[-1]["outcome"] == "success"
    assert detail["endedAssignment"] is True and detail["username"] == "alice"


def test_restarting_a_host_in_use_is_confirmed_and_keeps_the_assignment(auth_client, fake_db, compute):
    fake_db.fetchone_rows["GetVmDetails"] = dict(ASSIGNED_VM)
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(Action="Restart", PreviousPowerState="On", Username="alice", Assigned=True)
    admin = auth_client(ADMIN_USER)

    response = admin.post("/api/vms/5/restart", json={"confirm": "lnx-05"}, headers=auth_client.headers)

    assert response.status_code == 202 and response.get_json()["EndedAssignment"] is False
    assert compute.operations == [("restart", "lnx-05")]


def test_an_idle_host_can_be_stopped_by_an_operator(auth_client, fake_db, compute):
    fake_db.fetchone_rows["GetVmDetails"] = {**UNASSIGNED_VM, "PowerState": "On"}
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(Action="Stop", PreviousPowerState="On")
    operator = auth_client(OPERATOR_USER)

    assert operator.post("/api/vms/5/stop", json={}, headers=auth_client.headers).status_code == 202
    assert fake_db.latest_call("BeginVmPowerAction")["params"] == (5, "Stop", False)


def test_a_refused_azure_operation_restores_the_recorded_state(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["GetVmDetails"] = dict(UNASSIGNED_VM)
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row()
    fake_db.fetchone_rows["RevertVmPowerAction"] = {"Result": "Reverted", "VMID": 5, "AssignmentRestored": False}
    failing = Compute(fail={"start"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: failing)

    response = client.post("/api/vms/5/start")

    assert response.status_code == 502
    assert response.get_json() == {"error": "Azure refused to start lnx-05. Its recorded state was restored."}
    assert fake_db.latest_call("RevertVmPowerAction")["params"] == (
        5, "Off", "Unreachable", False, "Available", None, None, None, None,
    )
    assert "UpdateVmAttributes" not in procs(fake_db)


LEASE = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"
ENDED_ASSIGNMENT = dict(
    Action="Stop", PreviousPowerState="On", PreviousNetworkStatus="Reachable", PreviousVmStatus="Released",
    Username="alice", AvdHost="avd-01", PreviousLeaseId=LEASE, PreviousReleasedDate=datetime(2026, 9, 1, 8, 30),
    Assigned=True, EndedAssignment=True,
)


@pytest.mark.parametrize("revert,message,detail", [
    ({"Result": "Reverted", "AssignmentRestored": True},
     "Azure refused to stop lnx-05. Its recorded state was restored.",
     {"stateRestored": True, "assignmentRestored": True}),
    ({"Result": "Reverted", "AssignmentRestored": False},
     "Azure refused to stop lnx-05. Its power state was restored, but alice's assignment could not be, so it stays ended.",
     {"stateRestored": True, "assignmentRestored": False}),
    ({"Result": "NotFound", "AssignmentRestored": False},
     "Azure refused to stop lnx-05, and the broker could not restore its recorded state. Check the host before trying again.",
     {"stateRestored": False}),
])
def test_a_refused_stop_gives_the_assignment_back(app_module, auth_client, fake_db, monkeypatch, audit_entries,
                                                   revert, message, detail):
    fake_db.fetchone_rows["GetVmDetails"] = {**ASSIGNED_VM, "VmStatus": "Released"}
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(**ENDED_ASSIGNMENT)
    fake_db.fetchone_rows["RevertVmPowerAction"] = revert
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: Compute(fail={"power_off"}))

    response = auth_client(ADMIN_USER).post("/api/vms/5/stop", json={"confirm": "lnx-05"}, headers=auth_client.headers)

    assert response.status_code == 502
    assert response.get_json() == {"error": message}
    # The revert gets back everything the stop cleared, from what BeginVmPowerAction returned.
    assert fake_db.latest_call("RevertVmPowerAction")["params"] == (
        5, "On", "Reachable", True, "Released", "alice", "avd-01", LEASE, datetime(2026, 9, 1, 8, 30),
    )
    entry = audit_entries[-1]
    assert entry["action"] == "vm.stop" and entry["outcome"] == "failure"
    assert detail.items() <= json.loads(entry["detailJson"]).items()


def test_a_refused_action_whose_revert_fails_says_so(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["GetVmDetails"] = dict(UNASSIGNED_VM)
    fake_db.fetchone_rows["BeginVmPowerAction"] = power_row()
    fake_db.raise_on_execute["RevertVmPowerAction"] = "connection lost"
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: Compute(fail={"start"}))

    response = client.post("/api/vms/5/start")

    assert response.status_code == 502
    assert "could not restore its recorded state" in response.get_json()["error"]


@pytest.mark.parametrize("vm,result,status,text", [
    (None, None, 404, "was not found"),
    (dict(UNASSIGNED_VM), "NotFound", 404, "was not found"),
    (dict(UNASSIGNED_VM), "Assigned", 409, "was just assigned"),
    (dict(UNASSIGNED_VM), "InvalidState", 409, "Start it instead"),
    (dict(UNASSIGNED_VM), "InvalidAction", 500, "Unable to restart"),
])
def test_power_action_results_map_to_statuses(client, fake_db, compute, vm, result, status, text):
    fake_db.fetchone_rows["GetVmDetails"] = vm
    if result:
        fake_db.fetchone_rows["BeginVmPowerAction"] = power_row(result)

    response = client.post("/api/vms/5/restart")

    assert response.status_code == status
    assert text in response.get_json()["error"]
    assert compute.operations == []


@pytest.mark.parametrize("path,result,status,text", [
    ("drain", "Draining", 200, "is draining. alice keeps the session"),
    ("drain", "Drained", 200, "in maintenance now"),
    ("drain", "Unchanged", 200, "already out of rotation"),
    ("undrain", "ReturnedToService", 200, "back in service"),
    ("undrain", "Unchanged", 200, "already in service"),
    ("drain", "InvalidState", 409, "Repair its status first"),
    ("undrain", "NotFound", 404, "was not found"),
])
def test_drain_results_map_to_statuses_and_messages(client, fake_db, path, result, status, text):
    fake_db.fetchone_rows["SetVmDrain"] = {
        "Result": result, "VMID": 5, "Hostname": "lnx-05", "VmStatus": "CheckedOut",
        "DrainRequested": result == "Draining", "Username": "alice", "CleanupPending": False,
    }

    response = client.post(f"/api/vms/5/{path}")

    assert response.status_code == status
    body = response.get_json()
    assert text in (body.get("message") or body.get("error"))
    assert fake_db.latest_call("SetVmDrain")["params"] == (5, path == "drain")


def test_power_sync_reports_the_corrections(app_module, client, fake_db, monkeypatch, audit_entries):
    fake_db.fetchall_rows["GetVms"] = [{"VMID": 1, "Hostname": "lnx-01"}]
    fake_db.fetchall_rows["SyncVmPowerStates"] = [
        {"VMID": 1, "Hostname": "lnx-01", "PreviousPowerState": "Off", "PowerState": "On"},
    ]
    fake = Compute(power_states={"lnx-01": "PowerState/running"})
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: fake)

    body = client.post("/api/vms/sync").get_json()

    assert body["PowerStateCorrections"] == [{"Hostname": "lnx-01", "PowerState": "On"}]
    assert body["PowerSyncFailed"] is False and "Corrected the power state of 1 host" in body["message"]
    assert [e["action"] for e in audit_entries] == ["vm.power_corrected"]


def test_the_summary_reports_draining_hosts(client, fake_db):
    fake_db.fetchone_rows["GetVmSummary"] = {"TotalVMs": 3, "Draining": 2}
    assert client.get("/api/vms/summary").get_json()["Draining"] == 2


# ---------------------------------------------------------------------------
# 2.2 Heartbeat and fleet health


HEARTBEAT = {
    "agentVersion": "1.0.0",
    "scriptVersions": {"release-session.sh": "1.0.0", "create-user.sh": None, "unknown.sh": "9.9.9"},
    "settingsVersion": 7,
    "os": {"id": "rhel", "version": "9.4", "name": "Red Hat Enterprise Linux 9.4 (Plow)\u0007"},
    "kernel": "5.14.0-427.el9.x86_64",
    "desktop": "gnome",
    "xrdp": {"version": "0.10.1", "active": True},
    "nfs": {"reachable": "false", "mounts": 1},
    "loadAverage": 0.426,
    "cpuCount": 4,
    "memoryAvailableMb": 1024,
    "memoryTotalMb": 16000,
    "rootDiskFreePct": 150,
    "uptimeSeconds": 3600,
    "sessions": [
        {"username": "alice", "state": "active", "sessionStart": 1790000000, "disconnectedSince": None, "idleSeconds": 12},
        {"username": "../etc", "state": "active"},
        {"username": "bob", "state": "sleeping", "idleSeconds": -5},
    ],
    "extra": {"anything": True},
}


def recorded(fake_db):
    fake_db.fetchone_rows["RecordHostHeartbeat"] = {"Result": "Recorded", "Hostname": "lnx-01", "ReceivedAtUtc": "2026-09-24T12:00:00.000Z"}


def test_a_heartbeat_is_normalized_before_it_reaches_sql(client, fake_db):
    recorded(fake_db)

    response = client.post("/api/hosts/lnx-01/heartbeat", json=HEARTBEAT)

    assert response.status_code == 200
    assert response.get_json() == {"Hostname": "lnx-01", "ReceivedAtUtc": "2026-09-24T12:00:00.000Z"}
    hostname, document = fake_db.latest_call("RecordHostHeartbeat")["params"]
    document = json.loads(document)
    assert hostname == "lnx-01"
    assert "extra" not in document and "rootDiskFreePct" not in document
    assert document["scriptVersions"] == {"release-session.sh": "1.0.0", "create-user.sh": None}
    assert document["os"]["name"] == "Red Hat Enterprise Linux 9.4 (Plow)"
    assert document["nfs"] == {"reachable": False, "mounts": 1}
    assert document["loadAverage"] == 0.43
    assert document["sessions"] == [
        {"username": "alice", "state": "active", "sessionStart": 1790000000, "disconnectedSince": None, "idleSeconds": 12},
        {"username": "bob", "state": "unknown", "sessionStart": None, "disconnectedSince": None, "idleSeconds": None},
    ]


def test_an_empty_session_list_is_kept(app_module):
    document, problem = app_module.normalize_heartbeat({"agentVersion": "1.0.0", "sessions": []})
    assert problem is None and document == {"agentVersion": "1.0.0", "sessions": []}


@pytest.mark.parametrize("body,status", [
    ("[1, 2, 3]", 400),
    ("not json", 400),
    ("{\"pad\": \"" + "x" * (40 * 1024) + "\"}", 413),
], ids=["array", "not-json", "too-large"])
def test_heartbeats_that_are_not_objects_or_too_large_are_refused(client, fake_db, body, status):
    response = client.post("/api/hosts/lnx-01/heartbeat", data=body, content_type="application/json")
    assert response.status_code == status
    assert "RecordHostHeartbeat" not in procs(fake_db)


def test_a_heartbeat_hostname_must_be_a_hostname(client, fake_db):
    assert client.post("/api/hosts/bad%20host/heartbeat", json={}).status_code == 400


def test_a_host_can_only_report_its_own_heartbeat(auth_client, fake_db, audit_entries):
    recorded(fake_db)
    impostor = auth_client({"roles": ["LinuxHost"], "xms_mirid": LINUX_HOST_MIRID.format("lnx-02")})

    refused = impostor.post("/api/hosts/lnx-01/heartbeat", json=HEARTBEAT, headers=auth_client.headers)
    assert refused.status_code == 403
    assert "RecordHostHeartbeat" not in procs(fake_db)
    [entry] = audit_entries
    assert entry["action"] == "host.heartbeat" and entry["outcome"] == "denied" and entry["actorName"] == "lnx-02"

    itself = auth_client({"roles": ["LinuxHost"], "xms_mirid": LINUX_HOST_MIRID.format("LNX-01")})
    assert itself.post("/api/hosts/lnx-01/heartbeat", json=HEARTBEAT, headers=auth_client.headers).status_code == 200
    # Accepted heartbeats are routine agent traffic and are not audited.
    assert len(audit_entries) == 1


def test_refused_heartbeats_are_capped_like_other_denials(app_module, auth_client, fake_db, audit_entries, monkeypatch):
    monkeypatch.setattr(app_module, "DENIAL_AUDITS_PER_MINUTE", 2)
    recorded(fake_db)
    impostor = auth_client({"roles": ["LinuxHost"], "oid": "oid-lnx-02", "xms_mirid": LINUX_HOST_MIRID.format("lnx-02")})

    for _ in range(5):
        assert impostor.post("/api/hosts/lnx-01/heartbeat", json=HEARTBEAT, headers=auth_client.headers).status_code == 403

    assert len(audit_entries) == 2


def test_a_heartbeat_from_an_unregistered_host_is_not_found(client, fake_db):
    fake_db.fetchone_rows["RecordHostHeartbeat"] = {"Result": "NotFound", "Hostname": "lnx-99"}
    response = client.post("/api/hosts/lnx-99/heartbeat", json={"agentVersion": "1.0.0"})
    assert response.status_code == 404 and response.get_json() == {"error": "No VM found with Hostname lnx-99."}


def health_row(hostname, **values):
    row = {
        "VMID": 1, "Hostname": hostname, "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "Available",
        "DrainRequested": False, "CleanupPending": False, "Username": None, "AppliedSettingsVersion": 7,
        "CurrentSettingsVersion": 7, "ReconcileIntervalSeconds": 60, "LastHeartbeatUtc": "2026-09-24T12:00:00Z",
        "HeartbeatAgeSeconds": 30, "AgentVersion": "1.1.0",
        "ScriptVersionsJson": '{"release-session.sh": "1.1.0", "create-user.sh": "1.1.0"}',
        "ReportedSettingsVersion": 7, "OsId": "rhel", "OsVersion": "9.4", "OsName": "RHEL 9.4", "KernelVersion": "5.14",
        "Desktop": "gnome", "XrdpVersion": "0.10.1", "XrdpActive": True, "NfsReachable": True, "NfsMountCount": 1,
        "LoadAverage": 0.5, "CpuCount": 4, "MemoryAvailableMb": 8000, "MemoryTotalMb": 16000, "RootDiskFreePct": 60,
        "UptimeSeconds": 100, "SessionCount": 1, "SessionsJson": '[{"username": "alice", "state": "active"}]',
    }
    row.update(values)
    return row


def test_fleet_health_flags_what_an_operator_must_act_on(client, fake_db):
    fake_db.fetchall_rows["GetHostHealth"] = [
        health_row("healthy"),
        health_row("stale", HeartbeatAgeSeconds=600, XrdpActive=False),
        health_row("silent", HeartbeatAgeSeconds=None, LastHeartbeatUtc=None, AgentVersion=None, ScriptVersionsJson=None),
        health_row("off", PowerState="Off", HeartbeatAgeSeconds=9000, AppliedSettingsVersion=3),
        health_row("broken", XrdpActive=False, NfsReachable=False, RootDiskFreePct=4),
        health_row("old", AgentVersion="0.9.0"),
        health_row("half", ScriptVersionsJson='{"release-session.sh": "1.1.0", "manage-lease.sh": null}'),
        health_row("drift", AppliedSettingsVersion=None),
    ]

    body = client.get("/api/hosts/health").get_json()

    flags = {host["Hostname"]: host["Flags"] for host in body["Hosts"]}
    assert flags == {
        "healthy": [],
        "stale": ["stale"],
        "silent": ["no-heartbeat"],
        "off": [],
        "broken": ["xrdp-down", "nfs-unreachable", "low-disk"],
        "old": ["agent-outdated"],
        "half": ["agent-outdated"],
        "drift": ["settings-drift"],
    }
    statuses = {host["Hostname"]: host["Status"] for host in body["Hosts"]}
    assert statuses["healthy"] == "healthy" and statuses["off"] == "off" and statuses["stale"] == "attention"
    assert body["Summary"] == {
        "Total": 8, "PoweredOn": 7, "Reporting": 5, "Healthy": 1, "Attention": 6, "Off": 1,
        "NoHeartbeat": 1, "Stale": 1, "XrdpDown": 1, "NfsUnreachable": 1, "LowDisk": 1,
        "AgentOutdated": 2, "SettingsDrift": 1,
    }
    healthy = body["Hosts"][0]
    assert healthy["Sessions"] == [{"username": "alice", "state": "active"}]
    assert healthy["ScriptVersions"]["create-user.sh"] == "1.1.0"
    assert body["ExpectedAgentVersion"] == "1.1.0" and body["StaleAfterSeconds"] == 180


def test_fleet_health_for_one_host(client, fake_db):
    fake_db.fetchall_rows["GetHostHealth"] = [health_row("lnx-01")]
    assert client.get("/api/hosts/health?hostname=lnx-01").get_json()["Hosts"][0]["Hostname"] == "lnx-01"
    assert fake_db.latest_call("GetHostHealth")["params"] == ("lnx-01",)
    assert client.get("/api/hosts/health?hostname=bad%20host").status_code == 400


def test_fleet_health_summary_only_leaves_the_hosts_out(client, fake_db):
    fake_db.fetchall_rows["GetHostHealth"] = [health_row("lnx-01"), health_row("lnx-02", HeartbeatAgeSeconds=None)]
    body = client.get("/api/hosts/health?summary=true").get_json()
    assert "Hosts" not in body
    assert body["Summary"]["Healthy"] == 1 and body["Summary"]["NoHeartbeat"] == 1


def test_versions_compare_numerically(app_module):
    assert app_module.version_tuple("1.10.0") > app_module.version_tuple("1.9.9")
    assert app_module.version_tuple("1.0.0-dev") == (1, 0, 0)
    assert app_module.version_tuple("2") == (2, 0, 0)
    assert app_module.version_tuple(None) is None and app_module.version_tuple("dev") is None
    assert app_module.heartbeat_stale_after(300) == 900 and app_module.heartbeat_stale_after(None) == 180


def test_every_host_script_declares_the_agent_version(app_module):
    scripts = sorted((REPO_ROOT / "linux_host").rglob("*.sh"))
    scripts = [path for path in scripts if "tests" not in path.relative_to(REPO_ROOT / "linux_host").parts]
    assert scripts, "no host scripts found"

    declared = {}
    for path in scripts:
        match = re.search(r'^LINUXBROKER_AGENT_VERSION="([^"]+)"$', path.read_text(encoding="utf-8"), re.MULTILINE)
        declared[path.relative_to(REPO_ROOT).as_posix()] = match.group(1) if match else None

    assert set(declared.values()) == {app_module.HOST_AGENT_VERSION}, declared
    installed = {Path(name).name for name in declared}
    assert set(app_module.HEARTBEAT_SCRIPTS) <= installed
