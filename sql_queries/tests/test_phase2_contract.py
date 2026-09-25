"""Contract tests for the Phase 2 foundation objects: the audit log (067-071), host actions
and drain (072-082 and 087), and host heartbeats (083-086)."""

import json
import uuid

import pytest

from conftest import add_vm, exec_sql, one, rows


def write_audit(conn, action, outcome="success", actor="alice@contoso.com", oid="oid-alice",
                actor_type="user", target_type="vm", target_id="lnx-01", detail=None, correlation=None):
    return exec_sql(
        conn,
        "EXEC dbo.WriteAuditEntry @ActorOid=%s, @ActorName=%s, @ActorType=%s, @Action=%s, "
        "@TargetType=%s, @TargetId=%s, @Outcome=%s, @DetailJson=%s, @CorrelationId=%s",
        (oid, actor, actor_type, action, target_type, target_id, outcome,
         None if detail is None else (detail if isinstance(detail, str) else json.dumps(detail)), correlation),
    )


def audit_page(conn, **filters):
    params = {
        "From": None, "To": None, "Actor": None, "Action": None, "TargetType": None,
        "TargetId": None, "Outcome": None, "Offset": 0, "PageSize": 50,
    }
    params.update(filters)
    names = list(params)
    sql = "EXEC dbo.GetAuditLogPaged " + ", ".join(f"@{name}=%s" for name in names)
    return exec_sql(conn, sql, tuple(params[name] for name in names))


# ---------------------------------------------------------------------------- 2.4 audit


def test_audit_entries_are_written_filtered_and_paged(conn):
    first = write_audit(conn, "vm.start", detail={"mode": "PowerOff"}, correlation="abc123")
    assert first[0]["AuditId"] > 0
    write_audit(conn, "vm.stop", outcome="failure", target_id="lnx-02")
    write_audit(conn, "vm.update_attributes", outcome="denied", actor="bob@contoso.com", oid="oid-bob")
    write_audit(conn, "settings.update", target_type="settings", target_id="Global")
    write_audit(conn, "scaling.power_on", actor="task-linuxbroker", oid="oid-task", actor_type="service", target_id="lnx-03")

    everything = audit_page(conn)
    assert len(everything) == 5
    assert everything[0]["TotalCount"] == 5
    # Newest first, and the timestamp is an ISO-8601 UTC string rather than a driver datetime.
    assert everything[0]["Action"] == "scaling.power_on"
    assert everything[0]["OccurredAtUtc"].endswith("Z") and "T" in everything[0]["OccurredAtUtc"]

    oldest = everything[-1]
    assert json.loads(oldest["DetailJson"]) == {"mode": "PowerOff"}
    assert oldest["CorrelationId"] == "abc123"

    # A trailing dot is a prefix match; anything else is exact, and '_' is not a wildcard.
    assert {r["Action"] for r in audit_page(conn, Action="vm.")} == {"vm.start", "vm.stop", "vm.update_attributes"}
    assert [r["Action"] for r in audit_page(conn, Action="vm.update_attributes")] == ["vm.update_attributes"]
    assert audit_page(conn, Action="vm.update") == []
    assert audit_page(conn, Action="vm") == []

    # Actor matches the object id exactly or any part of the name.
    assert [r["Action"] for r in audit_page(conn, Actor="oid-bob")] == ["vm.update_attributes"]
    assert [r["Action"] for r in audit_page(conn, Actor="BOB@")] == ["vm.update_attributes"]
    assert len(audit_page(conn, Actor="%")) == 0

    assert [r["Action"] for r in audit_page(conn, Outcome="failure")] == ["vm.stop"]
    assert [r["Action"] for r in audit_page(conn, TargetType="settings")] == ["settings.update"]
    assert {r["TargetId"] for r in audit_page(conn, TargetId="lnx-0")} == {"lnx-01", "lnx-02", "lnx-03"}

    page_two = audit_page(conn, Offset=2, PageSize=2)
    assert len(page_two) == 2 and page_two[0]["TotalCount"] == 5
    assert audit_page(conn, PageSize=5000)[0]["TotalCount"] == 5


def test_audit_date_window_is_inclusive_from_and_exclusive_to(conn):
    write_audit(conn, "vm.start")
    exec_sql(conn, "UPDATE dbo.AuditLog SET OccurredAt='2026-01-10T12:00:00'")
    write_audit(conn, "vm.stop")
    exec_sql(conn, "UPDATE dbo.AuditLog SET OccurredAt='2026-01-11T00:00:00' WHERE Action='vm.stop'")

    assert [r["Action"] for r in audit_page(conn, From="2026-01-10T00:00:00", To="2026-01-11T00:00:00")] == ["vm.start"]
    assert [r["Action"] for r in audit_page(conn, From="2026-01-11T00:00:00")] == ["vm.stop"]


def test_audit_truncates_long_values_and_drops_invalid_detail(conn):
    write_audit(conn, "a" * 100, target_id="t" * 400, actor="n" * 400, detail="{not json")
    row = audit_page(conn)[0]
    assert len(row["Action"]) == 64
    assert len(row["TargetId"]) == 256
    assert len(row["ActorName"]) == 256
    assert row["DetailJson"] is None

    import pymssql
    with pytest.raises(pymssql.Error):
        write_audit(conn, "vm.start", outcome="maybe")
    conn.rollback()


def test_audit_purge_honors_the_retention_floor(conn):
    for days in (10, 40, 400):
        write_audit(conn, f"vm.old{days}")
        exec_sql(conn, "UPDATE dbo.AuditLog SET OccurredAt=DATEADD(DAY, -%d, SYSUTCDATETIME()) WHERE Action=%%s" % days, (f"vm.old{days}",))
    write_audit(conn, "vm.fresh")

    # Anything below 30 days is clamped, so a typo can never empty the table.
    clamped = exec_sql(conn, "EXEC dbo.PurgeAuditLog @RetentionDays=%s", (1,))[0]
    assert clamped["RetentionDays"] == 30
    assert clamped["Deleted"] == 2
    assert clamped["MoreRemaining"] is False
    assert {r["Action"] for r in audit_page(conn)} == {"vm.old10", "vm.fresh"}

    exec_sql(conn, "UPDATE dbo.AuditLog SET OccurredAt=DATEADD(DAY, -500, SYSUTCDATETIME())")
    batched = exec_sql(conn, "EXEC dbo.PurgeAuditLog @RetentionDays=%s, @BatchSize=%s, @MaxBatches=%s", (365, 1, 1))[0]
    assert batched["Deleted"] == 1 and batched["MoreRemaining"] is True


def test_settings_history_lists_each_version_newest_first(conn):
    start = exec_sql(conn, "EXEC dbo.GetLinuxHostSettings")[0]["SettingsVersion"]
    exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @GracePeriodSeconds=%s, @UpdatedBy=%s", (1800, "alice@contoso.com"))
    exec_sql(conn, "EXEC dbo.UpdateLinuxHostSettings @IdleTimeoutSeconds=%s, @UpdatedBy=%s", (3600, "bob@contoso.com"))

    history = exec_sql(conn, "EXEC dbo.GetLinuxHostSettingsHistory @Limit=%s", (3,))
    assert len(history) == 3
    current, previous = history[0], history[1]
    assert current["IsCurrent"] is True and current["ValidToUtc"] is None
    assert current["SettingsVersion"] == start + 2 and current["UpdatedBy"] == "bob@contoso.com"
    assert current["IdleTimeoutSeconds"] == 3600 and previous["IdleTimeoutSeconds"] == 0
    assert previous["IsCurrent"] is False and previous["ValidToUtc"].endswith("Z")
    assert previous["SettingsVersion"] == start + 1 and previous["GracePeriodSeconds"] == 1800
    assert "PreserveSessionsOnDisconnect" in current


# ------------------------------------------------------------------- 2.1 actions and drain


def set_drain(conn, vmid, enabled):
    return exec_sql(conn, "EXEC dbo.SetVmDrain @VMID=%s, @Enabled=%s", (vmid, enabled))[0]


def power(conn, vmid, action, allow_assigned=False):
    return exec_sql(
        conn, "EXEC dbo.BeginVmPowerAction @VMID=%s, @Action=%s, @AllowAssigned=%s", (vmid, action, allow_assigned)
    )[0]


def vm_row(conn, vmid):
    return one(conn, "SELECT * FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))


def flag_draining(conn, vmid):
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1, DrainRequestedDate=GETDATE() WHERE VMID=%s", (vmid,))


def set_rule(conn, **values):
    rule = {"MinVMs": 1, "MaxVMs": 5, "ScaleUpRatio": 70, "ScaleUpIncrement": 1,
            "ScaleDownRatio": 30, "ScaleDownIncrement": 1, "StopMode": "PowerOff"}
    rule.update(values)
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(
        conn,
        "INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement, StopMode) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s)",
        tuple(rule[key] for key in ("MinVMs", "MaxVMs", "ScaleUpRatio", "ScaleUpIncrement", "ScaleDownRatio", "ScaleDownIncrement", "StopMode")),
    )


def test_drain_keeps_the_owner_and_ends_in_maintenance(conn):
    lease = str(uuid.uuid4())
    draining = add_vm(conn, "drain-1", status="CheckedOut", username="alice", avdhost="avd", lease=lease)
    spare = add_vm(conn, "drain-spare")

    result = set_drain(conn, draining, True)
    assert result["Result"] == "Draining" and result["DrainRequested"] is True
    assert result["Username"] == "alice"
    assert vm_row(conn, draining)["DrainRequestedDate"] is not None
    assert set_drain(conn, draining, True)["Result"] == "Unchanged"

    # New users are sent elsewhere, then refused once only the draining host is left...
    assert exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("bob", "avd"))[0]["VMID"] == spare
    refused = exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("carol", "avd"))
    assert refused[0].get("Message") == "No available VM found"
    # ...while the user who holds it can still reconnect to it.
    exec_sql(conn, "EXEC dbo.ReleaseVm @Hostname=%s, @LeaseId=%s, @Username=%s", ("drain-1", lease, "alice"))
    assert exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("alice", "avd2"))[0]["VMID"] == draining

    returned = exec_sql(conn, "EXEC dbo.ReturnVm @VMID=%s", (draining,))[0]
    assert returned["CleanupPending"] is True and returned["VmStatus"] == "Available"
    assert vm_row(conn, draining)["DrainRequested"] is True

    completed = exec_sql(conn, "EXEC dbo.CompleteVmCleanup @VMID=%s, @LeaseId=%s, @Username=%s", (draining, lease, "alice"))[0]
    assert completed["VmStatus"] == "Maintenance" and completed["DrainCompleted"] is True
    row = vm_row(conn, draining)
    assert row["DrainRequested"] is False and row["DrainRequestedDate"] is None and row["CleanupPending"] is False

    back = set_drain(conn, draining, False)
    assert back["Result"] == "ReturnedToService" and back["VmStatus"] == "Available"
    assert set_drain(conn, draining, False)["Result"] == "Unchanged"

    # A cleanup on a host that is not draining is unchanged from Phase 1.
    other_lease = str(uuid.uuid4())
    plain = add_vm(conn, "plain")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupPending=1, CleanupUsername='dave', CleanupLeaseId=%s WHERE VMID=%s", (other_lease, plain))
    plain_done = exec_sql(conn, "EXEC dbo.CompleteVmCleanup @VMID=%s, @LeaseId=%s, @Username=%s", (plain, other_lease, "dave"))[0]
    assert plain_done["VmStatus"] == "Available" and plain_done["DrainCompleted"] is False


def test_drain_on_an_idle_host_is_immediate_and_undrain_restores_it(conn):
    idle = add_vm(conn, "drain-idle")
    drained = set_drain(conn, idle, True)
    assert drained["Result"] == "Drained" and drained["VmStatus"] == "Maintenance" and drained["DrainRequested"] is False
    assert set_drain(conn, idle, True)["Result"] == "Unchanged"

    restored = set_drain(conn, idle, False)
    assert restored["Result"] == "ReturnedToService" and restored["VmStatus"] == "Available"

    pending = add_vm(conn, "drain-pending", cleanup=True, username="old", lease=str(uuid.uuid4()))
    assert set_drain(conn, pending, True)["Result"] == "Draining"

    assert set_drain(conn, 999999, True)["Result"] == "NotFound"


def test_finalize_drains_and_maintenance_clear_the_flag(conn):
    lease = str(uuid.uuid4())
    busy = add_vm(conn, "fin-busy", status="Released", username="u1", avdhost="a", lease=lease)
    set_drain(conn, busy, True)
    idle = add_vm(conn, "fin-idle")
    flag_draining(conn, idle)

    finalized = exec_sql(conn, "EXEC dbo.FinalizeVmDrains")
    assert [r["Hostname"] for r in finalized] == ["fin-idle"]
    assert vm_row(conn, idle)["VmStatus"] == "Maintenance"
    assert vm_row(conn, busy)["DrainRequested"] is True

    # An administrator's repair ends the assignment and claims cleanup; once the host is clean
    # the catch-all completes the drain.
    exec_sql(conn, "EXEC dbo.UpdateVmAttributes @VMID=%s, @VmStatus=%s", (busy, "Available"))
    assert exec_sql(conn, "EXEC dbo.FinalizeVmDrains") == []
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET CleanupPending=0, CleanupUsername=NULL, CleanupLeaseId=NULL WHERE VMID=%s", (busy,))
    assert [r["Hostname"] for r in exec_sql(conn, "EXEC dbo.FinalizeVmDrains")] == ["fin-busy"]

    stuck = add_vm(conn, "fin-stuck")
    flag_draining(conn, stuck)
    updated = exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=%s", (stuck, False))[0]
    assert updated["Result"] == "Updated" and updated["VmStatus"] == "Available"
    assert vm_row(conn, stuck)["DrainRequested"] is False
    assert exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=%s", (stuck, False))[0]["Result"] == "Unchanged"


def test_power_actions_record_state_and_guard_assigned_hosts(conn):
    off = add_vm(conn, "pw-off", power="Off", net="Unreachable")
    started = power(conn, off, "Start")
    assert started["Result"] == "Requested" and started["PreviousPowerState"] == "Off"
    assert started["PreviousNetworkStatus"] == "Unreachable" and started["StopMode"] == "PowerOff"
    row = vm_row(conn, off)
    assert row["PowerState"] == "On" and row["NetworkStatus"] == "Unreachable" and row["PowerStateChangedDate"] is not None

    cold = add_vm(conn, "pw-cold", power="Off", net="Unreachable")
    assert power(conn, cold, "Restart")["Result"] == "InvalidState"
    assert vm_row(conn, cold)["PowerStateChangedDate"] is None

    on = add_vm(conn, "pw-on")
    restarted = power(conn, on, "Restart")
    assert restarted["Result"] == "Requested" and restarted["PreviousNetworkStatus"] == "Reachable"
    assert vm_row(conn, on)["PowerState"] == "On" and vm_row(conn, on)["NetworkStatus"] == "Unreachable"

    stopped = power(conn, on, "Stop")
    assert stopped["Result"] == "Requested" and stopped["EndedAssignment"] is False
    assert vm_row(conn, on)["PowerState"] == "Off"

    lease = str(uuid.uuid4())
    busy = add_vm(conn, "pw-user", status="CheckedOut", username="alice", avdhost="avd", lease=lease)
    for action in ("Stop", "Restart"):
        refused = power(conn, busy, action)
        assert refused["Result"] == "Assigned" and refused["Username"] == "alice"
    assert vm_row(conn, busy)["PowerState"] == "On" and vm_row(conn, busy)["NetworkStatus"] == "Reachable"

    kept = power(conn, busy, "Restart", allow_assigned=True)
    assert kept["Result"] == "Requested" and kept["EndedAssignment"] is False
    assert vm_row(conn, busy)["Username"] == "alice"

    ended = power(conn, busy, "Stop", allow_assigned=True)
    assert ended["Result"] == "Requested" and ended["EndedAssignment"] is True and ended["Username"] == "alice"
    row = vm_row(conn, busy)
    assert row["PowerState"] == "Off" and row["VmStatus"] == "Available"
    assert row["Username"] is None and row["LeaseId"] is None
    assert row["CleanupPending"] is True and row["CleanupUsername"] == "alice"
    assert str(row["CleanupLeaseId"]).lower() == lease

    assert power(conn, on, "Hibernate")["Result"] == "InvalidAction"
    assert power(conn, 999999, "Start")["Result"] == "NotFound"

    exec_sql(conn, "UPDATE dbo.VmScalingRules SET StopMode='Deallocate'")
    assert power(conn, on, "Start")["StopMode"] == "Deallocate"


def revert(conn, begun):
    return exec_sql(
        conn,
        "EXEC dbo.RevertVmPowerAction @VMID=%s, @PreviousPowerState=%s, @PreviousNetworkStatus=%s, "
        "@EndedAssignment=%s, @PreviousVmStatus=%s, @Username=%s, @AvdHost=%s, @LeaseId=%s, @ReleasedDate=%s",
        (begun["VMID"], begun["PreviousPowerState"], begun["PreviousNetworkStatus"], begun["EndedAssignment"],
         begun["PreviousVmStatus"], begun["Username"], begun["AvdHost"], begun["PreviousLeaseId"],
         begun["PreviousReleasedDate"]),
    )[0]


def test_a_refused_stop_gives_the_host_back_to_its_user(conn):
    lease = str(uuid.uuid4())
    busy = add_vm(conn, "rv-user", status="Released", username="alice", avdhost="avd", lease=lease, released_seconds=300)
    before = vm_row(conn, busy)

    begun = power(conn, busy, "Stop", allow_assigned=True)
    assert begun["EndedAssignment"] is True and str(begun["PreviousLeaseId"]).lower() == lease
    assert begun["PreviousVmStatus"] == "Released" and begun["PreviousReleasedDate"] == before["ReleasedDate"]
    assert vm_row(conn, busy)["Username"] is None

    reverted = revert(conn, begun)
    assert reverted["Result"] == "Reverted" and reverted["AssignmentRestored"] is True
    row = vm_row(conn, busy)
    for column in ("PowerState", "NetworkStatus", "VmStatus", "Username", "AvdHost", "LeaseId", "ReleasedDate"):
        assert row[column] == before[column], column
    assert row["CleanupPending"] is False and row["CleanupUsername"] is None and row["CleanupLeaseId"] is None

    # The user reconnects to the host they were on, keeping their lease.
    again = exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("alice", "avd"))[0]
    assert again["VMID"] == busy and str(again["LeaseId"]).lower() == lease


def test_a_refused_stop_leaves_the_assignment_ended_once_the_user_has_moved(conn):
    busy = add_vm(conn, "rv-moved", status="CheckedOut", username="bob", avdhost="avd", lease=str(uuid.uuid4()))
    spare = add_vm(conn, "rv-spare")

    begun = power(conn, busy, "Stop", allow_assigned=True)
    # Bob reconnects before Azure answers, and is given the spare.
    assert exec_sql(conn, "EXEC dbo.CheckoutVm @Username=%s, @AvdHost=%s", ("bob", "avd"))[0]["VMID"] == spare

    reverted = revert(conn, begun)
    assert reverted["Result"] == "Reverted" and reverted["AssignmentRestored"] is False
    row = vm_row(conn, busy)
    assert row["PowerState"] == "On" and row["NetworkStatus"] == "Reachable"
    assert row["Username"] is None and row["CleanupPending"] is True and row["CleanupUsername"] == "bob"
    assert vm_row(conn, spare)["Username"] == "bob"


def test_a_revert_of_an_unassigned_host_restores_only_its_power_state(conn):
    off = add_vm(conn, "rv-off", power="Off", net="Unreachable")
    begun = power(conn, off, "Start")
    assert vm_row(conn, off)["PowerState"] == "On"

    reverted = revert(conn, begun)
    assert reverted == {"Result": "Reverted", "VMID": off, "Hostname": "rv-off", "AssignmentRestored": False}
    row = vm_row(conn, off)
    assert row["PowerState"] == "Off" and row["NetworkStatus"] == "Unreachable" and row["VmStatus"] == "Available"

    assert revert(conn, {**begun, "VMID": 999999})["Result"] == "NotFound"


def test_scaling_leaves_draining_hosts_out_of_capacity(conn):
    set_rule(conn, MinVMs=2, MaxVMs=6)
    for name in ("drn-1", "drn-2"):
        vmid = add_vm(conn, name, status="CheckedOut", username=name.replace("-", ""), avdhost="a", lease=str(uuid.uuid4()), changed_minutes=20)
        flag_draining(conn, vmid)
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    add_vm(conn, "off-2", power="Off", net="Unreachable")
    flag_draining(conn, add_vm(conn, "off-drn", power="Off", net="Unreachable"))

    # Both running hosts are draining, so nothing can take a new user: start two others, but
    # never the draining one.
    started = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert sorted(r["VMName"] for r in started) == ["off-1", "off-2"]
    assert all(r["ActionType"] == "PowerOn" for r in started)
    notes = rows(conn, "SELECT TOP 1 Notes FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")[0]["Notes"]
    assert "draining=3" in notes and "serviceable=0" in notes

    exec_sql(conn, "DELETE FROM dbo.VirtualMachines")
    set_rule(conn, MinVMs=1, MaxVMs=6)
    add_vm(conn, "idle-1", changed_minutes=20)
    add_vm(conn, "idle-2", changed_minutes=20)
    flag_draining(conn, add_vm(conn, "idle-drn", changed_minutes=20))
    stopped = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [r["VMName"] for r in stopped] == ["idle-2"]


def test_vm_readers_report_drain(conn):
    add_vm(conn, "sum-ready")
    draining = add_vm(conn, "sum-drain")
    flag_draining(conn, draining)

    summary = exec_sql(conn, "EXEC dbo.GetVmSummary")[0]
    assert summary["Draining"] == 1 and summary["Ready"] == 1
    listed = {r["Hostname"]: r for r in exec_sql(conn, "EXEC dbo.GetVms")}
    assert listed["sum-drain"]["DrainRequested"] is True and listed["sum-drain"]["DrainRequestedDate"] is not None
    assert listed["sum-ready"]["DrainRequested"] is False
    assert exec_sql(conn, "EXEC dbo.GetVmDetails @VMID=%s", (draining,))[0]["DrainRequested"] is True


# ------------------------------------------------------------------------- 2.2 heartbeat


HEARTBEAT = {
    "agentVersion": "1.0.0",
    "scriptVersions": {"release-session.sh": "1.0.0", "create-user.sh": "1.0.0"},
    "os": {"id": "rhel", "version": "9.4", "name": "Red Hat Enterprise Linux 9.4 (Plow)"},
    "kernel": "5.14.0-427.el9.x86_64",
    "desktop": "gnome",
    "xrdp": {"version": "0.10.1", "active": True},
    "nfs": {"reachable": False, "mounts": 1},
    "loadAverage": 0.57,
    "cpuCount": 4,
    "memoryAvailableMb": 1024,
    "memoryTotalMb": 16000,
    "rootDiskFreePct": 55,
    "uptimeSeconds": 3600,
    "sessions": [{"username": "alice", "state": "active", "sessionStart": 1790000000, "disconnectedSince": None, "idleSeconds": 12}],
}


def heartbeat(conn, hostname, document):
    payload = document if isinstance(document, str) else json.dumps(document)
    return exec_sql(conn, "EXEC dbo.RecordHostHeartbeat @Hostname=%s, @HeartbeatJson=%s", (hostname, payload))[0]


def test_heartbeat_is_stored_for_registered_hosts_only(conn):
    vmid = add_vm(conn, "hb-1")
    settings_version = exec_sql(conn, "EXEC dbo.GetLinuxHostSettings")[0]["SettingsVersion"]

    assert heartbeat(conn, "missing-host", HEARTBEAT)["Result"] == "NotFound"
    assert heartbeat(conn, "hb-1", "not json")["Result"] == "Invalid"

    recorded = heartbeat(conn, "HB-1", dict(HEARTBEAT, settingsVersion=settings_version))
    assert recorded["Result"] == "Recorded" and recorded["Hostname"] == "hb-1"
    assert recorded["ReceivedAtUtc"].endswith("Z")

    stored = one(conn, "SELECT * FROM dbo.HostHeartbeats WHERE Hostname='hb-1'")
    assert stored["AgentVersion"] == "1.0.0" and stored["OsId"] == "rhel" and stored["Desktop"] == "gnome"
    assert stored["XrdpActive"] is True and stored["NfsReachable"] is False and stored["NfsMountCount"] == 1
    assert float(stored["LoadAverage"]) == 0.57 and stored["RootDiskFreePct"] == 55
    assert stored["SessionCount"] == 1 and json.loads(stored["SessionsJson"])[0]["username"] == "alice"
    assert json.loads(stored["ScriptVersionsJson"])["create-user.sh"] == "1.0.0"
    assert vm_row(conn, vmid)["SettingsVersion"] == settings_version

    # The same version again must not write the system-versioned VM row every minute.
    history_before = rows(conn, "SELECT COUNT(*) AS c FROM dbo.VirtualMachinesHistory WHERE VMID=%s", (vmid,))[0]["c"]
    heartbeat(conn, "hb-1", dict(HEARTBEAT, settingsVersion=settings_version))
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VirtualMachinesHistory WHERE VMID=%s", (vmid,))[0]["c"] == history_before
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.HostHeartbeats")[0]["c"] == 1


def test_heartbeat_drops_values_that_are_out_of_range(conn):
    add_vm(conn, "hb-bad")
    document = dict(
        HEARTBEAT,
        rootDiskFreePct=150, loadAverage=-1, cpuCount="many", memoryTotalMb=-5,
        xrdp={"version": "0.9", "active": "maybe"}, sessions="not-a-list", scriptVersions="1.0.0",
    )
    assert heartbeat(conn, "hb-bad", document)["Result"] == "Recorded"
    stored = one(conn, "SELECT * FROM dbo.HostHeartbeats WHERE Hostname='hb-bad'")
    assert stored["RootDiskFreePct"] is None and stored["LoadAverage"] is None and stored["CpuCount"] is None
    assert stored["MemoryTotalMb"] is None and stored["XrdpActive"] is None
    assert stored["SessionsJson"] is None and stored["SessionCount"] is None and stored["ScriptVersionsJson"] is None
    assert stored["XrdpVersion"] == "0.9"


def test_host_health_joins_heartbeats_and_settings(conn):
    add_vm(conn, "health-a")
    add_vm(conn, "health-b", power="Off", net="Unreachable")
    heartbeat(conn, "health-a", HEARTBEAT)

    health = {r["Hostname"]: r for r in exec_sql(conn, "EXEC dbo.GetHostHealth")}
    assert set(health) == {"health-a", "health-b"}
    reporting = health["health-a"]
    assert 0 <= reporting["HeartbeatAgeSeconds"] < 60 and reporting["LastHeartbeatUtc"].endswith("Z")
    assert reporting["AgentVersion"] == "1.0.0" and reporting["CurrentSettingsVersion"] >= 1
    assert reporting["ReconcileIntervalSeconds"] == 60
    silent = health["health-b"]
    assert silent["HeartbeatAgeSeconds"] is None and silent["LastHeartbeatUtc"] is None and silent["AgentVersion"] is None

    exec_sql(conn, "UPDATE dbo.HostHeartbeats SET ReceivedAt=DATEADD(SECOND, -600, SYSUTCDATETIME())")
    aged = exec_sql(conn, "EXEC dbo.GetHostHealth @Hostname=%s", ("health-a",))
    assert len(aged) == 1 and 595 <= aged[0]["HeartbeatAgeSeconds"] <= 660


def test_delete_vm_reports_only_real_deletes_and_drops_the_heartbeat(conn):
    vmid = add_vm(conn, "del-1", status="Maintenance")
    heartbeat(conn, "del-1", HEARTBEAT)

    deleted = exec_sql(conn, "EXEC dbo.DeleteVm @VMID=%s", (vmid,))
    assert deleted == [{"DeletedVMID": vmid, "Hostname": "del-1", "VmStatus": "Maintenance", "Username": None}]
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.HostHeartbeats")[0]["c"] == 0
    assert exec_sql(conn, "EXEC dbo.DeleteVm @VMID=%s", (vmid,)) == []


def test_phase2_procedures_exist(conn):
    expected = {
        "WriteAuditEntry", "GetAuditLogPaged", "PurgeAuditLog", "GetLinuxHostSettingsHistory",
        "SetVmDrain", "FinalizeVmDrains", "BeginVmPowerAction", "RevertVmPowerAction", "RecordHostHeartbeat", "GetHostHealth",
        # 2.3 sessions and users
        "GetSessions", "SearchUsers", "GetUserDetails", "GetUserHostHistory", "GetVmByHostname",
        "RequestProfileReset", "CancelProfileReset", "BeginProfileReset", "CompleteProfileReset",
        # 2.5 scaling policy and schedules
        "GetScalingPolicy", "GetScalingSchedules", "SaveScalingSchedule", "DeleteScalingSchedule",
        "SetScalingPolicyTimeZone", "GetTimeZones",
        # 2.6 trends and unmet demand
        "RecordCheckoutEvent", "GetUtilizationSeries", "GetCheckoutStats", "GetAttentionItems", "PurgeCheckoutEvents",
        # 2.9 rolling maintenance
        "CreateMaintenanceRun", "GetMaintenanceRuns", "GetMaintenanceRun", "GetMaintenanceRunHosts",
        "BeginMaintenanceTick", "EndMaintenanceTick", "ClaimMaintenanceAdmissions", "SetMaintenanceHostState",
        "SetMaintenanceRunStatus", "ReturnMaintenanceHost", "GetMaintenanceAttention",
        # 2.7 host list
        "GetVmsPaged", "GetVmStatusCounts", "ImportLinuxHostVm",
    }
    present = {r["name"] for r in rows(conn, "SELECT name FROM sys.procedures")}
    assert expected <= present
    tables = {r["name"] for r in rows(conn, "SELECT name FROM sys.tables")}
    assert {
        "AuditLog", "HostHeartbeats", "ScalingPolicy", "ScalingSchedules", "CheckoutEvents", "HostStartEvents",
        "MaintenanceRuns", "MaintenanceRunHosts",
    } <= tables
    functions = {r["name"] for r in rows(conn, "SELECT name FROM sys.objects WHERE type IN ('FN', 'IF', 'TF')")}
    assert {"fnScheduleWeekIntervals", "fnActiveScalingPhase", "fnMaintenanceRunSummary"} <= functions
