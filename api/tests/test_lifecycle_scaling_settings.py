"""Release lifecycle, scaling and host settings behavior added in Phase 1."""

import json
import types

import pytest


LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"


class _Host:
    """Stands in for run_remote_command with scripted (returncode, stdout) replies."""

    def __init__(self, *responses, default=(0, "")):
        self.calls = []
        self._responses = list(responses)
        self._default = default

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        self.calls.append({"hostname": hostname, "command": command, "timeout": timeout})
        returncode, stdout = self._responses.pop(0) if self._responses else self._default
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=""), f"avdadmin@{hostname}"

    @property
    def commands(self):
        return [call["command"] for call in self.calls]


# ---------------------------------------------------------------------------
# Cleaning a returned user off its host.


def test_forced_cleanup_clears_a_missing_lease_and_deletes_the_user(app_module, monkeypatch):
    host = _Host((0, "__LEASE_ACTION=missing__\n"), (0, "__LEASE_ACTION=cleared__\n"), (0, ""))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    outcome = app_module.cleanup_remote_user("lnxhost-01", "alice", LEASE_ID, force=True, timeout=30)

    assert outcome == app_module.CLEANUP_COMPLETED
    assert host.commands[0] == f"sudo /usr/local/bin/manage-lease.sh clear alice {LEASE_ID}"
    assert host.commands[1] == "sudo /usr/local/bin/manage-lease.sh clear-any alice"
    assert "userdel -r alice" in host.commands[2]
    assert all(call["timeout"] == 30 for call in host.calls)


def test_unforced_cleanup_still_leaves_a_mismatched_lease_alone(app_module, monkeypatch):
    host = _Host((0, "__LEASE_ACTION=mismatch__\n"))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    assert app_module.cleanup_remote_user("lnxhost-01", "alice", LEASE_ID) == app_module.CLEANUP_SKIPPED
    assert len(host.calls) == 1


@pytest.mark.parametrize("marker", ["__LEASE_ACTION=in-use__", "__LEASE_ACTION=cleared-in-use__"])
def test_a_signed_in_user_keeps_the_host_pending(app_module, monkeypatch, marker):
    host = _Host((0, f"{marker}\n"))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    assert app_module.cleanup_remote_user("lnxhost-01", "alice", LEASE_ID, force=True) == app_module.CLEANUP_IN_USE
    assert all("userdel" not in command for command in host.commands)


def test_a_failed_userdel_is_not_mistaken_for_a_clean_host(app_module, monkeypatch, caplog):
    """userdel exits 8 while processes still run as the user; the account is still there."""
    host = _Host((0, "__LEASE_ACTION=cleared__\n"), (1, "__USERDEL_FAILED__=8\n"))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    assert app_module.cleanup_remote_user("lnxhost-01", "alice", LEASE_ID, force=True) == app_module.CLEANUP_FAILED
    assert "userdel exit 8" in caplog.text


def test_only_harmless_userdel_exit_codes_count_as_success(app_module, monkeypatch):
    host = _Host((0, "__LEASE_ACTION=cleared__\n"), (0, ""))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    app_module.cleanup_remote_user("lnxhost-01", "alice", LEASE_ID)

    delete_command = host.commands[1]
    assert "case $status in 0|6|12) exit 0 ;; esac" in delete_command
    assert "|| echo" not in delete_command


def test_the_vm_is_only_marked_clean_after_the_host_is_clean(app_module, fake_db, monkeypatch):
    monkeypatch.setattr(app_module, "cleanup_remote_user", lambda *a, **k: app_module.CLEANUP_FAILED)
    assert app_module.clean_up_returned_user(7, "lnxhost-07", "alice", LEASE_ID) == app_module.CLEANUP_FAILED
    assert not any(call["proc"] == "CompleteVmCleanup" for call in fake_db.calls)

    monkeypatch.setattr(app_module, "cleanup_remote_user", lambda *a, **k: app_module.CLEANUP_COMPLETED)
    fake_db.fetchone_rows["CompleteVmCleanup"] = {"VMID": 7, "CleanupPending": False}
    assert app_module.clean_up_returned_user(7, "lnxhost-07", "alice", LEASE_ID) == app_module.CLEANUP_COMPLETED
    assert fake_db.latest_call("CompleteVmCleanup")["params"] == (7, LEASE_ID, "alice")


def _returned_row(**overrides):
    row = {
        "VMID": 7, "Hostname": "lnxhost-07", "IPAddress": "10.0.0.7", "PowerState": "On",
        "NetworkStatus": "Reachable", "VmStatus": "Available", "LastUpdateDate": None,
        "ReturnedUsername": "alice", "ReturnedAvdHost": "avd-01", "ReturnedLeaseId": LEASE_ID,
        "CleanupPending": True, "ResultType": "Expired",
    }
    row.update(overrides)
    return row


def test_manual_return_claims_cleans_up_and_completes(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["ReturnVm"] = _returned_row()
    fake_db.fetchone_rows["CompleteVmCleanup"] = {"VMID": 7, "CleanupPending": False}
    host = _Host((0, "__LEASE_ACTION=cleared__\n"), (0, ""))
    monkeypatch.setattr(app_module, "run_remote_command", host)

    response = client.post("/api/vms/7/return")

    assert response.status_code == 200
    body = response.get_json()
    assert body["CleanupResult"] == "Completed"
    assert body["CleanupPending"] is False
    procs = [call["proc"] for call in fake_db.calls]
    assert procs.index("ReturnVm") < procs.index("CompleteVmCleanup")


def test_manual_return_reports_pending_cleanup_while_the_user_is_signed_in(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["ReturnVm"] = _returned_row()
    monkeypatch.setattr(app_module, "run_remote_command", _Host((0, "__LEASE_ACTION=in-use__\n")))

    body = client.post("/api/vms/7/return").get_json()

    assert body["CleanupResult"] == "InUse"
    assert body["CleanupPending"] is True
    assert not any(call["proc"] == "CompleteVmCleanup" for call in fake_db.calls)


def test_manual_return_hides_sql_errors(client, fake_db):
    fake_db.fetchone_rows["ReturnVm"] = {"Message": "deadlock on db-prod-01", "ErrorNumber": 1205}
    response = client.post("/api/vms/7/return")
    assert response.status_code == 500
    assert "db-prod-01" not in response.get_data(as_text=True)


def test_the_sweep_cleans_reachable_hosts_and_skips_the_rest(app_module, client, fake_db, monkeypatch):
    fake_db.fetchall_rows["ReturnReleasedVms"] = [
        _returned_row(VMID=1, Hostname="lnxhost-01"),
        _returned_row(VMID=2, Hostname="lnxhost-02", NetworkStatus="Unreachable"),
        _returned_row(VMID=3, Hostname="lnxhost-03", ReturnedUsername=None, CleanupPending=False),
        _returned_row(VMID=4, Hostname="lnxhost-04", ResultType="Retry"),
    ]
    fake_db.fetchone_rows["CompleteVmCleanup"] = {"VMID": 1, "CleanupPending": False}
    cleaned = []

    def fake_cleanup(hostname, username, lease_id=None, force=False, timeout=120):
        cleaned.append((hostname, force, timeout))
        return app_module.CLEANUP_COMPLETED if hostname == "lnxhost-01" else app_module.CLEANUP_IN_USE

    monkeypatch.setattr(app_module, "cleanup_remote_user", fake_cleanup)

    response = client.post("/api/vms/released", json={})

    assert response.status_code == 200
    results = {row["VMID"]: row for row in response.get_json()}
    assert results[1]["CleanupResult"] == "Completed" and results[1]["CleanupPending"] is False
    assert results[2]["CleanupResult"] == "Skipped" and results[2]["CleanupPending"] is True
    assert results[3]["CleanupResult"] == "NotRequired" and results[3]["CleanupPending"] is False
    assert results[4]["CleanupResult"] == "InUse" and results[4]["CleanupPending"] is True
    assert sorted(cleaned) == [("lnxhost-01", True, 30), ("lnxhost-04", True, 30)]
    completed = [call for call in fake_db.calls if call["proc"] == "CompleteVmCleanup"]
    assert [call["params"][0] for call in completed] == [1]


def test_the_sweep_defers_work_it_cannot_start_before_the_deadline(app_module, client, fake_db, monkeypatch):
    fake_db.fetchall_rows["ReturnReleasedVms"] = [_returned_row()]
    monkeypatch.setattr(app_module, "SWEEP_DEADLINE_SECONDS", -1)
    monkeypatch.setattr(app_module, "cleanup_remote_user", lambda *a, **k: pytest.fail("cleanup should not start"))

    body = client.post("/api/vms/released", json={}).get_json()

    assert body[0]["CleanupResult"] == "Deferred"
    assert body[0]["CleanupPending"] is True


@pytest.mark.parametrize("outcome,status", [("Completed", 200), ("InUse", 409), ("Failed", 502)])
def test_retrying_cleanup_reports_the_outcome(app_module, client, fake_db, monkeypatch, outcome, status):
    fake_db.fetchone_rows["BeginVmCleanupRetry"] = {
        "VMID": 7, "Hostname": "lnxhost-07", "PowerState": "On", "NetworkStatus": "Reachable",
        "CleanupUsername": "alice", "CleanupLeaseId": LEASE_ID,
    }
    monkeypatch.setattr(app_module, "clean_up_returned_user", lambda *a, **k: outcome)

    response = client.post("/api/vms/7/cleanup")

    assert response.status_code == status
    body = response.get_json()
    assert body["CleanupResult"] == outcome
    assert body["CleanupPending"] is (outcome != "Completed")
    assert ("message" in body) is (outcome == "Completed")


def test_retrying_cleanup_on_a_clean_vm_is_a_conflict(client, fake_db):
    response = client.post("/api/vms/7/cleanup")
    assert response.status_code == 409
    assert response.get_json() == {"error": "VM 7 has no pending cleanup."}


@pytest.mark.parametrize("result,status", [
    ("Updated", 200), ("Unchanged", 200), ("Assigned", 409), ("InvalidState", 409), ("NotFound", 404),
])
def test_maintenance_results_map_to_statuses(client, fake_db, result, status):
    fake_db.fetchone_rows["SetVmMaintenance"] = {
        "Result": result, "VMID": 5 if result != "NotFound" else None,
        "Hostname": "lnxhost-05" if result != "NotFound" else None, "VmStatus": "Maintenance",
    }
    response = client.post("/api/vms/5/maintenance", json={"enabled": True})
    assert response.status_code == status
    assert fake_db.latest_call("SetVmMaintenance")["params"] == (5, True)


@pytest.mark.parametrize("body", [{}, {"enabled": "yes"}, {"enabled": 1}])
def test_maintenance_requires_a_boolean(client, fake_db, body):
    assert client.post("/api/vms/5/maintenance", json=body).status_code == 400
    assert fake_db.calls == []


def test_network_status_records_only_valid_values(client, fake_db):
    assert client.post("/api/vms/5/network-status", json={"networkstatus": "Maybe"}).status_code == 400
    assert client.post("/api/vms/5/network-status", json={"networkstatus": "Reachable"}).status_code == 404

    fake_db.fetchone_rows["SetVmNetworkStatus"] = {
        "VMID": 5, "Hostname": "lnxhost-05", "PowerState": "On", "NetworkStatus": "Reachable", "Changed": 1,
    }
    response = client.post("/api/vms/5/network-status", json={"networkstatus": "Reachable"})
    assert response.status_code == 200
    assert response.get_json()["Changed"] is True


@pytest.mark.parametrize("body", [
    {"powerstate": "Sideways"}, {"networkstatus": "Maybe"}, {"vmstatus": "Draining"},
])
def test_update_attributes_rejects_values_the_database_would_refuse(client, fake_db, body):
    response = client.post("/api/vms/5/update-attributes", json=body)
    assert response.status_code == 400
    assert fake_db.calls == []


NEW_VM = {"hostname": "lnxhost-09", "ipaddress": "10.0.0.9", "powerstate": "On",
          "networkstatus": "Reachable", "vmstatus": "Available"}


def test_adding_a_vm_stores_blank_optional_fields_as_null(client, fake_db):
    """Checkout only uses hosts whose Username is NULL, so '' would strand the new host."""
    fake_db.fetchone_rows["AddVm"] = {"NewVMID": 9}

    response = client.post("/api/vms/add", json={**NEW_VM, "username": "  ", "avdhost": "", "description": ""})

    assert response.status_code == 201
    params = fake_db.latest_call("AddVm")["params"]
    assert params[5:] == (None, None, None)


def test_a_username_can_only_be_recorded_for_an_assigned_host(client, fake_db):
    response = client.post("/api/vms/add", json={**NEW_VM, "username": "alice"})
    assert response.status_code == 400
    assert fake_db.calls == []


def test_release_hides_sql_errors(client, fake_db):
    fake_db.fetchone_rows["ReleaseVm"] = {"Message": "timeout on db-prod-01", "ErrorNumber": -2}
    response = client.post("/api/vms/lnxhost-01/release", json={})
    assert response.status_code == 500
    assert "db-prod-01" not in response.get_data(as_text=True)


# ---------------------------------------------------------------------------
# Scaling.


class _Compute:
    def __init__(self, power_states=None, fail=()):
        self.power_states = power_states or {}
        self.fail = set(fail)
        self.operations = []
        client = self

        class _Vms:
            def instance_view(self, resource_group, name):
                code = client.power_states.get(name)
                if code is None:
                    error = Exception("not found")
                    error.status_code = 404
                    raise error
                return types.SimpleNamespace(statuses=[
                    types.SimpleNamespace(code="ProvisioningState/succeeded"),
                    types.SimpleNamespace(code=code),
                ])

            def _operate(self, operation, resource_group, name):
                if (operation, name) in client.fail:
                    raise RuntimeError("AllocationFailed in region xyz")
                client.operations.append((operation, name))

            def begin_start(self, resource_group, name):
                self._operate("start", resource_group, name)

            def begin_power_off(self, resource_group, name):
                self._operate("power_off", resource_group, name)

            def begin_deallocate(self, resource_group, name):
                self._operate("deallocate", resource_group, name)

        self.virtual_machines = _Vms()


def _use_compute(app_module, monkeypatch, compute):
    monkeypatch.setattr(app_module, "ComputeManagementClient", lambda *a, **k: compute)


def test_scaling_reconciles_power_states_from_azure_first(app_module, client, fake_db, monkeypatch):
    fake_db.fetchall_rows["GetVms"] = [
        {"VMID": 1, "Hostname": "lnxhost-01"}, {"VMID": 2, "Hostname": "lnxhost-02"}, {"VMID": 3, "Hostname": "gone"},
    ]
    fake_db.fetchall_rows["SyncVmPowerStates"] = [
        {"VMID": 2, "Hostname": "lnxhost-02", "PreviousPowerState": "On", "PowerState": "Off"},
    ]
    _use_compute(app_module, monkeypatch, _Compute({
        "lnxhost-01": "PowerState/running", "lnxhost-02": "PowerState/deallocated",
    }))

    response = client.post("/api/scaling/trigger", json={})

    assert response.status_code == 200
    body = response.get_json()
    assert body["PowerStateCorrections"] == [{"Hostname": "lnxhost-02", "PowerState": "Off"}]
    assert body["PowerSyncFailed"] is False
    sent = json.loads(fake_db.latest_call("SyncVmPowerStates")["params"][0])
    assert sorted(sent, key=lambda item: item["hostname"]) == [
        {"hostname": "lnxhost-01", "powerState": "On"},
        {"hostname": "lnxhost-02", "powerState": "Off"},
    ]
    procs = [call["proc"] for call in fake_db.calls]
    assert procs.index("SyncVmPowerStates") < procs.index("TriggerScalingLogic")


def test_scaling_runs_even_when_azure_cannot_be_read(app_module, client, fake_db, monkeypatch):
    class _Broken:
        def instance_view(self, *args):
            raise RuntimeError("throttled")

    compute = _Compute()
    compute.virtual_machines.instance_view = _Broken().instance_view
    _use_compute(app_module, monkeypatch, compute)

    response = client.post("/api/scaling/trigger", json={})

    assert response.status_code == 200
    assert response.get_json()["PowerSyncFailed"] is True
    assert any(call["proc"] == "TriggerScalingLogic" for call in fake_db.calls)


def test_scaling_executes_actions_by_stop_mode_and_accepts_the_legacy_spelling(app_module, client, fake_db, monkeypatch):
    fake_db.fetchall_rows["GetVms"] = []
    fake_db.fetchall_rows["TriggerScalingLogic"] = [
        {"ActionType": "PowerOn", "VMName": "lnxhost-01", "VMID": 1, "StopMode": None, "PreviousNetworkStatus": "Unreachable", "ActivityID": 9},
        {"ActionType": "PoweredOn", "VMName": "lnxhost-02", "VMID": 2},
        {"ActionType": "PowerOff", "VMName": "lnxhost-03", "VMID": 3, "StopMode": "PowerOff", "PreviousNetworkStatus": "Reachable", "ActivityID": 9},
        {"ActionType": "PowerOff", "VMName": "lnxhost-04", "VMID": 4, "StopMode": "Deallocate", "PreviousNetworkStatus": "Reachable", "ActivityID": 9},
    ]
    compute = _Compute()
    _use_compute(app_module, monkeypatch, compute)

    body = client.post("/api/scaling/trigger", json={}).get_json()

    assert compute.operations == [
        ("start", "lnxhost-01"), ("start", "lnxhost-02"), ("power_off", "lnxhost-03"), ("deallocate", "lnxhost-04"),
    ]
    assert body["PoweredOnVMs"] == ["lnxhost-01", "lnxhost-02"]
    assert body["PoweredOffVMs"] == ["lnxhost-03"]
    assert body["DeallocatedVMs"] == ["lnxhost-04"]
    assert body["Failed"] == []


def test_a_refused_power_operation_restores_the_recorded_state(app_module, client, fake_db, monkeypatch):
    fake_db.fetchall_rows["GetVms"] = []
    fake_db.fetchall_rows["TriggerScalingLogic"] = [
        {"ActionType": "PowerOn", "VMName": "lnxhost-01", "VMID": 1, "StopMode": None, "PreviousNetworkStatus": "Unreachable", "ActivityID": 9},
    ]
    _use_compute(app_module, monkeypatch, _Compute(fail={("start", "lnxhost-01")}))

    response = client.post("/api/scaling/trigger", json={})

    body = response.get_json()
    assert body["PoweredOnVMs"] == []
    assert body["Failed"] == [{"VMName": "lnxhost-01", "Action": "PowerOn", "Error": "The Azure start operation could not be requested."}]
    assert "region xyz" not in response.get_data(as_text=True)
    assert fake_db.latest_call("UpdateVmAttributes")["params"] == (1, "Off", "Unreachable", None)
    assert fake_db.latest_call("AppendScalingActivityNote")["params"][0] == 9


# ---------------------------------------------------------------------------
# Scaling rules.

VALID_RULE = {
    "minvms": 2, "maxvms": 10, "scaleupratio": 70, "scaleupincrement": 2,
    "scaledownratio": 30, "scaledownincrement": 1,
}


@pytest.mark.parametrize("override,field", [
    ({"minvms": 0}, "minvms"),
    ({"maxvms": 2}, "maxvms"),
    ({"scaleupratio": 101}, "scaleupratio"),
    ({"scaleupratio": 20}, "scaleupratio"),
    ({"scaleupincrement": 0}, "scaleupincrement"),
    ({"scaledownincrement": "one"}, "scaledownincrement"),
    ({"minvms": True}, "minvms"),
    ({"stopmode": "Hibernate"}, "stopmode"),
])
def test_rule_creation_names_the_invalid_field(client, fake_db, override, field):
    response = client.post("/api/scaling/rules/create", json={**VALID_RULE, **override})
    assert response.status_code == 400
    assert field in response.get_json()["error"]
    assert fake_db.calls == []


def test_rule_creation_passes_the_stop_mode(client, fake_db):
    fake_db.fetchone_rows["CreateScalingRule"] = {"NewRuleID": 3, "ActiveRuleID": 3, "Message": None}
    response = client.post("/api/scaling/rules/create", json={**VALID_RULE, "stopmode": "deallocate"})
    assert response.status_code == 201
    assert response.get_json() == {"NewRuleID": 3}
    assert fake_db.latest_call("CreateScalingRule")["params"][-1] == "Deallocate"


def test_a_second_rule_is_refused_with_the_active_rule(client, fake_db):
    fake_db.fetchone_rows["CreateScalingRule"] = {
        "NewRuleID": None, "ActiveRuleID": 1, "Message": "A scaling rule already exists.",
    }
    response = client.post("/api/scaling/rules/create", json=VALID_RULE)
    assert response.status_code == 409
    assert response.get_json() == {"error": "Only one scaling rule is applied. Edit rule #1 instead.", "ActiveRuleID": 1}


def test_rule_updates_validate_the_resulting_rule(client, fake_db):
    fake_db.fetchone_rows["GetScalingRuleDetails"] = {
        "RuleID": 1, "MinVMs": 2, "MaxVMs": 10, "ScaleUpRatio": 70.0, "ScaleUpIncrement": 2,
        "ScaleDownRatio": 30.0, "ScaleDownIncrement": 1, "StopMode": "PowerOff", "IsActive": True,
    }
    response = client.post("/api/scaling/rules/1/update", json={"minvms": 10})
    assert response.status_code == 400
    assert "maxvms" in response.get_json()["error"]
    assert not any(call["proc"] == "UpdateScalingRule" for call in fake_db.calls)

    response = client.post("/api/scaling/rules/1/update", json={"stopmode": "Deallocate"})
    assert response.status_code == 200
    assert fake_db.latest_call("UpdateScalingRule")["params"] == (1, 2, 10, 70.0, 2, 30.0, 1, "Deallocate")


def test_updating_a_missing_rule_is_not_found(client, fake_db):
    assert client.post("/api/scaling/rules/9/update", json={"minvms": 3}).status_code == 404


# ---------------------------------------------------------------------------
# Host settings.

SETTINGS_ROW = {
    "SettingsID": 1, "GracePeriodSeconds": 1200, "ReconcileIntervalSeconds": 60,
    "WatcherDebounceSeconds": 10, "WatcherSettleSeconds": 2, "IdleTimeoutSeconds": 0,
    "IdleWarningSeconds": 120, "ScreenLockEnabled": False, "DisableLockScreen": True,
    "ScreenIdleDelaySeconds": 0, "ScreenLockDelaySeconds": 0, "ScreenLockSettingsLocked": True,
    "PreserveSessionsOnDisconnect": False, "SettingsVersion": 4,
}


def test_hosts_do_not_receive_new_settings_while_they_are_off(auth_client, fake_db):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = dict(SETTINGS_ROW)

    host_view = auth_client({"roles": ["LinuxHost"]}).get("/api/hosts/settings", headers=auth_client.headers).get_json()
    portal_view = auth_client({"roles": ["Reader"], "scp": "access_as_user"}).get(
        "/api/hosts/settings", headers=auth_client.headers
    ).get_json()

    assert "PreserveSessionsOnDisconnect" not in host_view
    assert portal_view["PreserveSessionsOnDisconnect"] is False


def test_hosts_receive_a_new_setting_once_it_is_on(auth_client, fake_db):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = {**SETTINGS_ROW, "PreserveSessionsOnDisconnect": True}
    host_view = auth_client({"roles": ["LinuxHost"]}).get("/api/hosts/settings", headers=auth_client.headers).get_json()
    assert host_view["PreserveSessionsOnDisconnect"] is True


def test_preserving_sessions_cannot_be_combined_with_the_screen_lock(client, fake_db):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = {**SETTINGS_ROW, "ScreenLockEnabled": True}
    response = client.post("/api/hosts/settings/update", json={"PreserveSessionsOnDisconnect": True})
    assert response.status_code == 400
    assert "ScreenLockEnabled" in response.get_json()["error"]
    assert not any(call["proc"] == "UpdateLinuxHostSettings" for call in fake_db.calls)


def test_the_preserve_setting_is_saved(client, fake_db):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = dict(SETTINGS_ROW)
    fake_db.fetchone_rows["UpdateLinuxHostSettings"] = {**SETTINGS_ROW, "PreserveSessionsOnDisconnect": True, "SettingsVersion": 5}

    response = client.post("/api/hosts/settings/update", json={"PreserveSessionsOnDisconnect": True})

    assert response.status_code == 200
    assert response.get_json()["PreserveSessionsOnDisconnect"] is True
    params = fake_db.latest_call("UpdateLinuxHostSettings")["params"]
    assert params[-2] is True


def test_apply_now_pushes_in_parallel_and_reports_hosts_it_did_not_reach(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = dict(SETTINGS_ROW)
    fake_db.fetchall_rows["GetVms"] = [
        {"VMID": 2, "Hostname": "lnxhost-02", "PowerState": "On", "NetworkStatus": "Reachable"},
        {"VMID": 1, "Hostname": "lnxhost-01", "PowerState": "On", "NetworkStatus": "Reachable"},
        {"VMID": 3, "Hostname": "lnxhost-03", "PowerState": "Off", "NetworkStatus": "Unreachable"},
    ]
    pushed = []

    def fake_apply(hostname, settings, timeout=120):
        pushed.append((hostname, dict(settings), timeout))
        return hostname != "lnxhost-02", "Applied." if hostname != "lnxhost-02" else "The host could not be reached."

    monkeypatch.setattr(app_module, "apply_host_settings_to_host", fake_apply)

    body = client.post("/api/hosts/settings/apply", json={}).get_json()

    assert body["TargetCount"] == 2
    assert body["SucceededCount"] == 1
    assert [result["Hostname"] for result in body["Results"]] == ["lnxhost-01", "lnxhost-02"]
    assert body["NotAttempted"] == []
    assert {hostname for hostname, _, _ in pushed} == {"lnxhost-01", "lnxhost-02"}
    assert all(timeout == app_module.APPLY_HOST_TIMEOUT_SECONDS for _, _, timeout in pushed)


def test_apply_now_stops_starting_pushes_at_the_deadline(app_module, client, fake_db, monkeypatch):
    fake_db.fetchone_rows["GetLinuxHostSettings"] = dict(SETTINGS_ROW)
    fake_db.fetchall_rows["GetVms"] = [{"VMID": 1, "Hostname": "lnxhost-01", "PowerState": "On", "NetworkStatus": "Reachable"}]
    monkeypatch.setattr(app_module, "APPLY_DEADLINE_SECONDS", -1)
    monkeypatch.setattr(app_module, "apply_host_settings_to_host", lambda *a, **k: pytest.fail("should not push"))

    body = client.post("/api/hosts/settings/apply", json={}).get_json()

    assert body["TargetCount"] == 1
    assert body["Results"] == []
    assert body["NotAttempted"] == ["lnxhost-01"]


def test_the_ssh_push_leaves_out_settings_that_are_off(app_module, monkeypatch, fake_db):
    captured = {}

    def fake_run(hostname, command, stdin_input=None, timeout=120):
        captured["document"] = json.loads(stdin_input)
        captured["timeout"] = timeout
        return types.SimpleNamespace(returncode=0, stdout="", stderr=""), f"avdadmin@{hostname}"

    monkeypatch.setattr(app_module, "run_remote_command", fake_run)
    settings = app_module.normalize_host_settings(SETTINGS_ROW)

    applied, _message = app_module.apply_host_settings_to_host("lnxhost-01", settings, timeout=30)

    assert applied is True
    assert "PreserveSessionsOnDisconnect" not in captured["document"]
    assert captured["document"]["SettingsVersion"] == 4
    assert captured["timeout"] == 30
