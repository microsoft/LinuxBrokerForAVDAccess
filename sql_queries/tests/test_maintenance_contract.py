"""Contract tests for 2.9 rolling maintenance (124-140): creating runs, admission under the
scaling lock keeping the minimum ready, the scaling surge, compare-and-set host progress, run
status changes, the advance lease and the return-to-service guard."""

import json
import threading
import time

from conftest import add_vm, exec_sql, one, rows


LEASE = "7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C"


def set_rule(conn, min_vms=2, max_vms=10):
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(conn, "INSERT INTO dbo.VmScalingRules (MinVMs,MaxVMs,ScaleUpRatio,ScaleUpIncrement,ScaleDownRatio,ScaleDownIncrement) "
                   "VALUES (%s, %s, 70, 1, 30, 1)", (min_vms, max_vms))


def create_run(conn, vmids, **options):
    values = {"PatchMode": "Security", "BatchSize": 2, "MinReadyOverride": None, "SignOutDeadlineMinutes": None,
              "WarningMinutes": 15, "IncludePoweredOff": False, "MaxFailures": 1, "CanaryCount": 0}
    values.update(options)
    return exec_sql(
        conn,
        "EXEC dbo.CreateMaintenanceRun @Name=%s, @PatchMode=%s, @BatchSize=%s, @MinReadyOverride=%s, @SignOutDeadlineMinutes=%s, "
        "@WarningMinutes=%s, @IncludePoweredOff=%s, @MaxFailures=%s, @CanaryCount=%s, @HostsJson=%s, @CreatedBy=%s",
        ("Patch night", values["PatchMode"], values["BatchSize"], values["MinReadyOverride"], values["SignOutDeadlineMinutes"],
         values["WarningMinutes"], values["IncludePoweredOff"], values["MaxFailures"], values["CanaryCount"],
         json.dumps(vmids) if not isinstance(vmids, str) else vmids, "admin@contoso.com"),
    )[0]


def admit(conn, run_id):
    return exec_sql(conn, "EXEC dbo.ClaimMaintenanceAdmissions @RunID=%s", (run_id,))


def run_row(conn, run_id=None):
    return one(conn, "EXEC dbo.GetMaintenanceRun @RunID=%s", (run_id,))


def hosts(conn, run_id):
    return rows(conn, "EXEC dbo.GetMaintenanceRunHosts @RunID=%s", (run_id,))


def host(conn, run_id, hostname):
    return next(h for h in hosts(conn, run_id) if h["Hostname"] == hostname)


def set_state(conn, run_host_id, version, **flags):
    names = ", ".join(f"@{name}=%s" for name in flags)
    return exec_sql(conn, f"EXEC dbo.SetMaintenanceHostState @RunHostID=%s, @ExpectedVersion=%s{', ' + names if names else ''}",
                    (run_host_id, version, *flags.values()))[0]


def run_status(conn, run_id, action, reason=None):
    return exec_sql(conn, "EXEC dbo.SetMaintenanceRunStatus @RunID=%s, @Action=%s, @Reason=%s, @UpdatedBy=%s",
                    (run_id, action, reason, "admin@contoso.com"))[0]


def vm(conn, vmid):
    return one(conn, "SELECT * FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))


def ready_pool(conn, count, prefix="lnx"):
    return [add_vm(conn, f"{prefix}-{index:02}") for index in range(1, count + 1)]


# ----------------------------------------------------------------------- creating runs


def test_a_run_keeps_the_given_order_once_per_host(conn):
    a, b, c = ready_pool(conn, 3)
    created = create_run(conn, [c, a, c, b])
    assert created["Result"] == "Created" and created["HostCount"] == 3
    assert [(h["Hostname"], h["Position"], h["State"]) for h in hosts(conn, created["RunID"])] == [
        ("lnx-03", 1, "Pending"), ("lnx-01", 2, "Pending"), ("lnx-02", 3, "Pending"),
    ]
    summary = run_row(conn)
    assert (summary["RunID"], summary["Status"], summary["Total"], summary["Pending"]) == (created["RunID"], "Active", 3, 3)


def test_unknown_or_missing_hosts_are_refused(conn):
    a = add_vm(conn, "lnx-01")
    unknown = create_run(conn, [a, 999999, "abc"])
    assert unknown["Result"] == "UnknownHosts"
    assert [item["VMID"] for item in json.loads(unknown["UnknownJson"])] == ["999999", "abc"]
    assert create_run(conn, [])["Result"] == "NoHosts"
    assert create_run(conn, '{"not": "a list"}')["Result"] == "NoHosts"
    assert one(conn, "SELECT COUNT(*) AS N FROM dbo.MaintenanceRuns")["N"] == 0


def test_only_one_run_is_active_at_a_time(conn):
    a, b = ready_pool(conn, 2)
    first = create_run(conn, [a])
    assert create_run(conn, [b]) == {"Result": "RunActive", "RunID": first["RunID"], "HostCount": 0, "UnknownJson": None}

    run_status(conn, first["RunID"], "pause")
    assert create_run(conn, [b])["Result"] == "RunActive"
    run_status(conn, first["RunID"], "cancel")
    assert create_run(conn, [b])["Result"] == "RunActive"
    assert run_status(conn, first["RunID"], "finish")["Status"] == "Cancelled"
    assert create_run(conn, [b])["Result"] == "Created"


# ----------------------------------------------------------------------- admission


def test_admission_keeps_the_minimum_ready_and_asks_scaling_for_a_spare(conn):
    set_rule(conn, min_vms=2)
    ids = ready_pool(conn, 4)
    run_id = create_run(conn, ids, BatchSize=3)["RunID"]

    admitted = admit(conn, run_id)

    assert [(r["Hostname"], r["Action"]) for r in admitted] == [("lnx-01", "Admitted"), ("lnx-02", "Admitted")]
    assert [vm(conn, i)["VmStatus"] for i in ids] == ["Maintenance", "Maintenance", "Available", "Available"]
    summary = run_row(conn, run_id)
    assert summary["SurgeRequested"] is True and "lnx-03" in summary["WaitReason"]
    assert (summary["InProgress"], summary["ReadyNow"], summary["MinReadyInForce"]) == (2, 2, 2)
    first = host(conn, run_id, "lnx-01")
    assert first["State"] == "Draining" and first["WasMaintenance"] is False and first["AdmittedAgeSeconds"] is not None


def test_hosts_in_use_are_drained_without_taking_ready_capacity(conn):
    set_rule(conn, min_vms=2)
    ready = ready_pool(conn, 2)
    busy = add_vm(conn, "lnx-busy", status="CheckedOut", username="alice", avdhost="avd", lease=LEASE)
    off = add_vm(conn, "lnx-off", power="Off", net="Unreachable")
    run_id = create_run(conn, [*ready, busy, off], BatchSize=4, IncludePoweredOff=True)["RunID"]

    admitted = admit(conn, run_id)

    assert sorted(r["Hostname"] for r in admitted) == ["lnx-busy", "lnx-off"]
    busy_vm = vm(conn, busy)
    assert (busy_vm["VmStatus"], busy_vm["DrainRequested"], busy_vm["Username"]) == ("CheckedOut", True, "alice")
    assert vm(conn, off)["VmStatus"] == "Maintenance"
    assert host(conn, run_id, "lnx-off")["WasPoweredOff"] is True
    assert run_row(conn, run_id)["SurgeRequested"] is True


def test_the_minimum_can_be_overridden_and_powered_off_hosts_skipped(conn):
    set_rule(conn, min_vms=2)
    ready = ready_pool(conn, 2)
    off = add_vm(conn, "lnx-off", power="Off", net="Unreachable")
    run_id = create_run(conn, [*ready, off], BatchSize=5, MinReadyOverride=0)["RunID"]

    changes = admit(conn, run_id)

    assert sorted((r["Hostname"], r["Action"]) for r in changes) == [
        ("lnx-01", "Admitted"), ("lnx-02", "Admitted"), ("lnx-off", "Skipped"),
    ]
    assert "does not include powered-off hosts" in host(conn, run_id, "lnx-off")["Detail"]
    summary = run_row(conn, run_id)
    assert summary["SurgeRequested"] is False and summary["WaitReason"] is None and summary["Skipped"] == 1


def test_a_host_that_was_already_out_of_rotation_is_recorded_as_such(conn):
    drained = add_vm(conn, "lnx-drained", status="CheckedOut", username="bob", avdhost="avd", lease=LEASE)
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE VMID=%s", (drained,))
    maint = add_vm(conn, "lnx-maint", status="Maintenance")
    run_id = create_run(conn, [drained, maint], BatchSize=2)["RunID"]

    admit(conn, run_id)

    assert host(conn, run_id, "lnx-drained")["WasDrained"] is True
    assert host(conn, run_id, "lnx-maint")["WasMaintenance"] is True


def test_unregistered_hosts_are_skipped(conn):
    a, b = ready_pool(conn, 2)
    run_id = create_run(conn, [a, b], MinReadyOverride=0)["RunID"]
    exec_sql(conn, "DELETE FROM dbo.VirtualMachines WHERE VMID=%s", (b,))

    changes = admit(conn, run_id)

    assert ("lnx-02", "Skipped") in [(r["Hostname"], r["Action"]) for r in changes]
    assert host(conn, run_id, "lnx-02")["Registered"] is False


def test_a_paused_run_admits_nothing(conn):
    ids = ready_pool(conn, 3)
    run_id = create_run(conn, ids, MinReadyOverride=0)["RunID"]
    run_status(conn, run_id, "pause")
    assert admit(conn, run_id) == []
    assert all(h["State"] == "Pending" for h in hosts(conn, run_id))


def test_canary_hosts_run_alone_and_the_run_pauses_after_them(conn):
    ids = ready_pool(conn, 4)
    run_id = create_run(conn, ids, BatchSize=3, MinReadyOverride=0, CanaryCount=1)["RunID"]

    assert [r["Hostname"] for r in admit(conn, run_id)] == ["lnx-01"]
    assert admit(conn, run_id) == []

    canary = host(conn, run_id, "lnx-01")
    assert set_state(conn, canary["RunHostID"], canary["Version"], State="Succeeded")["Result"] == "Updated"
    assert admit(conn, run_id) == []
    summary = run_row(conn, run_id)
    assert summary["Status"] == "Paused" and summary["CanaryReached"] is True
    assert "first 1 host" in summary["StatusReason"]

    run_status(conn, run_id, "resume")
    assert [r["Hostname"] for r in admit(conn, run_id)] == ["lnx-02", "lnx-03", "lnx-04"]


def test_admission_waits_for_the_scaling_lock(conn, second_conn):
    ids = ready_pool(conn, 2)
    run_id = create_run(conn, ids, MinReadyOverride=0)["RunID"]
    holder = second_conn()
    cur = holder.cursor()
    cur.execute("BEGIN TRANSACTION; DECLARE @r INT; EXEC @r = sp_getapplock @Resource='LinuxBroker.Scaling', @LockMode='Exclusive', @LockOwner='Transaction'; SELECT @r")
    cur.fetchall()
    try:
        started = time.monotonic()
        assert admit(conn, run_id) == []
        assert time.monotonic() - started >= 4
        assert all(h["State"] == "Pending" for h in hosts(conn, run_id))
    finally:
        holder.rollback()
    assert len(admit(conn, run_id)) == 2


# ----------------------------------------------------------------------- the scaling surge


def test_scaling_keeps_one_more_host_while_a_run_waits_for_a_spare(conn):
    set_rule(conn, min_vms=2, max_vms=5)
    ids = ready_pool(conn, 2)
    spare = add_vm(conn, "lnx-spare", power="Off", net="Unreachable")
    run_id = create_run(conn, ids)["RunID"]
    admit(conn, run_id)

    preview = exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1")[0]
    assert (preview["MinVMs"], preview["MaintenanceSurge"], preview["Action"]) == (3, True, "PowerOn")

    actions = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [(a["ActionType"], a["VMID"]) for a in actions] == [("PowerOn", spare)]
    notes = one(conn, "SELECT TOP 1 Notes, MinVMs FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert notes["MinVMs"] == 3 and "maintenance run asked for one more ready host" in notes["Notes"]

    # A paused run no longer asks.
    run_status(conn, run_id, "pause")
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1")[0]["MaintenanceSurge"] is False


def test_the_surge_never_goes_past_the_maximum(conn):
    set_rule(conn, min_vms=2, max_vms=3)
    ids = ready_pool(conn, 2)
    run_id = create_run(conn, ids)["RunID"]
    admit(conn, run_id)
    assert run_row(conn, run_id)["SurgeRequested"] is True
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1")[0]["MinVMs"] == 3
    # Rules always allow one more than their minimum; a proposed phase might not.
    preview = exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1, @OverrideJson=%s", (json.dumps({"MinVMs": 3, "MaxVMs": 3}),))[0]
    assert (preview["MinVMs"], preview["MaintenanceSurge"]) == (3, False)


# ----------------------------------------------------------------------- host progress


def test_host_progress_is_a_compare_and_set(conn):
    a = add_vm(conn, "lnx-01")
    run_id = create_run(conn, [a], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    current = host(conn, run_id, "lnx-01")

    patching = set_state(conn, current["RunHostID"], current["Version"], State="Patching", MarkAction=True, PatchToken="lb1-1-1")
    assert (patching["Result"], patching["State"], patching["Attempts"], patching["Version"]) == ("Updated", "Patching", 1, current["Version"] + 1)
    assert set_state(conn, current["RunHostID"], current["Version"], State="Failed")["Result"] == "Conflict"

    again = set_state(conn, current["RunHostID"], patching["Version"], MarkAction=True, PatchToken="lb1-1-2")
    assert again["Attempts"] == 2
    detail = host(conn, run_id, "lnx-01")
    assert detail["PatchToken"] == "lb1-1-2" and detail["ActionAgeSeconds"] is not None and detail["StepAgeSeconds"] is not None

    started = set_state(conn, current["RunHostID"], again["Version"], MarkPatchStarted=True)
    finished = set_state(conn, current["RunHostID"], started["Version"], State="Restarting", MarkPatchFinished=True,
                         RebootRequired="yes")
    assert (finished["State"], finished["Attempts"]) == ("Restarting", 0)
    detail = host(conn, run_id, "lnx-01")
    assert detail["PatchStartedAtUtc"].endswith("Z") and detail["RebootRequired"] == "yes" and detail["ActionAgeSeconds"] is None

    done = set_state(conn, current["RunHostID"], finished["Version"], State="Succeeded", Detail="Patched.", SetDetail=True)
    assert done["Result"] == "Updated" and host(conn, run_id, "lnx-01")["CompletedAtUtc"].endswith("Z")
    assert set_state(conn, current["RunHostID"], done["Version"], State="Failed")["Result"] == "Final"
    assert set_state(conn, 999999, 0, State="Failed")["Result"] == "NotFound"


def test_a_start_can_count_as_the_restart(conn):
    off = add_vm(conn, "lnx-off", power="Off", net="Unreachable")
    run_id = create_run(conn, [off], PatchMode="RebootOnly", IncludePoweredOff=True)["RunID"]
    admit(conn, run_id)
    current = host(conn, run_id, "lnx-off")
    starting = set_state(conn, current["RunHostID"], current["Version"], State="Starting", MarkAction=True)
    exec_sql(conn, "UPDATE dbo.MaintenanceRunHosts SET ActionRequestedAt=DATEADD(MINUTE, -3, ActionRequestedAt) WHERE RunHostID=%s",
             (current["RunHostID"],))
    set_state(conn, current["RunHostID"], starting["Version"], State="Verifying", RestartFromAction=True)
    assert 170 <= host(conn, run_id, "lnx-off")["RestartAgeSeconds"] <= 200


def test_a_heartbeat_proves_the_restart_only_when_its_boot_came_after(conn):
    a = add_vm(conn, "lnx-01")
    run_id = create_run(conn, [a], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    current = host(conn, run_id, "lnx-01")
    set_state(conn, current["RunHostID"], current["Version"], State="Verifying", MarkRestart=True)
    exec_sql(conn, "UPDATE dbo.MaintenanceRunHosts SET RestartRequestedAt=DATEADD(MINUTE, -5, RestartRequestedAt) WHERE RunHostID=%s",
             (current["RunHostID"],))

    exec_sql(conn, "INSERT INTO dbo.HostHeartbeats (Hostname, ReceivedAt, UptimeSeconds, XrdpActive) VALUES ('lnx-01', SYSUTCDATETIME(), 864000, 1)")
    stale = host(conn, run_id, "lnx-01")
    assert (stale["HeartbeatAfterRestart"], stale["BootedAfterRestart"]) == (True, False)

    exec_sql(conn, "UPDATE dbo.HostHeartbeats SET UptimeSeconds=120 WHERE Hostname='lnx-01'")
    fresh = host(conn, run_id, "lnx-01")
    assert (fresh["HeartbeatAfterRestart"], fresh["BootedAfterRestart"], fresh["XrdpActive"]) == (True, True, True)

    exec_sql(conn, "UPDATE dbo.HostHeartbeats SET ReceivedAt=DATEADD(MINUTE, -10, SYSUTCDATETIME()), UptimeSeconds=60 WHERE Hostname='lnx-01'")
    old = host(conn, run_id, "lnx-01")
    assert (old["HeartbeatAfterRestart"], old["BootedAfterRestart"]) == (False, False)


# ----------------------------------------------------------------------- run status


def test_run_status_changes(conn):
    ids = ready_pool(conn, 3)
    run_id = create_run(conn, ids, BatchSize=1, MinReadyOverride=0)["RunID"]
    admit(conn, run_id)

    assert run_status(conn, run_id, "resume")["Result"] == "Unchanged"
    assert run_status(conn, run_id, "complete")["Result"] == "InvalidState"
    paused = run_status(conn, run_id, "pause", "Checking the first host.")
    assert (paused["Result"], paused["Status"], paused["StatusReason"]) == ("Updated", "Paused", "Checking the first host.")
    assert run_status(conn, run_id, "resume")["Status"] == "Active"

    stopping = run_status(conn, run_id, "cancel")
    assert (stopping["Status"], stopping["EndStatus"], stopping["Cancelled"], stopping["InProgress"]) == ("Stopping", "Cancelled", 2, 1)
    assert run_status(conn, run_id, "cancel")["Result"] == "Unchanged"
    assert run_status(conn, run_id, "finish")["Result"] == "InvalidState"

    draining = host(conn, run_id, "lnx-01")
    set_state(conn, draining["RunHostID"], draining["Version"], State="Cancelled")
    finished = run_status(conn, run_id, "finish")
    assert (finished["Status"], finished["EndedAtUtc"] is not None) == ("Cancelled", True)
    assert run_status(conn, run_id, "pause")["Result"] == "InvalidState"
    assert run_status(conn, 999999, "pause")["Result"] == "NotFound"


def test_a_run_completes_only_when_every_host_is_done(conn):
    a = add_vm(conn, "lnx-01")
    run_id = create_run(conn, [a], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    current = host(conn, run_id, "lnx-01")
    set_state(conn, current["RunHostID"], current["Version"], State="Succeeded")
    completed = run_status(conn, run_id, "complete")
    assert (completed["Result"], completed["Status"], completed["EndStatus"]) == ("Updated", "Completed", "Completed")


def test_too_many_failures_stop_the_run(conn):
    ids = ready_pool(conn, 2)
    run_id = create_run(conn, ids, BatchSize=1, MinReadyOverride=0)["RunID"]
    stopping = run_status(conn, run_id, "fail", "2 hosts failed.")
    assert (stopping["Status"], stopping["EndStatus"], stopping["StatusReason"]) == ("Stopping", "Failed", "2 hosts failed.")
    assert "too many hosts failed" in host(conn, run_id, "lnx-01")["Detail"]
    assert run_status(conn, run_id, "finish")["Status"] == "Failed"


# ----------------------------------------------------------------------- the advance lease


def test_one_advance_at_a_time(conn):
    assert one(conn, "EXEC dbo.BeginMaintenanceTick")["Result"] == "NoRun"
    a = add_vm(conn, "lnx-01")
    run_id = create_run(conn, [a])["RunID"]
    # Before its first advance a run has no tick age, but its age since creation is known.
    fresh = run_row(conn, run_id)
    assert fresh["LastTickAgeSeconds"] is None and 0 <= fresh["CreatedAgeSeconds"] < 60
    exec_sql(conn, "UPDATE dbo.MaintenanceRuns SET CreatedAt=DATEADD(MINUTE, -10, CreatedAt) WHERE RunID=%s", (run_id,))
    assert 599 <= run_row(conn, run_id)["CreatedAgeSeconds"] <= 660

    claimed = one(conn, "EXEC dbo.BeginMaintenanceTick @LeaseSeconds=60")
    assert (claimed["Result"], claimed["RunID"], claimed["Status"]) == ("Claimed", run_id, "Active") and claimed["TickToken"]
    busy = one(conn, "EXEC dbo.BeginMaintenanceTick")
    assert (busy["Result"], busy["RunID"], busy["TickToken"]) == ("Busy", run_id, None)

    assert one(conn, "EXEC dbo.EndMaintenanceTick @RunID=%s, @TickToken=%s", (run_id, "00000000-0000-0000-0000-000000000000"))["Result"] == "NotHeld"
    assert one(conn, "EXEC dbo.EndMaintenanceTick @RunID=%s, @TickToken=%s", (run_id, claimed["TickToken"]))["Result"] == "Released"
    again = one(conn, "EXEC dbo.BeginMaintenanceTick")
    assert again["Result"] == "Claimed"

    # An advance that died lets its claim lapse.
    exec_sql(conn, "UPDATE dbo.MaintenanceRuns SET TickLeaseUntil=DATEADD(SECOND, -1, SYSUTCDATETIME()) WHERE RunID=%s", (run_id,))
    assert one(conn, "EXEC dbo.BeginMaintenanceTick")["Result"] == "Claimed"
    assert run_row(conn, run_id)["LastTickAgeSeconds"] is not None


# ----------------------------------------------------------------------- returning hosts


def test_returning_to_service_is_refused_while_a_run_patches_the_host(conn):
    a, b = ready_pool(conn, 2)
    run_id = create_run(conn, [a, b], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    patching = host(conn, run_id, "lnx-01")
    set_state(conn, patching["RunHostID"], patching["Version"], State="Patching")

    for proc in ("SetVmDrain", "SetVmMaintenance"):
        refused = exec_sql(conn, f"EXEC dbo.{proc} @VMID=%s, @Enabled=0", (a,))[0]
        assert (refused["Result"], refused["Reason"], refused["MaintenanceRunID"]) == ("InvalidState", "InMaintenanceRun", run_id), proc
    assert vm(conn, a)["VmStatus"] == "Maintenance"

    # Before patching starts, a manual return takes the host out of the run.
    returned = exec_sql(conn, "EXEC dbo.SetVmDrain @VMID=%s, @Enabled=0", (b,))[0]
    assert (returned["Result"], returned["VmStatus"], returned["Reason"]) == ("ReturnedToService", "Available", None)
    skipped = host(conn, run_id, "lnx-02")
    assert skipped["State"] == "Skipped" and "Returned to service by an operator" in skipped["Detail"]

    # Draining is never refused.
    assert exec_sql(conn, "EXEC dbo.SetVmDrain @VMID=%s, @Enabled=1", (a,))[0]["Result"] == "Unchanged"


def test_maintenance_off_before_patching_also_skips_the_host(conn):
    a = add_vm(conn, "lnx-01")
    run_id = create_run(conn, [a], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    result = exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=0", (a,))[0]
    assert (result["Result"], result["VmStatus"]) == ("Updated", "Available")
    assert host(conn, run_id, "lnx-01")["State"] == "Skipped"


def test_a_patched_host_goes_back_the_way_it_was_found(conn):
    fresh = add_vm(conn, "lnx-fresh")
    maint = add_vm(conn, "lnx-maint", status="Maintenance")
    run_id = create_run(conn, [fresh, maint], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)

    back = one(conn, "EXEC dbo.ReturnMaintenanceHost @RunHostID=%s", (host(conn, run_id, "lnx-fresh")["RunHostID"],))
    assert (back["Result"], back["VmStatus"], back["DrainRequested"]) == ("ReturnedToService", "Available", False)
    assert one(conn, "EXEC dbo.ReturnMaintenanceHost @RunHostID=%s", (host(conn, run_id, "lnx-fresh")["RunHostID"],))["Result"] == "Unchanged"
    left = one(conn, "EXEC dbo.ReturnMaintenanceHost @RunHostID=%s", (host(conn, run_id, "lnx-maint")["RunHostID"],))
    assert (left["Result"], left["VmStatus"]) == ("LeftOutOfService", "Maintenance")


def test_a_cancelled_run_gives_a_waiting_host_back_to_its_user(conn):
    busy = add_vm(conn, "lnx-busy", status="CheckedOut", username="carol", avdhost="avd", lease=LEASE)
    run_id = create_run(conn, [busy])["RunID"]
    admit(conn, run_id)
    assert vm(conn, busy)["DrainRequested"] is True
    back = one(conn, "EXEC dbo.ReturnMaintenanceHost @RunHostID=%s", (host(conn, run_id, "lnx-busy")["RunHostID"],))
    assert (back["Result"], back["VmStatus"], back["DrainRequested"]) == ("ReturnedToService", "CheckedOut", False)


def test_failed_hosts_still_out_of_rotation_need_attention(conn):
    a, b = ready_pool(conn, 2)
    run_id = create_run(conn, [a, b], MinReadyOverride=0)["RunID"]
    admit(conn, run_id)
    for name in ("lnx-01", "lnx-02"):
        current = host(conn, run_id, name)
        set_state(conn, current["RunHostID"], current["Version"], State="Failed", Detail="Patching failed (exit 1).", SetDetail=True)
    exec_sql(conn, "EXEC dbo.SetVmMaintenance @VMID=%s, @Enabled=0", (b,))

    items = rows(conn, "EXEC dbo.GetMaintenanceAttention")
    assert [(i["Hostname"], i["RunID"], i["Detail"]) for i in items] == [("lnx-01", run_id, "Patching failed (exit 1).")]


def test_the_run_list_is_newest_first(conn):
    a = add_vm(conn, "lnx-01")
    first = create_run(conn, [a])["RunID"]
    run_status(conn, first, "cancel")
    run_status(conn, first, "finish")
    second = create_run(conn, [a])["RunID"]
    listed = rows(conn, "EXEC dbo.GetMaintenanceRuns @Limit=5")
    assert [r["RunID"] for r in listed] == [second, first]
    assert listed[1]["Status"] == "Cancelled" and listed[0]["CreatedBy"] == "admin@contoso.com"
