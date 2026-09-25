"""Contract tests for 2.6 trends and unmet demand (115-123): checkout and host-start events,
the utilization series, checkout statistics, attention items, the purge and the summary's
scaler counts."""

import json
from datetime import datetime, timedelta, timezone

from conftest import add_vm, exec_sql, one, rows


def utc_floor(minutes=60):
    now = datetime.now(timezone.utc).replace(tzinfo=None, second=0, microsecond=0)
    return now - timedelta(minutes=now.minute % minutes)


def record(conn, outcome, username="alice", duration=None, hostname=None, minutes_ago=None):
    event_id = exec_sql(conn, "EXEC dbo.RecordCheckoutEvent @Username=%s, @AvdHost=%s, @Outcome=%s, @DurationMs=%s, @Hostname=%s",
                        (username, "avd-01", outcome, duration, hostname))[0]["EventID"]
    if minutes_ago is not None:
        exec_sql(conn, "UPDATE dbo.CheckoutEvents SET OccurredAt=DATEADD(MINUTE, -%s, SYSUTCDATETIME()) WHERE EventID=%s",
                 (minutes_ago, event_id))
    return event_id


def event_at(conn, outcome, at_utc, duration=None):
    exec_sql(conn, "INSERT INTO dbo.CheckoutEvents (OccurredAt, Username, Outcome, DurationMs) VALUES (%s, 'u', %s, %s)",
             (at_utc, outcome, duration))


def run_at(conn, at_utc, running, in_use, serviceable, min_vms=1, max_vms=5):
    # CheckTimestamp is database-local, like every scaling run writes it.
    exec_sql(conn, "INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, NewTotalVMs, "
                   "ServiceableVMs, MinVMs, MaxVMs) "
                   "VALUES (DATEADD(MINUTE, DATEDIFF(MINUTE, GETUTCDATE(), GETDATE()), CAST(%s AS DATETIME2(0))), %s, %s, N'No Action', %s, %s, %s, %s)",
             (at_utc, running, in_use, running, serviceable, min_vms, max_vms))


def set_status(conn, vmid, status):
    return exec_sql(conn, "EXEC dbo.SetVmNetworkStatus @VMID=%s, @NetworkStatus=%s", (vmid, status))[0]


def power(conn, vmid, action):
    return exec_sql(conn, "EXEC dbo.BeginVmPowerAction @VMID=%s, @Action=%s", (vmid, action))[0]


def stamp(conn, vmid):
    return one(conn, "SELECT StartRequestedAt FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["StartRequestedAt"]


def start_events(conn):
    return rows(conn, "SELECT VMID, Hostname, Seconds FROM dbo.HostStartEvents ORDER BY EventID")


def backdate_history(conn, vmid, minutes):
    """Moves a host's temporal history back in time, which system versioning never allows."""
    exec_sql(conn, "ALTER TABLE dbo.VirtualMachines SET (SYSTEM_VERSIONING = OFF)")
    try:
        exec_sql(conn, "UPDATE dbo.VirtualMachinesHistory SET SysStartTime=DATEADD(MINUTE, -%s, SysStartTime), "
                       "SysEndTime=DATEADD(MINUTE, -%s, SysEndTime) WHERE VMID=%s", (minutes, minutes, vmid))
    finally:
        exec_sql(conn, "ALTER TABLE dbo.VirtualMachines SET (SYSTEM_VERSIONING = ON "
                       "(HISTORY_TABLE = dbo.VirtualMachinesHistory, DATA_CONSISTENCY_CHECK = OFF))")


def attention(conn, **arguments):
    sql = "EXEC dbo.GetAttentionItems " + ", ".join(f"@{name}=%s" for name in arguments)
    return rows(conn, sql, tuple(arguments.values()))


def kinds(items):
    return [item["Kind"] for item in items]


# ----------------------------------------------------------------------- checkout events


def test_record_checkout_event_stores_the_outcome_and_turns_unknown_ones_into_errors(conn):
    record(conn, "Assigned", duration=1200, hostname="lnx-01")
    record(conn, "Bogus", duration=-5)
    stored = rows(conn, "SELECT Username, AvdHost, Outcome, DurationMs, Hostname, "
                        "DATEDIFF(SECOND, OccurredAt, SYSUTCDATETIME()) AS AgeSeconds FROM dbo.CheckoutEvents ORDER BY EventID")
    assert [(r["Outcome"], r["DurationMs"], r["Hostname"]) for r in stored] == [("Assigned", 1200, "lnx-01"), ("Error", 0, None)]
    assert all(r["AvdHost"] == "avd-01" and 0 <= r["AgeSeconds"] < 60 for r in stored)


# ----------------------------------------------------------------------- host starts


def test_a_start_is_measured_when_the_host_first_becomes_reachable(conn):
    vmid = add_vm(conn, "lnx-start", power="Off", net="Unreachable")
    assert power(conn, vmid, "Start")["Result"] == "Requested"
    assert stamp(conn, vmid) is not None

    exec_sql(conn, "UPDATE dbo.VirtualMachines SET StartRequestedAt=DATEADD(SECOND, -95, SYSUTCDATETIME()) WHERE VMID=%s", (vmid,))
    result = set_status(conn, vmid, "Reachable")
    assert result["Changed"] and result["NetworkStatus"] == "Reachable"
    events = start_events(conn)
    assert len(events) == 1 and events[0]["Hostname"] == "lnx-start" and 94 <= events[0]["Seconds"] <= 100
    assert stamp(conn, vmid) is None

    # Later reachability changes do not measure again.
    set_status(conn, vmid, "Unreachable")
    set_status(conn, vmid, "Reachable")
    assert len(start_events(conn)) == 1


def test_a_restart_reported_reachable_before_the_host_went_down_waits_for_it_to_come_back(conn):
    vmid = add_vm(conn, "lnx-restart")
    assert power(conn, vmid, "Restart")["Result"] == "Requested"

    set_status(conn, vmid, "Reachable")
    assert start_events(conn) == [] and stamp(conn, vmid) is not None

    exec_sql(conn, "UPDATE dbo.VirtualMachines SET StartRequestedAt=DATEADD(SECOND, -70, StartRequestedAt) WHERE VMID=%s", (vmid,))
    set_status(conn, vmid, "Unreachable")
    set_status(conn, vmid, "Reachable")
    events = start_events(conn)
    assert len(events) == 1 and 69 <= events[0]["Seconds"] <= 75


def test_scaling_starts_are_measured_and_stops_are_not(conn):
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(conn, "INSERT INTO dbo.VmScalingRules (MinVMs,MaxVMs,ScaleUpRatio,ScaleUpIncrement,ScaleDownRatio,ScaleDownIncrement) "
                   "VALUES (1, 3, 70, 1, 30, 1)")
    vmid = add_vm(conn, "lnx-scale", power="Off", net="Unreachable")
    actions = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [a["VMID"] for a in actions if a["ActionType"] == "PowerOn"] == [vmid]
    assert stamp(conn, vmid) is not None

    power(conn, vmid, "Stop")
    assert stamp(conn, vmid) is None
    set_status(conn, vmid, "Reachable")
    assert start_events(conn) == []


def test_a_stamp_older_than_two_hours_is_cleared_without_measuring(conn):
    vmid = add_vm(conn, "lnx-stale", net="Unreachable")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET StartRequestedAt=DATEADD(MINUTE, -150, SYSUTCDATETIME()) WHERE VMID=%s", (vmid,))
    set_status(conn, vmid, "Reachable")
    assert start_events(conn) == [] and stamp(conn, vmid) is None


def test_set_vm_network_status_keeps_its_result_for_an_unchanged_host(conn):
    vmid = add_vm(conn, "lnx-same")
    result = set_status(conn, vmid, "Reachable")
    assert result == {"VMID": vmid, "Hostname": "lnx-same", "PowerState": "On", "NetworkStatus": "Reachable", "Changed": False}


# ----------------------------------------------------------------------- utilization series


def test_utilization_series_buckets_runs_and_checkouts_including_empty_buckets(conn):
    start = utc_floor(60) - timedelta(hours=3)
    run_at(conn, start + timedelta(minutes=5), running=4, in_use=1, serviceable=4, min_vms=2, max_vms=6)
    run_at(conn, start + timedelta(minutes=35), running=4, in_use=3, serviceable=3, min_vms=2, max_vms=6)
    run_at(conn, start + timedelta(hours=2, minutes=10), running=2, in_use=0, serviceable=2, min_vms=1, max_vms=6)
    run_at(conn, start - timedelta(minutes=1), running=9, in_use=9, serviceable=9)
    event_at(conn, "Assigned", start + timedelta(minutes=10), 800)
    event_at(conn, "NoneAvailable", start + timedelta(minutes=50))
    event_at(conn, "Error", start + timedelta(hours=1, minutes=1))
    event_at(conn, "NoneAvailable", start + timedelta(hours=3))

    series = rows(conn, "EXEC dbo.GetUtilizationSeries @FromUtc=%s, @ToUtc=%s, @BucketMinutes=60",
                  (start, start + timedelta(hours=3)))

    assert [b["BucketStartUtc"] for b in series] == [(start + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ") for h in range(3)]
    first, second, third = series
    assert first["Runs"] == 2 and float(first["PoweredOn"]) == 4.0 and float(first["InUse"]) == 2.0
    assert float(first["Serviceable"]) == 3.5 and first["PeakInUse"] == 3 and (first["MinVMs"], first["MaxVMs"]) == (2, 6)
    assert (first["Checkouts"], first["Denied"], first["Failed"]) == (2, 1, 0)
    assert second["Runs"] == 0 and second["PoweredOn"] is None and second["MaxVMs"] is None
    assert (second["Checkouts"], second["Denied"], second["Failed"]) == (1, 0, 1)
    assert third["Runs"] == 1 and third["MinVMs"] == 1 and third["Checkouts"] == 0


def test_utilization_series_rounds_the_start_down_and_bounds_the_bucket_count(conn):
    start = utc_floor(60) - timedelta(hours=2)
    series = rows(conn, "EXEC dbo.GetUtilizationSeries @FromUtc=%s, @ToUtc=%s, @BucketMinutes=1",
                  (start + timedelta(seconds=30), start + timedelta(minutes=12)))
    # Buckets below five minutes are widened to five; the partial last bucket is included.
    assert [b["BucketStartUtc"][11:16] for b in series] == [(start + timedelta(minutes=m)).strftime("%H:%M") for m in (0, 5, 10)]

    assert rows(conn, "EXEC dbo.GetUtilizationSeries @FromUtc=%s, @ToUtc=%s, @BucketMinutes=5",
                (start, start - timedelta(minutes=5))) == []
    assert rows(conn, "EXEC dbo.GetUtilizationSeries @FromUtc=%s, @ToUtc=%s, @BucketMinutes=5",
                (start - timedelta(days=30), start)) == []


# ----------------------------------------------------------------------- checkout stats


def test_checkout_stats_count_outcomes_and_report_percentiles(conn):
    for index, duration in enumerate(range(100, 1001, 100)):
        record(conn, "Assigned" if index % 2 else "Reused", duration=duration)
    record(conn, "NoneAvailable", duration=50)
    record(conn, "NoneAvailable", minutes_ago=90)
    record(conn, "ProvisionFailed", duration=30000)
    record(conn, "Error")
    record(conn, "Assigned", duration=5, minutes_ago=60 * 30)
    exec_sql(conn, "INSERT INTO dbo.HostStartEvents (Hostname, RequestedAt, ReadyAt, Seconds) VALUES "
                   "('a', SYSUTCDATETIME(), SYSUTCDATETIME(), 60), ('b', SYSUTCDATETIME(), SYSUTCDATETIME(), 120), "
                   "('c', SYSUTCDATETIME(), SYSUTCDATETIME(), 300), "
                   "('d', DATEADD(DAY, -3, SYSUTCDATETIME()), DATEADD(DAY, -3, SYSUTCDATETIME()), 999)")

    stats = one(conn, "EXEC dbo.GetCheckoutStats @FromUtc=%s", (datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(hours=24),))

    assert (stats["Total"], stats["Assigned"], stats["Reused"]) == (14, 5, 5)
    assert (stats["NoneAvailable"], stats["ProvisionFailed"], stats["Errors"]) == (2, 1, 1)
    # Only successful checkouts count toward latency: PERCENTILE_CONT over 100..1000.
    assert (stats["P50Ms"], stats["P95Ms"]) == (550, 955)
    assert stats["DeniedLastHour"] == 1 and stats["LastDeniedUtc"].endswith("Z")
    assert (stats["HostStarts"], stats["StartP50Seconds"], stats["StartP95Seconds"]) == (3, 120, 282)


def test_checkout_stats_with_no_events_are_zero_and_null(conn):
    stats = one(conn, "EXEC dbo.GetCheckoutStats @FromUtc=NULL")
    assert (stats["Total"], stats["Assigned"], stats["NoneAvailable"], stats["DeniedLastHour"], stats["HostStarts"]) == (0, 0, 0, 0, 0)
    assert stats["P50Ms"] is None and stats["StartP95Seconds"] is None and stats["LastDeniedUtc"] is None


# ----------------------------------------------------------------------- attention items


def test_no_ready_hosts_is_flagged_unless_a_host_is_starting(conn):
    assert attention(conn) == []

    add_vm(conn, "lnx-busy", status="CheckedOut", username="alice", avdhost="avd", lease="7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C")
    add_vm(conn, "lnx-drain", net="Reachable")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE Hostname='lnx-drain'")
    assert kinds(attention(conn)) == ["no-ready-hosts"]

    # A host that is starting will be ready soon.
    booting = add_vm(conn, "lnx-boot", net="Unreachable", changed_minutes=2)
    assert attention(conn) == []
    exec_sql(conn, "DELETE FROM dbo.VirtualMachines WHERE VMID=%s", (booting,))
    assert kinds(attention(conn)) == ["no-ready-hosts"]

    add_vm(conn, "lnx-ready")
    assert attention(conn) == []


def test_denied_checkouts_in_the_window_are_counted(conn):
    add_vm(conn, "lnx-ready")
    record(conn, "NoneAvailable", minutes_ago=5)
    record(conn, "NoneAvailable", minutes_ago=20)
    record(conn, "NoneAvailable", minutes_ago=90)
    record(conn, "Assigned")

    items = attention(conn)
    assert kinds(items) == ["denied-checkouts"]
    assert items[0]["ItemCount"] == 2 and 290 <= items[0]["AgeSeconds"] <= 320
    assert attention(conn, DeniedMinutes=120)[0]["ItemCount"] == 3


def test_unreachable_hosts_are_timed_from_their_last_reachable_version(conn):
    add_vm(conn, "lnx-ready")
    never = add_vm(conn, "lnx-never", net="Unreachable", changed_minutes=40)
    recent = add_vm(conn, "lnx-recent", changed_minutes=40)
    set_status(conn, recent, "Unreachable")
    add_vm(conn, "lnx-booting", net="Unreachable", changed_minutes=3)
    add_vm(conn, "lnx-maint", net="Unreachable", status="Maintenance", changed_minutes=40)
    add_vm(conn, "lnx-off", power="Off", net="Unreachable", changed_minutes=40)

    items = attention(conn)
    assert [(i["Kind"], i["Hostname"]) for i in items] == [("unreachable", "lnx-never")]
    assert 40 * 60 - 5 <= items[0]["AgeSeconds"] <= 40 * 60 + 60 and items[0]["VMID"] == never

    backdate_history(conn, recent, 25)
    items = attention(conn)
    assert [i["Hostname"] for i in items] == ["lnx-never", "lnx-recent"]
    assert 25 * 60 - 5 <= items[1]["AgeSeconds"] <= 25 * 60 + 60


def test_cleanups_are_stuck_after_several_failed_attempts(conn):
    add_vm(conn, "lnx-ready")
    fresh = add_vm(conn, "lnx-fresh", cleanup=True, username="bob")
    add_vm(conn, "lnx-down", net="Unreachable", cleanup=True, username="carol", changed_minutes=2)
    exec_sql(conn, "INSERT INTO dbo.VirtualMachines (Hostname, PowerState, NetworkStatus, VmStatus, CleanupPending, CleanupUsername) "
                   "VALUES ('lnx-old', 'On', 'Reachable', 'Available', 1, 'dave')")

    items = attention(conn)
    assert [(i["Kind"], i["Hostname"], i["Username"]) for i in items] == [("cleanup-stuck", "lnx-old", "dave")]
    assert items[0]["AgeSeconds"] >= 7 * 24 * 3600 - 60

    backdate_history(conn, fresh, 20)
    assert [(i["Hostname"], i["Username"]) for i in attention(conn)] == [("lnx-old", "dave"), ("lnx-fresh", "bob")]


def test_never_connected_needs_a_current_heartbeat_without_the_user(conn):
    add_vm(conn, "lnx-ready")
    lease = "7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C"
    ids = {}
    for name, user in (("lnx-gone", "erin"), ("lnx-here", "frank"), ("lnx-stale", "grace"), ("lnx-new", "heidi")):
        ids[name] = add_vm(conn, name, status="CheckedOut", username=user, avdhost="avd", lease=lease)
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET AssignedDate=DATEADD(MINUTE, -45, GETDATE()), "
                   "LastCheckoutDate=DATEADD(MINUTE, -45, GETDATE()) WHERE Hostname <> 'lnx-new'")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET AssignedDate=DATEADD(MINUTE, -45, GETDATE()), "
                   "LastCheckoutDate=DATEADD(MINUTE, -5, GETDATE()) WHERE Hostname = 'lnx-new'")
    for hostname, sessions, age in (("lnx-gone", [{"username": "someone"}], 10), ("lnx-here", [{"username": "frank"}], 10),
                                    ("lnx-stale", [], 900), ("lnx-new", [], 10)):
        exec_sql(conn, "INSERT INTO dbo.HostHeartbeats (Hostname, ReceivedAt, SessionsJson) "
                       "VALUES (%s, DATEADD(SECOND, -%s, SYSUTCDATETIME()), %s)", (hostname, age, json.dumps(sessions)))

    items = attention(conn)
    assert [(i["Kind"], i["Hostname"], i["Username"]) for i in items] == [("never-connected", "lnx-gone", "erin")]
    assert 45 * 60 - 5 <= items[0]["AgeSeconds"] <= 45 * 60 + 60


# ----------------------------------------------------------------------- purge and summary


def test_purge_removes_old_events_in_batches(conn):
    for days in (100, 100, 100, 10):
        record(conn, "Assigned", minutes_ago=days * 24 * 60)
    exec_sql(conn, "INSERT INTO dbo.HostStartEvents (Hostname, RequestedAt, ReadyAt, Seconds) VALUES "
                   "('old', DATEADD(DAY, -120, SYSUTCDATETIME()), DATEADD(DAY, -120, SYSUTCDATETIME()), 60), "
                   "('new', SYSUTCDATETIME(), SYSUTCDATETIME(), 60)")

    first = exec_sql(conn, "EXEC dbo.PurgeCheckoutEvents @RetentionDays=90, @BatchSize=2")[0]
    assert (first["RetentionDays"], first["CheckoutEventsDeleted"], first["HostStartEventsDeleted"], first["MoreRemaining"]) == (90, 2, 1, True)
    second = exec_sql(conn, "EXEC dbo.PurgeCheckoutEvents @RetentionDays=90, @BatchSize=2")[0]
    assert (second["CheckoutEventsDeleted"], second["HostStartEventsDeleted"], second["MoreRemaining"]) == (1, 0, False)
    assert one(conn, "SELECT COUNT(*) AS N FROM dbo.CheckoutEvents")["N"] == 1

    clamped = exec_sql(conn, "EXEC dbo.PurgeCheckoutEvents @RetentionDays=1")[0]
    assert clamped["RetentionDays"] == 7 and clamped["CheckoutEventsDeleted"] == 1


def test_vm_summary_counts_serviceable_and_in_use_as_the_scaler_does(conn):
    lease = "7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C"
    add_vm(conn, "ready")
    add_vm(conn, "busy", status="CheckedOut", username="a", avdhost="avd", lease=lease)
    add_vm(conn, "released", status="Released", username="b", avdhost="avd", lease=lease)
    add_vm(conn, "cleanup", cleanup=True)
    add_vm(conn, "booting", net="Unreachable", changed_minutes=2)
    add_vm(conn, "lost", net="Unreachable", changed_minutes=30)
    add_vm(conn, "maint", status="Maintenance")
    drain = add_vm(conn, "drain")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE VMID=%s", (drain,))
    add_vm(conn, "off", power="Off", net="Unreachable")

    summary = one(conn, "EXEC dbo.GetVmSummary")
    scaler = exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1")[0]
    assert (summary["Serviceable"], summary["InUse"]) == (scaler["Serviceable"], scaler["InUse"]) == (5, 3)
    assert (summary["TotalVMs"], summary["Ready"], summary["Draining"], summary["PoweredOn"]) == (9, 1, 1, 8)
