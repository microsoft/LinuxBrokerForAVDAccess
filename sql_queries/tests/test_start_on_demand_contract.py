"""Contract tests for 4.1 start on demand and scale to zero (144-156): the policy settings, the
Starting outcome, waiting users, dbo.ReserveVmForStart, scaling with waiting users and a minimum
of 0, and the dashboard's wait figures."""

import json
from datetime import datetime, timedelta, timezone

from conftest import add_vm, exec_sql, one, rows


def set_rule(conn, **values):
    rule = {"MinVMs": 0, "MaxVMs": 5, "ScaleUpRatio": 70, "ScaleUpIncrement": 1, "ScaleDownRatio": 30,
            "ScaleDownIncrement": 1, "StopMode": "PowerOff"}
    rule.update(values)
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(conn, "INSERT INTO dbo.VmScalingRules (MinVMs,MaxVMs,ScaleUpRatio,ScaleUpIncrement,ScaleDownRatio,ScaleDownIncrement,StopMode) "
                   "VALUES (%s,%s,%s,%s,%s,%s,%s)", tuple(rule[k] for k in ("MinVMs", "MaxVMs", "ScaleUpRatio", "ScaleUpIncrement",
                                                                         "ScaleDownRatio", "ScaleDownIncrement", "StopMode")))


def set_start_on_demand(conn, enabled=None, max_pending=None, updated_by="admin@contoso.com"):
    return exec_sql(conn, "EXEC dbo.SetScalingPolicyStartOnDemand @Enabled=%s, @MaxPendingStarts=%s, @UpdatedBy=%s",
                    (enabled, max_pending, updated_by))[0]


def reserve(conn, username="alice", avdhost="avd-01"):
    return exec_sql(conn, "EXEC dbo.ReserveVmForStart @Username=%s, @AvdHost=%s", (username, avdhost))[0]


def record(conn, outcome, username="alice", seconds_ago=None, avdhost="avd-01", client_version=None):
    event_id = exec_sql(conn, "EXEC dbo.RecordCheckoutEvent @Username=%s, @AvdHost=%s, @Outcome=%s, @DurationMs=%s, @Hostname=%s, "
                              "@ClientVersion=%s", (username, avdhost, outcome, 100, None, client_version))[0]["EventID"]
    if seconds_ago is not None:
        exec_sql(conn, "UPDATE dbo.CheckoutEvents SET OccurredAt=DATEADD(SECOND, -%s, SYSUTCDATETIME()) WHERE EventID=%s",
                 (seconds_ago, event_id))
    return event_id


def waiting(conn):
    return sorted(r["Username"] for r in rows(conn, "SELECT Username FROM dbo.fnWaitingCheckoutUsers()"))


def booting(conn, hostname, seconds_ago=0, cleanup=False):
    vmid = add_vm(conn, hostname, net="Unreachable", cleanup=cleanup)
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET PowerStateChangedDate=DATEADD(SECOND, -%s, GETDATE()) WHERE VMID=%s",
             (seconds_ago, vmid))
    return vmid


def vm(conn, vmid):
    return one(conn, "SELECT Hostname, PowerState, NetworkStatus, VmStatus, StartRequestedAt, "
                     "DATEDIFF(SECOND, PowerStateChangedDate, GETDATE()) AS ChangedSecondsAgo FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))


def dry_run(conn):
    return exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1")[0]


def start_times(conn, *seconds):
    for value in seconds:
        exec_sql(conn, "INSERT INTO dbo.HostStartEvents (Hostname, RequestedAt, ReadyAt, Seconds) "
                       "VALUES ('hist', SYSUTCDATETIME(), SYSUTCDATETIME(), %s)", (value,))


# ----------------------------------------------------------------------- policy and constraints


def test_start_on_demand_is_on_by_default_and_can_be_changed(conn):
    policy = exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]
    assert (policy["StartOnDemandEnabled"], policy["MaxPendingStarts"], policy["ZeroMinimumCount"]) == (True, 2, 0)

    assert set_start_on_demand(conn)["Result"] == "Invalid"
    invalid = set_start_on_demand(conn, max_pending=21)
    assert (invalid["Result"], invalid["Message"]) == ("Invalid", "maxpendingstarts must be between 1 and 20.")
    assert set_start_on_demand(conn, max_pending=0)["Result"] == "Invalid"

    updated = set_start_on_demand(conn, enabled=False, max_pending=4)
    assert updated == {
        "Result": "Updated", "Message": None, "StartOnDemandEnabled": False, "MaxPendingStarts": 4,
        "PreviousStartOnDemandEnabled": True, "PreviousMaxPendingStarts": 2, "ZeroMinimumCount": 0,
    }
    assert set_start_on_demand(conn, enabled=False)["Result"] == "Unchanged"
    # A NULL keeps the other value.
    assert set_start_on_demand(conn, enabled=True)["MaxPendingStarts"] == 4

    policy = exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]
    assert (policy["StartOnDemandEnabled"], policy["MaxPendingStarts"], policy["UpdatedBy"]) == (True, 4, "admin@contoso.com")

    for sql in ("UPDATE dbo.ScalingPolicy SET MaxPendingStarts=0", "UPDATE dbo.ScalingPolicy SET MaxPendingStarts=21"):
        try:
            exec_sql(conn, sql)
        except Exception:
            conn.rollback()
        else:
            raise AssertionError(f"{sql} should be refused")


def test_a_minimum_of_zero_needs_start_on_demand(conn):
    set_rule(conn, MinVMs=0)
    save = ("EXEC dbo.SaveScalingSchedule @ScheduleID=NULL, @Name=%s, @Enabled=%s, @DaysOfWeek=31, @StartTime='08:00', "
            "@EndTime='18:00', @MinVMs=%s, @MaxVMs=4, @ScaleUpRatio=60, @ScaleUpIncrement=1, @ScaleDownRatio=20, "
            "@ScaleDownIncrement=1, @StopMode=NULL, @UpdatedBy=NULL")
    assert exec_sql(conn, save, ("Quiet days", True, 0))[0]["Result"] == "Created"
    exec_sql(conn, "UPDATE dbo.ScalingSchedules SET Enabled=0")
    assert exec_sql(conn, save, ("Busy days", True, 1))[0]["Result"] == "Created"
    exec_sql(conn, "UPDATE dbo.ScalingSchedules SET Enabled=1, MinVMs=0 WHERE Name='Busy days'")

    # The rule and one enabled window have a minimum of 0; the disabled window does not count.
    assert exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]["ZeroMinimumCount"] == 2
    turned_off = set_start_on_demand(conn, enabled=False)
    assert (turned_off["Result"], turned_off["ZeroMinimumCount"]) == ("Updated", 2)

    refused = exec_sql(conn, save, ("Night", False, 0))[0]
    assert (refused["Result"], refused["Message"]) == ("Invalid", "minvms can be 0 only while start on demand is on.")

    for sql in ("UPDATE dbo.VmScalingRules SET MinVMs=-1", "UPDATE dbo.ScalingSchedules SET MinVMs=-1",
                "UPDATE dbo.ScalingSchedules SET MinVMs=0, MaxVMs=0"):
        try:
            exec_sql(conn, sql)
        except Exception:
            conn.rollback()
        else:
            raise AssertionError(f"{sql} should be refused")


def test_the_starting_outcome_is_stored(conn):
    record(conn, "Starting")
    assert one(conn, "SELECT Outcome FROM dbo.CheckoutEvents")["Outcome"] == "Starting"
    exec_sql(conn, "INSERT INTO dbo.CheckoutEvents (Username, Outcome) VALUES ('bob', 'Starting')")


def test_the_policy_lists_avd_hosts_whose_script_cannot_wait(conn):
    policy = exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]
    assert (policy["AvdHostsSeen"], policy["AvdHostsOutdated"]) == (0, 0)
    assert (policy["OutdatedAvdHostsJson"], policy["AvdClientVersionsJson"]) == (None, None)

    record(conn, "Assigned", avdhost="avd-01", client_version="2.0.0")
    record(conn, "Assigned", avdhost="avd-02", client_version="2.0.0", seconds_ago=60)
    record(conn, "Assigned", avdhost="avd-03")
    record(conn, "Reused", avdhost="avd-04", client_version="2.1.0")
    # The latest checkout decides: avd-05 was updated, avd-06 went back to an old script.
    record(conn, "Assigned", avdhost="avd-05", seconds_ago=600)
    record(conn, "Reused", avdhost="avd-05", client_version="2.0.0")
    record(conn, "Assigned", avdhost="avd-06", client_version="2.0.0", seconds_ago=600)
    record(conn, "Reused", avdhost="avd-06", client_version="")
    # An AVD host not seen for a week is left out.
    record(conn, "Assigned", avdhost="avd-07", seconds_ago=8 * 86400)

    policy = exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]
    assert (policy["AvdHostsSeen"], policy["AvdHostsOutdated"]) == (6, 2)
    assert json.loads(policy["OutdatedAvdHostsJson"]) == [{"AvdHost": "avd-03"}, {"AvdHost": "avd-06"}]
    assert json.loads(policy["AvdClientVersionsJson"]) == [{"ClientVersion": "2.0.0", "AvdHosts": 3},
                                                          {"ClientVersion": "2.1.0", "AvdHosts": 1}]
    assert one(conn, "SELECT ClientVersion FROM dbo.CheckoutEvents WHERE AvdHost='avd-06' AND Outcome='Reused'")["ClientVersion"] is None


# ----------------------------------------------------------------------- waiting users


def test_a_user_waits_while_their_latest_event_in_five_minutes_is_starting(conn):
    record(conn, "Starting", "alice", seconds_ago=90)
    record(conn, "Starting", "alice", seconds_ago=30)
    record(conn, "Starting", "bob", seconds_ago=120)
    record(conn, "Assigned", "bob", seconds_ago=10)
    record(conn, "Starting", "carol", seconds_ago=400)
    record(conn, "Assigned", "dave", seconds_ago=200)
    record(conn, "Starting", "dave", seconds_ago=60)
    record(conn, "Starting", "erin", seconds_ago=100)
    record(conn, "NoneAvailable", "erin", seconds_ago=50)

    assert waiting(conn) == ["alice", "dave"]


# ----------------------------------------------------------------------- reserving a start


def test_reserve_is_disabled_while_start_on_demand_is_off(conn):
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    set_start_on_demand(conn, enabled=False)
    result = reserve(conn)
    assert (result["Result"], result["VMID"], result["RetryAfterSeconds"]) == ("Disabled", None, None)
    assert one(conn, "SELECT PowerState FROM dbo.VirtualMachines")["PowerState"] == "Off"


def test_reserve_says_ready_now_when_a_host_became_ready(conn):
    add_vm(conn, "ready-1")
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    assert reserve(conn)["Result"] == "ReadyNow"
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")[0]["c"] == 0


def test_reserve_starts_the_first_free_stopped_host_as_scaling_would(conn, second_conn):
    set_rule(conn, MinVMs=0, MaxVMs=5)
    add_vm(conn, "busy-1", status="CheckedOut", username="zoe", avdhost="avd", lease="7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C")
    drained = add_vm(conn, "off-drain", power="Off", net="Unreachable")
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET DrainRequested=1 WHERE VMID=%s", (drained,))
    add_vm(conn, "off-cleanup", power="Off", net="Unreachable", cleanup=True)
    add_vm(conn, "off-maint", power="Off", net="Unreachable", status="Maintenance")
    first = add_vm(conn, "off-1", power="Off", net="Unreachable")
    add_vm(conn, "off-2", power="Off", net="Unreachable")

    result = reserve(conn, "alice", "avd-07")
    assert (result["Result"], result["VMID"], result["VMName"]) == ("Started", first, "off-1")
    assert (result["PreviousNetworkStatus"], result["RetryAfterSeconds"], result["Waiting"], result["Booting"]) == ("Unreachable", 60, 1, 1)
    started = vm(conn, first)
    assert (started["PowerState"], started["NetworkStatus"], started["VmStatus"]) == ("On", "Unreachable", "Available")
    assert started["StartRequestedAt"] is not None and 0 <= started["ChangedSecondsAgo"] < 60

    log = one(conn, "SELECT * FROM dbo.VmScalingActivityLog WHERE ActivityID=%s", (result["ActivityID"],))
    assert (log["ActionTaken"], log["VMsPoweredOn"], log["VMsPoweredOff"], log["CurrentRunningVMs"], log["NewTotalVMs"]) == (
        "Start On Demand", 1, 0, 1, 2)
    assert (log["MinVMs"], log["MaxVMs"], log["PhaseName"]) == (0, 5, "Default rule")
    assert "alice" in log["Notes"] and "avd-07" in log["Notes"] and "off-1" in log["Outcome"]

    # The scaling lock is released with the caller's transaction.
    cur = second_conn().cursor()
    cur.execute("BEGIN TRAN; DECLARE @r INT; EXEC @r = sp_getapplock @Resource='LinuxBroker.Scaling', @LockMode='Exclusive', "
                "@LockOwner='Transaction', @LockTimeout=0; SELECT @r AS r")
    assert cur.fetchone()[0] >= 0
    cur.execute("ROLLBACK")


def test_a_waiting_user_waits_for_the_host_already_starting(conn):
    start_times(conn, 50, 70, 80)
    first = booting(conn, "boot-1", seconds_ago=20)
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    record(conn, "Starting", "alice", seconds_ago=20)

    result = reserve(conn, "alice")
    assert (result["Result"], result["VMID"], result["Waiting"], result["Booting"]) == ("AlreadyStarting", None, 1, 1)
    # The median start is 70 seconds, and the host has been starting for 20.
    assert 48 <= result["RetryAfterSeconds"] <= 50
    assert json.loads(result["BootingHostsJson"]) == [{"VMID": first, "Hostname": "boot-1", "IPAddress": "10.0.0.1"}]
    assert one(conn, "SELECT PowerState FROM dbo.VirtualMachines WHERE Hostname='off-1'")["PowerState"] == "Off"


def test_retry_after_is_kept_between_30_and_120_seconds(conn):
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    add_vm(conn, "off-2", power="Off", net="Unreachable")
    start_times(conn, 300, 400)
    assert reserve(conn, "alice")["RetryAfterSeconds"] == 120
    record(conn, "Starting", "alice")

    exec_sql(conn, "DELETE FROM dbo.HostStartEvents")
    start_times(conn, 10)
    second = reserve(conn, "bob")
    assert (second["Result"], second["RetryAfterSeconds"]) == ("Started", 30)
    record(conn, "Starting", "bob")

    # A host that has been starting for longer than the median still asks for 30 seconds.
    exec_sql(conn, "UPDATE dbo.VirtualMachines SET PowerStateChangedDate=DATEADD(SECOND, -200, GETDATE()) WHERE PowerState='On'")
    third = reserve(conn, "alice")
    assert (third["Result"], third["RetryAfterSeconds"]) == ("AlreadyStarting", 30)


def test_each_waiting_user_gets_a_host_up_to_the_pending_limit(conn):
    for index in range(4):
        add_vm(conn, f"off-{index}", power="Off", net="Unreachable")

    assert reserve(conn, "alice")["Result"] == "Started"
    record(conn, "Starting", "alice")
    second = reserve(conn, "bob")
    assert (second["Result"], second["VMName"], second["Waiting"], second["Booting"]) == ("Started", "off-1", 2, 2)
    record(conn, "Starting", "bob")

    third = reserve(conn, "carol")
    assert (third["Result"], third["Waiting"], third["Booting"]) == ("AlreadyStarting", 3, 2)
    assert [h["Hostname"] for h in json.loads(third["BootingHostsJson"])] == ["off-0", "off-1"]

    set_start_on_demand(conn, max_pending=3)
    assert reserve(conn, "carol")["Result"] == "Started"


def test_booting_counts_only_free_hosts_started_in_the_last_ten_minutes(conn):
    exec_sql(conn, "UPDATE dbo.ScalingPolicy SET MaxPendingStarts=5")
    booting(conn, "stale", seconds_ago=11 * 60)
    booting(conn, "cleaning", seconds_ago=30, cleanup=True)
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    record(conn, "Starting", "bob")

    # One host is starting (the one being cleaned), for two waiting users.
    result = reserve(conn, "alice")
    assert (result["Result"], result["Booting"], result["Waiting"]) == ("Started", 2, 2)

    record(conn, "Starting", "alice")
    waiting_again = reserve(conn, "alice")
    assert waiting_again["Result"] == "AlreadyStarting"
    # A host being cleaned counts as starting, but is not offered for a probe: a checkout could not take it yet.
    assert [h["Hostname"] for h in json.loads(waiting_again["BootingHostsJson"])] == ["off-1"]


def test_reserve_stops_at_the_phase_maximum(conn):
    set_rule(conn, MinVMs=0, MaxVMs=1)
    add_vm(conn, "busy-1", status="CheckedOut", username="zoe", avdhost="avd", lease="7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C")
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    assert reserve(conn, "alice")["Result"] == "AtMaximum"

    # With a host already starting, a user at the maximum waits for it instead.
    exec_sql(conn, "DELETE FROM dbo.VirtualMachines WHERE Hostname='busy-1'")
    booting(conn, "boot-1", seconds_ago=10)
    record(conn, "Starting", "bob")
    result = reserve(conn, "alice")
    assert (result["Result"], result["Booting"], result["Waiting"]) == ("AlreadyStarting", 1, 2)


def test_reserve_reports_no_candidate_when_nothing_can_start(conn):
    add_vm(conn, "busy-1", status="CheckedOut", username="zoe", avdhost="avd", lease="7F6E3C1A-8E0C-4E5B-9A8C-0D1E2F3A4B5C")
    add_vm(conn, "off-cleanup", power="Off", net="Unreachable", cleanup=True)
    result = reserve(conn, "alice")
    assert (result["Result"], result["RetryAfterSeconds"], result["BootingHostsJson"]) == ("NoCandidate", None, "[]")


def test_reserve_is_busy_while_scaling_holds_the_lock(conn, second_conn):
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    cur = second_conn().cursor()
    cur.execute("BEGIN TRAN; DECLARE @r INT; EXEC @r = sp_getapplock @Resource='LinuxBroker.Scaling', @LockMode='Exclusive', "
                "@LockOwner='Transaction', @LockTimeout=0; SELECT @r")
    try:
        result = reserve(conn, "alice")
        assert (result["Result"], result["RetryAfterSeconds"]) == ("Busy", 30)
        assert one(conn, "SELECT PowerState FROM dbo.VirtualMachines")["PowerState"] == "Off"
    finally:
        cur.execute("ROLLBACK")


# ----------------------------------------------------------------------- scaling


def test_scaling_stops_idle_hosts_down_to_zero_while_start_on_demand_is_on(conn):
    set_rule(conn, MinVMs=0, MaxVMs=5)
    add_vm(conn, "idle-1", changed_minutes=30)

    preview = dry_run(conn)
    assert (preview["Action"], preview["MinVMs"], preview["Waiting"], preview["StartOnDemandEnabled"]) == ("PowerOff", 0, 0, True)
    stopped = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [(r["ActionType"], r["VMName"]) for r in stopped] == [("PowerOff", "idle-1")]

    # Nothing is running and nobody is waiting: nothing to do.
    preview = dry_run(conn)
    assert (preview["Action"], preview["Serviceable"], preview["Utilization"]) == ("None", 0, 0)


def test_a_minimum_of_zero_is_read_as_one_while_start_on_demand_is_off(conn):
    set_rule(conn, MinVMs=0, MaxVMs=5)
    set_start_on_demand(conn, enabled=False)
    add_vm(conn, "off-1", power="Off", net="Unreachable")

    preview = dry_run(conn)
    assert (preview["Action"], preview["MinVMs"], preview["StartOnDemandEnabled"]) == ("PowerOn", 1, False)
    assert preview["Reason"] == "Serviceable hosts are below the minimum."
    exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    notes = one(conn, "SELECT TOP 1 Notes FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")["Notes"]
    assert "Start on demand is off, so MinVMs 0 was read as 1." in notes and "Rule Min=1" in notes


def test_waiting_users_count_as_demand(conn):
    set_rule(conn, MinVMs=0, MaxVMs=5, ScaleUpIncrement=1)
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    add_vm(conn, "off-2", power="Off", net="Unreachable")
    record(conn, "Starting", "alice")

    preview = dry_run(conn)
    assert (preview["Action"], preview["Waiting"], float(preview["Utilization"]), preview["RequestCount"]) == ("PowerOn", 1, 100.0, 1)
    assert preview["Reason"] == "Utilization is at or above the scale-up ratio. 1 user is waiting for a host to start."

    exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    notes = one(conn, "SELECT TOP 1 Notes FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")["Notes"]
    assert "inUse=0, waiting=1," in notes


def test_scaling_down_leaves_a_host_for_each_waiting_user(conn):
    set_rule(conn, MinVMs=0, MaxVMs=20, ScaleDownIncrement=20)
    for index in range(10):
        add_vm(conn, f"idle-{index}", changed_minutes=30)

    assert dry_run(conn)["RequestCount"] == 10
    record(conn, "Starting", "alice")
    preview = dry_run(conn)
    assert (preview["Action"], preview["RequestCount"], float(preview["Utilization"])) == ("PowerOff", 9, 10.0)
    assert preview["Reason"].endswith("1 user is waiting for a host to start.")


# ----------------------------------------------------------------------- dashboard


def test_checkout_stats_measure_waits_and_leave_starting_out_of_the_total(conn):
    record(conn, "Starting", "alice", seconds_ago=600)
    record(conn, "Starting", "alice", seconds_ago=540)
    record(conn, "Assigned", "alice", seconds_ago=480)
    record(conn, "Starting", "bob", seconds_ago=300)
    record(conn, "NoneAvailable", "bob", seconds_ago=240)
    record(conn, "Starting", "carol", seconds_ago=900)
    record(conn, "Reused", "carol", seconds_ago=660)
    record(conn, "Starting", "dave", seconds_ago=30)
    # A wait that began before the period is left out of it.
    record(conn, "Starting", "erin", seconds_ago=3900)
    record(conn, "Assigned", "erin", seconds_ago=3780)

    since = datetime.now(timezone.utc).replace(tzinfo=None) - timedelta(hours=1)
    stats = one(conn, "EXEC dbo.GetCheckoutStats @FromUtc=%s", (since,))
    assert (stats["Total"], stats["Assigned"], stats["Reused"], stats["NoneAvailable"], stats["Starting"]) == (3, 1, 1, 1, 5)
    assert (stats["Waits"], stats["WaitsServed"], stats["WaitingNow"]) == (4, 2, 1)
    # alice waited 120 seconds and carol 240.
    assert (stats["WaitP50Seconds"], stats["WaitP95Seconds"]) == (180, 234)


def test_utilization_series_count_waiting_users_and_scaling_runs_only(conn):
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    start = now - timedelta(minutes=30)
    for outcome, user in (("Starting", "alice"), ("Starting", "alice"), ("Starting", "bob"), ("Assigned", "alice")):
        exec_sql(conn, "INSERT INTO dbo.CheckoutEvents (OccurredAt, Username, Outcome) VALUES (%s, %s, %s)",
                 (now - timedelta(minutes=5), user, outcome))
    for action, running in (("No Action", 2), ("Start On Demand", 3)):
        exec_sql(conn, "INSERT INTO dbo.VmScalingActivityLog (CheckTimestamp, CurrentRunningVMs, CurrentInUseVMs, ActionTaken, NewTotalVMs, "
                       "ServiceableVMs, MinVMs, MaxVMs) VALUES (DATEADD(MINUTE, -5, GETDATE()), %s, 0, %s, %s, %s, 0, 5)",
                 (running, action, running, running))

    series = rows(conn, "EXEC dbo.GetUtilizationSeries @FromUtc=%s, @ToUtc=%s, @BucketMinutes=60", (start, now + timedelta(minutes=1)))
    assert len(series) == 1
    bucket = series[0]
    assert (bucket["Runs"], float(bucket["PoweredOn"]), bucket["Checkouts"], bucket["Waited"]) == (1, 2.0, 1, 2)


def test_no_ready_hosts_is_the_idle_state_of_a_pool_scaled_to_zero(conn):
    set_rule(conn, MinVMs=0, MaxVMs=5)
    add_vm(conn, "off-1", power="Off", net="Unreachable")
    attention = lambda: [r["Kind"] for r in rows(conn, "EXEC dbo.GetAttentionItems")]
    assert attention() == []

    record(conn, "Starting", "alice")
    assert attention() == ["no-ready-hosts"]

    exec_sql(conn, "DELETE FROM dbo.CheckoutEvents")
    set_start_on_demand(conn, enabled=False)
    assert attention() == ["no-ready-hosts"]

    set_start_on_demand(conn, enabled=True)
    set_rule(conn, MinVMs=1, MaxVMs=5)
    assert attention() == ["no-ready-hosts"]


def test_start_on_demand_objects_exist(conn):
    procedures = {r["name"] for r in rows(conn, "SELECT name FROM sys.procedures")}
    assert {"ReserveVmForStart", "SetScalingPolicyStartOnDemand"} <= procedures
    functions = {r["name"] for r in rows(conn, "SELECT name FROM sys.objects WHERE type IN ('IF', 'TF', 'FN')")}
    assert "fnWaitingCheckoutUsers" in functions
