"""Contract tests for 2.5 scaling policy and schedules (101-114): week intervals, the active
phase, saving windows without overlaps, the policy time zone, the dry run and the MinVMs cap."""

import json

from conftest import add_vm, exec_sql, one, rows


MON, TUE, WED, THU, FRI, SAT, SUN = 1, 2, 4, 8, 16, 32, 64
WEEKDAYS = MON | TUE | WED | THU | FRI


def reset_rule(conn, **values):
    rule = {"MinVMs": 1, "MaxVMs": 5, "ScaleUpRatio": 70, "ScaleUpIncrement": 1, "ScaleDownRatio": 30,
            "ScaleDownIncrement": 1, "StopMode": "PowerOff"}
    rule.update(values)
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    exec_sql(conn, "INSERT INTO dbo.VmScalingRules (MinVMs,MaxVMs,ScaleUpRatio,ScaleUpIncrement,ScaleDownRatio,ScaleDownIncrement,StopMode) "
                   "VALUES (%s,%s,%s,%s,%s,%s,%s)", tuple(rule[k] for k in ("MinVMs", "MaxVMs", "ScaleUpRatio", "ScaleUpIncrement",
                                                                         "ScaleDownRatio", "ScaleDownIncrement", "StopMode")))


def save(conn, name="Business hours", days=WEEKDAYS, start="08:00", end="18:00", enabled=True, schedule_id=None, **values):
    rule = {"MinVMs": 3, "MaxVMs": 8, "ScaleUpRatio": 60, "ScaleUpIncrement": 2, "ScaleDownRatio": 20,
            "ScaleDownIncrement": 1, "StopMode": None}
    rule.update(values)
    return exec_sql(
        conn,
        "EXEC dbo.SaveScalingSchedule @ScheduleID=%s, @Name=%s, @Enabled=%s, @DaysOfWeek=%s, @StartTime=%s, @EndTime=%s, "
        "@MinVMs=%s, @MaxVMs=%s, @ScaleUpRatio=%s, @ScaleUpIncrement=%s, @ScaleDownRatio=%s, @ScaleDownIncrement=%s, "
        "@StopMode=%s, @UpdatedBy=%s",
        (schedule_id, name, enabled, days, start, end, rule["MinVMs"], rule["MaxVMs"], rule["ScaleUpRatio"],
         rule["ScaleUpIncrement"], rule["ScaleDownRatio"], rule["ScaleDownIncrement"], rule["StopMode"], "admin@contoso.com"),
    )[0]


def phase(conn, at_utc):
    found = rows(conn, "SELECT * FROM dbo.fnActiveScalingPhase(%s)", (at_utc,))
    return found[0] if found else None


def intervals(conn, days, start, end):
    return sorted((r["StartMinute"], r["EndMinute"]) for r in rows(
        conn, "SELECT * FROM dbo.fnScheduleWeekIntervals(%s, %s, %s)", (days, start, end)))


def set_zone(conn, zone):
    return exec_sql(conn, "EXEC dbo.SetScalingPolicyTimeZone @TimeZone=%s, @UpdatedBy=%s", (zone, "admin@contoso.com"))[0]


def dry_run(conn, at_utc=None, override=None):
    return exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=1, @AtUtc=%s, @OverrideJson=%s",
                    (at_utc, json.dumps(override) if override is not None else None))[0]


# ----------------------------------------------------------------------- windows


def test_week_intervals_cover_midnight_and_the_sunday_wrap(conn):
    assert intervals(conn, MON | WED, "09:00", "17:00") == [(540, 1020), (2 * 1440 + 540, 2 * 1440 + 1020)]
    # Friday 22:00 to Saturday 02:00.
    assert intervals(conn, FRI, "22:00", "02:00") == [(4 * 1440 + 1320, 5 * 1440 + 120)]
    # Sunday 23:00 runs into Monday 01:00, at the start of the week.
    assert intervals(conn, SUN, "23:00", "01:00") == [(0, 60), (6 * 1440 + 1380, 10080)]
    # Ending at midnight is the end of the day, not a zero-length window.
    assert intervals(conn, TUE, "18:00", "00:00") == [(1440 + 1080, 2 * 1440)]


def test_the_default_rule_applies_outside_every_window(conn):
    reset_rule(conn, MinVMs=1, MaxVMs=4, StopMode="Deallocate")
    save(conn)

    monday_morning = phase(conn, "2026-09-21T09:00:00")
    assert monday_morning["Source"] == "Schedule" and monday_morning["PhaseName"] == "Business hours"
    assert monday_morning["MinVMs"] == 3 and monday_morning["MaxVMs"] == 8
    # The window names no stop mode, so the rule's applies.
    assert monday_morning["StopMode"] == "Deallocate"

    monday_night = phase(conn, "2026-09-21T19:00:00")
    assert monday_night["Source"] == "Rule" and monday_night["PhaseName"] == "Default rule" and monday_night["MinVMs"] == 1
    saturday = phase(conn, "2026-09-26T10:00:00")
    assert saturday["Source"] == "Rule"
    # The end time is exclusive.
    assert phase(conn, "2026-09-21T18:00:00")["Source"] == "Rule"
    assert phase(conn, "2026-09-21T08:00:00")["Source"] == "Schedule"


def test_windows_are_read_in_the_policy_time_zone_through_daylight_saving(conn):
    reset_rule(conn)
    save(conn, start="07:30", end="19:00")
    assert set_zone(conn, "Eastern Standard Time")["Result"] == "Updated"

    # 12:00 UTC is 08:00 in July (EDT) and 07:00 in January (EST).
    july = phase(conn, "2026-07-01T12:00:00")
    assert july["Source"] == "Schedule" and july["TimeZone"] == "Eastern Standard Time"
    assert str(july["LocalTime"]).startswith("2026-07-01 08:00")
    january = phase(conn, "2026-01-14T12:00:00")
    assert january["Source"] == "Rule" and str(january["LocalTime"]).startswith("2026-01-14 07:00")


def test_overnight_and_disabled_windows(conn):
    reset_rule(conn)
    save(conn, name="Night shift", days=FRI, start="22:00", end="02:00", MinVMs=2)
    save(conn, name="Weekend", days=SAT | SUN, start="09:00", end="17:00", enabled=False)

    assert phase(conn, "2026-09-26T01:30:00")["PhaseName"] == "Night shift"
    assert phase(conn, "2026-09-26T02:00:00")["Source"] == "Rule"
    # A disabled window never applies.
    assert phase(conn, "2026-09-26T10:00:00")["Source"] == "Rule"


def test_no_rule_and_no_window_resolves_to_nothing(conn):
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    assert phase(conn, "2026-09-21T09:00:00") is None
    save(conn)
    only_window = phase(conn, "2026-09-21T09:00:00")
    assert only_window["Source"] == "Schedule" and only_window["StopMode"] == "PowerOff" and only_window["RuleID"] is None


# -------------------------------------------------------------------- saving


def test_enabled_windows_cannot_overlap(conn):
    first = save(conn)
    assert first["Result"] == "Created" and first["ScheduleID"]

    clash = save(conn, name="Lunch peak", days=WED, start="11:00", end="14:00")
    assert clash["Result"] == "Overlap" and clash["OverlapsName"] == "Business hours"
    assert clash["OverlapsScheduleID"] == first["ScheduleID"]

    # Touching at the boundary is fine, a disabled window may overlap, and a window never
    # overlaps itself.
    assert save(conn, name="Evening", days=WEEKDAYS, start="18:00", end="22:00")["Result"] == "Created"
    assert save(conn, name="Draft", days=WED, start="11:00", end="14:00", enabled=False)["Result"] == "Created"
    assert save(conn, schedule_id=first["ScheduleID"], start="07:30", end="18:00")["Result"] == "Updated"

    # An overnight window that wraps into Monday morning clashes with business hours.
    wrap = save(conn, name="Sunday night", days=SUN, start="23:00", end="09:00")
    assert wrap["Result"] == "Overlap"

    saved = {r["Name"]: r for r in exec_sql(conn, "EXEC dbo.GetScalingSchedules")}
    assert saved["Business hours"]["StartTime"] == "07:30" and saved["Business hours"]["EndTime"] == "18:00"
    assert saved["Draft"]["Enabled"] is False and saved["Evening"]["UpdatedBy"] == "admin@contoso.com"


def test_saving_validates_like_the_api(conn):
    cases = [
        ({"name": "  "}, "name is required."),
        ({"days": 0}, "Choose at least one day."),
        ({"start": "08:00", "end": "08:00"}, "start and end must differ."),
        ({"MinVMs": 0}, "minvms must be at least 1."),
        ({"MinVMs": 5, "MaxVMs": 5}, "maxvms must be greater than minvms."),
        ({"ScaleUpRatio": 101}, "scaleupratio must be between 0 and 100."),
        ({"ScaleUpRatio": 20, "ScaleDownRatio": 20}, "scaleupratio must be greater than scaledownratio."),
        ({"ScaleDownIncrement": 0}, "scaledownincrement must be at least 1."),
        ({"StopMode": "Hibernate"}, "stopmode must be PowerOff or Deallocate."),
    ]
    for values, message in cases:
        result = save(conn, **values)
        assert (result["Result"], result["Message"]) == ("Invalid", message), values
    assert save(conn, schedule_id=424242)["Result"] == "NotFound"
    assert exec_sql(conn, "EXEC dbo.GetScalingSchedules") == []


def test_deleting_a_window(conn):
    created = save(conn)
    assert exec_sql(conn, "EXEC dbo.DeleteScalingSchedule @ScheduleID=%s", (created["ScheduleID"],))[0] == {
        "Result": "Deleted", "ScheduleID": created["ScheduleID"], "Name": "Business hours"}
    assert exec_sql(conn, "EXEC dbo.DeleteScalingSchedule @ScheduleID=%s", (created["ScheduleID"],))[0]["Result"] == "NotFound"


def test_the_policy_time_zone_accepts_only_known_zones(conn):
    assert set_zone(conn, "Mars Standard Time")["Result"] == "InvalidTimeZone"
    assert set_zone(conn, "W. Europe Standard Time") == {
        "Result": "Updated", "TimeZone": "W. Europe Standard Time", "PreviousTimeZone": "UTC"}
    assert set_zone(conn, "W. Europe Standard Time")["Result"] == "Unchanged"

    policy = exec_sql(conn, "EXEC dbo.GetScalingPolicy")[0]
    assert policy["TimeZone"] == "W. Europe Standard Time" and policy["UpdatedBy"] == "admin@contoso.com"
    assert policy["NowUtc"].endswith("Z") and "T" in policy["LocalTime"]
    assert policy["ActiveSource"] == "Rule" and policy["ActiveMinVMs"] == 2

    zones = {r["Name"]: r for r in exec_sql(conn, "EXEC dbo.GetTimeZones")}
    assert {"UTC", "Eastern Standard Time", "W. Europe Standard Time"} <= set(zones)
    assert zones["UTC"]["CurrentUtcOffset"] == "+00:00"


# -------------------------------------------------------------- the scaling run


def test_a_dry_run_changes_nothing_and_decides_what_the_run_does(conn):
    reset_rule(conn, MinVMs=3, MaxVMs=5)
    add_vm(conn, "dry-on", changed_minutes=30)
    add_vm(conn, "dry-off-1", power="Off", net="Unreachable")
    add_vm(conn, "dry-off-2", power="Off", net="Unreachable")
    add_vm(conn, "dry-off-3", power="Off", net="Unreachable")
    before = rows(conn, "SELECT VMID, PowerState, NetworkStatus FROM dbo.VirtualMachines ORDER BY VMID")

    preview = dry_run(conn)
    assert preview["Action"] == "PowerOn" and preview["RequestCount"] == 2 and preview["CandidateCount"] == 2
    assert preview["Reason"] == "Serviceable hosts are below the minimum."
    assert preview["PhaseSource"] == "Rule" and preview["MinVMs"] == 3 and preview["Serviceable"] == 1
    assert preview["AtUtc"].endswith("Z")
    assert rows(conn, "SELECT VMID, PowerState, NetworkStatus FROM dbo.VirtualMachines ORDER BY VMID") == before
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")[0]["c"] == 0

    started = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert sorted(r["VMName"] for r in started) == sorted(h["Hostname"] for h in json.loads(preview["CandidatesJson"]))
    stamped = rows(conn, "SELECT Hostname, StartRequestedAt FROM dbo.VirtualMachines WHERE PowerState='On' AND Hostname <> 'dry-on'")
    assert len(stamped) == 2 and all(r["StartRequestedAt"] is not None for r in stamped)

    log = one(conn, "SELECT TOP 1 * FROM dbo.VmScalingActivityLog ORDER BY ActivityID DESC")
    assert log["PhaseName"] == "Default rule" and log["MinVMs"] == 3 and log["MaxVMs"] == 5
    assert log["ServiceableVMs"] == 1 and log["DrainingVMs"] == 0 and log["ScheduleID"] is None
    assert "Phase=Default rule." in log["Notes"]


def test_a_dry_run_can_try_proposed_values_and_another_time(conn):
    reset_rule(conn, MinVMs=1, MaxVMs=5)
    save(conn, MinVMs=4, MaxVMs=8)
    add_vm(conn, "try-on", changed_minutes=30)
    for index in range(4):
        add_vm(conn, f"try-off-{index}", power="Off", net="Unreachable")

    at_night = dry_run(conn, at_utc="2026-09-21T23:00:00")
    assert at_night["PhaseSource"] == "Rule" and at_night["Action"] == "None"
    at_nine = dry_run(conn, at_utc="2026-09-21T09:00:00")
    assert at_nine["PhaseSource"] == "Schedule" and at_nine["PhaseName"] == "Business hours"
    assert at_nine["Action"] == "PowerOn" and at_nine["RequestCount"] == 3

    proposed = dry_run(conn, at_utc="2026-09-21T23:00:00", override={
        "MinVMs": 2, "MaxVMs": 6, "ScaleUpRatio": 50, "ScaleUpIncrement": 1, "ScaleDownRatio": 10,
        "ScaleDownIncrement": 1, "StopMode": "Deallocate", "PhaseName": "Night draft"})
    assert proposed["PhaseSource"] == "Proposed" and proposed["PhaseName"] == "Night draft"
    assert proposed["MinVMs"] == 2 and proposed["StopMode"] == "Deallocate" and proposed["RequestCount"] == 1

    # A normal run ignores both, and applies what is in force now.
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic @DryRun=0, @AtUtc=%s, @OverrideJson=%s",
                    ("2026-09-21T09:00:00", json.dumps({"MinVMs": 5}))) is not None


def test_a_dry_run_without_any_rule(conn):
    exec_sql(conn, "DELETE FROM dbo.VmScalingRules")
    preview = dry_run(conn)
    assert preview["Action"] == "None" and preview["Reason"] == "No scaling rule is configured."
    assert rows(conn, "SELECT COUNT(*) AS c FROM dbo.VmScalingActivityLog")[0]["c"] == 0


def test_the_minimum_wins_over_the_maximum(conn):
    reset_rule(conn, MinVMs=2, MaxVMs=3)
    add_vm(conn, "cap-ready-1", changed_minutes=30)
    add_vm(conn, "cap-ready-2", changed_minutes=30)
    for index in range(3):
        add_vm(conn, f"cap-maint-{index}", status="Maintenance", changed_minutes=30)

    preview = dry_run(conn)
    assert preview["PoweredOn"] == 5 and preview["Serviceable"] == 2
    assert preview["Action"] == "None" and "leave fewer serviceable hosts than the minimum" in preview["Reason"]
    assert exec_sql(conn, "EXEC dbo.TriggerScalingLogic") == []

    # With room above the minimum, only the excess over it is stopped.
    add_vm(conn, "cap-ready-3", changed_minutes=30)
    stopped = exec_sql(conn, "EXEC dbo.TriggerScalingLogic")
    assert [r["ActionType"] for r in stopped] == ["PowerOff"]
    assert one(conn, "SELECT StartRequestedAt FROM dbo.VirtualMachines WHERE Hostname=%s", (stopped[0]["VMName"],))["StartRequestedAt"] is None


def test_a_manual_stop_uses_the_active_phase_stop_mode_and_starts_are_stamped(conn):
    reset_rule(conn, StopMode="PowerOff")
    # Two windows that between them cover every minute of the week.
    save(conn, name="Mornings", days=127, start="00:00", end="12:00", StopMode="Deallocate")
    save(conn, name="Afternoons", days=127, start="12:00", end="00:00", StopMode="Deallocate")
    vmid = add_vm(conn, "manual-1", power="Off", net="Unreachable")

    started = exec_sql(conn, "EXEC dbo.BeginVmPowerAction @VMID=%s, @Action=%s", (vmid, "Start"))[0]
    assert started["Result"] == "Requested" and started["StopMode"] == "Deallocate"
    assert one(conn, "SELECT StartRequestedAt FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["StartRequestedAt"] is not None

    exec_sql(conn, "UPDATE dbo.VirtualMachines SET NetworkStatus='Reachable', StartRequestedAt=NULL WHERE VMID=%s", (vmid,))
    exec_sql(conn, "EXEC dbo.BeginVmPowerAction @VMID=%s, @Action=%s", (vmid, "Restart"))
    assert one(conn, "SELECT StartRequestedAt FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["StartRequestedAt"] is not None

    exec_sql(conn, "EXEC dbo.BeginVmPowerAction @VMID=%s, @Action=%s", (vmid, "Stop"))
    assert one(conn, "SELECT StartRequestedAt FROM dbo.VirtualMachines WHERE VMID=%s", (vmid,))["StartRequestedAt"] is None


def test_scaling_policy_objects_exist(conn):
    procedures = {r["name"] for r in rows(conn, "SELECT name FROM sys.procedures")}
    assert {"GetScalingPolicy", "GetScalingSchedules", "SaveScalingSchedule", "DeleteScalingSchedule",
            "SetScalingPolicyTimeZone", "GetTimeZones"} <= procedures
    functions = {r["name"] for r in rows(conn, "SELECT name FROM sys.objects WHERE type IN ('IF', 'TF', 'FN')")}
    assert {"fnScheduleWeekIntervals", "fnActiveScalingPhase"} <= functions
