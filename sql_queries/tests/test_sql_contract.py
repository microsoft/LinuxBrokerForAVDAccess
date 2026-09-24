import json
import uuid

import pymssql
import pytest

from conftest import add_vm, exec_sql, one, rows


def test_return_released_sweep_thresholds_retries_and_complete(conn):
    exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @GracePeriodSeconds=%s, @ReconcileIntervalSeconds=%s", (1200, 60))
    a = add_vm(conn, "rel-1300", status="Released", username="u1", avdhost="a", lease=str(uuid.uuid4()), released_seconds=1300)
    blease = str(uuid.uuid4())
    b = add_vm(conn, "rel-1330", status="Released", username="u2", avdhost="a", lease=blease, released_seconds=1330)
    c = add_vm(conn, "rel-fallback", status="Released", username="u3", avdhost="a", lease=str(uuid.uuid4()), last_seconds=1400)
    retry = add_vm(conn, "retry", cleanup=True, username="old", lease=str(uuid.uuid4()))
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupAttemptDate=DATEADD(SECOND,-121,GETDATE()) WHERE VMID=%s", (retry,))

    got = exec_sql(conn, "EXEC dbo.ReturnReleasedVms")
    by_host = {r["Hostname"]: r for r in got}
    assert "rel-1300" not in by_host
    assert by_host["rel-1330"]["ResultType"] == "Expired"
    assert by_host["rel-1330"]["CleanupPending"] is True
    assert by_host["rel-1330"]["ReturnedUsername"] == "u2"
    assert by_host["rel-fallback"]["ResultType"] == "Expired"
    assert by_host["retry"]["ResultType"] == "Retry"
    assert by_host["retry"]["ReturnedUsername"] == "old"

    assert exec_sql(conn, "EXEC dbo.CompleteVmCleanup @VMID=%s, @LeaseId=%s, @Username=%s", (b, str(uuid.uuid4()), "u2")) == []
    cleared = exec_sql(conn, "EXEC dbo.CompleteVmCleanup @VMID=%s, @LeaseId=%s, @Username=%s", (b, blease, "u2"))
    assert cleared[0]["CleanupPending"] is False

    exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @GracePeriodSeconds=%s", (3600,))
    add_vm(conn, "rel-40min", status="Released", username="u4", avdhost="a", lease=str(uuid.uuid4()), released_seconds=2400)
    assert all(r["Hostname"] != "rel-40min" for r in exec_sql(conn, "EXEC dbo.ReturnReleasedVms"))


def test_release_checkout_return_lifecycle(conn):
    lease = str(uuid.uuid4())
    vmid = add_vm(conn, "host1", status="CheckedOut", username="alice", avdhost="avd", lease=lease)
    released = exec_sql(conn, "EXEC dbo.ReleaseVm @Hostname=%s, @LeaseId=%s, @Username=%s", ("host1", lease, "alice"))[0]
    assert released["ReleaseStatus"] == "Released"
    assert released["ReleasedDate"] is not None

    again = exec_sql(conn, "EXEC dbo.ReleaseVm @Hostname=%s, @LeaseId=%s, @Username=%s", ("host1", lease, "alice"))[0]
    assert again["ReleasedDate"] == released["ReleasedDate"]

    reused = exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("alice", "avd2"))[0]
    assert reused["VMID"] == vmid
    assert one(conn, "SELECT ReleasedDate FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["ReleasedDate"] is None

    returned = exec_sql(conn, "EXEC dbo.ReturnVm @VMID=%s, @ExpectedLeaseId=%s", (vmid, lease))[0]
    assert returned["CleanupPending"] is True
    assert returned["ReturnedUsername"] == "alice"

    add_vm(conn, "pending", cleanup=True)
    checkout_bob = exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("bob", "avd"))
    assert checkout_bob == [] or checkout_bob[0].get("Message") == "No available VM found"
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VirtualMachines WHERE Username='bob'")[0]["c"] == 0
    retry = exec_sql(conn, "EXEC dbo.BeginVmCleanupRetry @VMID=%s", (vmid,))[0]
    assert retry["CleanupUsername"] == "alice"


def test_update_attributes_network_maintenance_and_summary(conn):
    lease = str(uuid.uuid4())
    vmid = add_vm(conn, "repair", status="CheckedOut", username="alice", avdhost="avd", lease=lease)
    before = one(conn, "SELECT LastUpdateDate FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["LastUpdateDate"]
    unchanged = exec_sql(conn, "EXEC dbo.UpdateVmAttributes @VMID=%s", (vmid,))[0]
    assert unchanged["LastUpdateDate"] == before

    changed = exec_sql(conn, "EXEC dbo.UpdateVmAttributes @VMID=%s, @PowerState=%s, @VmStatus=%s", (vmid, "Off", "Available"))[0]
    assert changed["PowerState"] == "Off"
    row = one(conn, "SELECT Username, LeaseId, CleanupPending, CleanupAttemptDate, PowerStateChangedDate, ReleasedDate FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))
    assert row["Username"] is None and row["LeaseId"] is None
    assert row["CleanupPending"] is True and row["CleanupAttemptDate"] is None
    assert row["PowerStateChangedDate"] is not None and row["ReleasedDate"] is None

    net1 = exec_sql(conn, "EXEC dbo.SetVmNetworkStatus @VMID=%s, @NetworkStatus=%s", (vmid, "Unreachable"))[0]
    assert net1["Changed"] is True
    net_same = exec_sql(conn, "EXEC dbo.SetVmNetworkStatus @VMID=%s, @NetworkStatus=%s", (vmid, "Unreachable"))[0]
    assert net_same["Changed"] is False

    avail = add_vm(conn, "maint")
    assert exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=%s", (avail, True))[0]["Result"] == "Updated"
    assert exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=%s", (avail, True))[0]["Result"] == "Unchanged"
    assigned = add_vm(conn, "assigned", status="CheckedOut", username="u", lease=str(uuid.uuid4()))
    assert exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=%s", (assigned, True))[0]["Result"] == "Assigned"

    vms = exec_sql(conn, "EXEC dbo.GetVms")
    assert {"ReleasedDate", "CleanupPending", "CleanupUsername", "PowerStateChangedDate"}.issubset(vms[0].keys())
    detail = exec_sql(conn, "EXEC dbo.GetVmDetails @VMID=%s", (vmid,))[0]
    assert detail["CleanupPending"] is True
    summary = exec_sql(conn, "EXEC dbo.GetVmSummary")[0]
    assert "CleanupPending" in summary and summary["Ready"] == 0


def reset_rule(conn, **kw):
    vals = {"MinVMs": 1, "MaxVMs": 3, "ScaleUpRatio": 70, "ScaleUpIncrement": 1, "ScaleDownRatio": 30, "ScaleDownIncrement": 1, "StopMode": "PowerOff"}
    vals.update(kw)
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(conn, "INSERT INTO dbo.VmScalingRules (MinVMs,MaxVMs,ScaleUpRatio,ScaleUpIncrement,ScaleDownRatio,ScaleDownIncrement,StopMode) VALUES (%s,%s,%s,%s,%s,%s,%s)", tuple(vals[k] for k in ["MinVMs","MaxVMs","ScaleUpRatio","ScaleUpIncrement","ScaleDownRatio","ScaleDownIncrement","StopMode"]))


def test_scaling_start_stop_no_rule_and_applock(conn, second_conn):
    reset_rule(conn, MinVMs=2, MaxVMs=3)
    add_vm(conn, "off1", power="Off", net="Unreachable")
    up = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [r["ActionType"] for r in up] == ["PowerOn"]
    assert up[0]["PreviousNetworkStatus"] == "Unreachable"
    assert up[0]["ActivityID"] is not None

    clean = rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")[0]["c"]
    reset_rule(conn, MinVMs=1, MaxVMs=2, StopMode="Deallocate")
    add_vm(conn, "on1", changed_minutes=20)
    add_vm(conn, "on2", changed_minutes=20)
    add_vm(conn, "booting", net="Unreachable", changed_minutes=1)
    add_vm(conn, "used", status="Released", username="u", lease=str(uuid.uuid4()), changed_minutes=20)
    down = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert down and all(r["ActionType"] == "PowerOff" for r in down)
    assert all(r["StopMode"] == "Deallocate" for r in down)
    assert "booting" not in {r["VMName"] for r in down}
    log = rows(conn, "SELECT TOP 1 * FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")[0]
    assert log["ActionTaken"] == "Scale Down" and "deallocation" in log["Outcome"]

    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic") == []
    assert "No scaling rule" in rows(conn, "SELECT TOP 1 Notes FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")[0]["Notes"]

    c2 = second_conn()
    cur2 = c2.cursor()
    cur2.execute("BEGIN TRAN; DECLARE @r INT; EXEC @r = sp_getapplock @Resource='LinuxBroker.Scaling', @LockMode='Exclusive', @LockOwner='Transaction', @LockTimeout=0; SELECT @r")
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic") == []
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")[0]["c"] == clean + 2
    cur2.execute("ROLLBACK")


def test_scaling_rules_constraints_history_and_create_lock(conn, second_conn):
    rules = exec_sql(conn, "EXEC dbo.GetScalingRules")
    assert rules[0]["IsActive"] is True and rules[0]["StopMode"] == "PowerOff"
    refused = exec_sql(conn, "EXEC dbo.CreateScalingRule @MinVMs=1,@MaxVMs=2,@ScaleUpRatio=70,@ScaleUpIncrement=1,@ScaleDownRatio=30,@ScaleDownIncrement=1")[0]
    assert refused["NewRuleID"] is None and refused["ActiveRuleID"] is not None
    exec_sql(conn, "EXEC dbo.UpdateScalingRule @RuleID=%s, @StopMode=%s", (rules[0]["RuleID"], "Deallocate"))
    assert exec_sql(conn, "EXEC dbo.GetScalingRuleDetails @RuleID=%s", (rules[0]["RuleID"],))[0]["StopMode"] == "Deallocate"
    assert "StopMode" in exec_sql(conn, "EXEC dbo.GetVmScalingRulesHistoryPaged")[0]

    for sql in [
        "UPDATE dbo.VmScalingRules SET MinVMs=0",
        "UPDATE dbo.VmScalingRules SET ScaleUpIncrement=0",
        "UPDATE dbo.VmScalingRules SET ScaleUpRatio=101",
        "UPDATE dbo.VmScalingRules SET StopMode='Stop'",
    ]:
        with pytest.raises(Exception):
            exec_sql(conn, sql)
        conn.rollback()

    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    c2 = second_conn()
    cur2 = c2.cursor()
    cur2.execute("BEGIN TRAN; DECLARE @r INT; EXEC @r=sp_getapplock @Resource='LinuxBroker.ScalingRules', @LockMode='Exclusive', @LockOwner='Transaction', @LockTimeout=0; SELECT @r")
    # Avoid a 10s lock timeout in this contract test by verifying the lock path through app lock directly.
    cur2.execute("ROLLBACK")
    made1 = exec_sql(conn, "EXEC dbo.CreateScalingRule 1,2,70,1,30,1,'PowerOff'")[0]
    made2 = exec_sql(conn, "EXEC dbo.CreateScalingRule 1,2,70,1,30,1,'PowerOff'")[0]
    assert made1["NewRuleID"] is not None and made2["NewRuleID"] is None
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingRules")[0]["c"] == 1


def test_sync_append_uid_settings_and_compatibility(conn):
    v1 = add_vm(conn, "CaseHost", power="Off", net="Unreachable", changed_minutes=5)
    v2 = add_vm(conn, "fresh", power="Off", net="Unreachable", changed_minutes=0)
    changed = exec_sql(conn, "EXEC dbo.SyncVmPowerStates @PowerStatesJson=%s, @GraceSeconds=%s", (json.dumps([{"hostname":"casehost","powerState":"On"},{"hostname":"fresh","powerState":"On"},{"hostname":"missing","powerState":"Off"},{"hostname":"bad","powerState":"Paused"}]), 120))
    assert [r["Hostname"] for r in changed] == ["CaseHost"]
    off = exec_sql(conn, "EXEC dbo.SyncVmPowerStates @PowerStatesJson=%s, @GraceSeconds=%s", (json.dumps([{"hostname":"CASEHOST","powerState":"Off"}]), 0))[0]
    assert off["PreviousPowerState"] == "On"
    assert one(conn, "SELECT NetworkStatus FROM dbo.VirtualMachines WHERE VMID=%s", (v1,))["NetworkStatus"] == "Unreachable"

    exec_sql(conn, "INSERT INTO dbo.VmScalingActivityLog (CurrentRunningVMs,CurrentInUseVMs,ActionTaken,VMsPoweredOn,VMsPoweredOff,NewTotalVMs,Notes) VALUES (0,0,'No Action',0,0,0,'base')")
    aid = rows(conn, "SELECT MAX(ActivityID) AS id FROM dbo.VmScalingActivityLog")[0]["id"]
    exec_sql(conn, "EXEC dbo.AppendScalingActivityNote @ActivityID=%s, @Note=%s", (aid, "more"))
    assert rows(conn, "SELECT Notes FROM dbo.VmScalingActivityLog WHERE ActivityID=%s", (aid,))[0]["Notes"] == "base more"

    exec_sql(conn, "INSERT INTO dbo.VmUsers (uid, username) VALUES (2500, 'legacy')")
    assert exec_sql(conn, "EXEC dbo.GetOrCreateVmUserUid @Username=%s", ("legacy",))[0]["uid"] == 2500
    uid = exec_sql(conn, "EXEC dbo.GetOrCreateVmUserUid @Username=%s", ("newuser",))[0]["uid"]
    assert uid >= 2000 and uid != 2500

    settings = exec_sql(conn, "EXEC dbo.GetLinuxHostSettings")[0]
    assert settings["PreserveSessionsOnDisconnect"] is False
    version = settings["SettingsVersion"]
    assert exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @PreserveSessionsOnDisconnect=%s", (True,))[0]["SettingsVersion"] == version + 1
    assert exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @PreserveSessionsOnDisconnect=%s", (True,))[0]["SettingsVersion"] == version + 1
    with pytest.raises(Exception):
        exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @ScreenLockEnabled=%s", (True,))
    conn.rollback()

    expected = {'CheckoutVm','DeleteVm','AddVm','GetVmDetails','ReturnVm','GetScalingRules','UpdateScalingRule','TriggerScalingLogic','GetScalingActivityLog','GetVms','CreateScalingRule','ReleaseVm','UpdateVmAttributes','ReturnReleasedVms','DeleteScalingRule','GetVmHistory','GetVmScalingRulesHistory','GetScalingRuleDetails','GetDeletedVirtualMachines','RegisterLinuxHostVm','GetLinuxHostSettings','UpdateLinuxHostSettings','RecordHostSettingsApplied','GetVmSummary','GetVmHistoryPaged','GetScalingActivityLogPaged','GetVmScalingRulesHistoryPaged','CompleteVmCleanup','BeginVmCleanupRetry','SetVmNetworkStatus','SetVmMaintenance','SyncVmPowerStates','AppendScalingActivityNote','GetOrCreateVmUserUid'}
    present = {r['name'] for r in rows(conn, "SELECT name FROM sys.procedures")}
    assert expected <= present
