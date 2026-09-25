"""2.5 scaling policy and schedules: validation mirroring SQL, overlap messages, the next
change, the time zone, and the dry-run preview."""

import json

import pytest


ADMIN_USER = {"roles": ["FullAccess"], "scp": "access_as_user", "oid": "oid-alice", "preferred_username": "alice@contoso.com"}

RULE_VALUES = {"minvms": 3, "maxvms": 8, "scaleupratio": 60, "scaleupincrement": 2, "scaledownratio": 20, "scaledownincrement": 1}


def schedule_row(schedule_id, name, days=31, start="08:00", end="18:00", enabled=True, **values):
    row = {
        "ScheduleID": schedule_id, "Name": name, "Enabled": enabled, "DaysOfWeek": days, "StartTime": start,
        "EndTime": end, "MinVMs": 3, "MaxVMs": 8, "ScaleUpRatio": 60, "ScaleUpIncrement": 2, "ScaleDownRatio": 20,
        "ScaleDownIncrement": 1, "StopMode": None, "UpdatedBy": "alice@contoso.com", "UpdatedAtUtc": "2026-09-20T10:00:00Z",
    }
    row.update(values)
    return row


def body(**overrides):
    payload = {"name": "Business hours", "days": ["mon", "tue", "wed", "thu", "fri"], "start": "08:00", "end": "18:00", **RULE_VALUES}
    payload.update(overrides)
    return payload


# ------------------------------------------------------------------- pure logic


def test_week_intervals_mirror_the_sql_function(app_module):
    intervals = app_module.schedule_week_intervals
    assert intervals(1 | 4, 540, 1020) == [(540, 1020), (2 * 1440 + 540, 2 * 1440 + 1020)]
    assert intervals(16, 1320, 120) == [(4 * 1440 + 1320, 5 * 1440 + 120)]
    assert intervals(64, 1380, 60) == [(6 * 1440 + 1380, 10080), (0, 60)]
    assert intervals(2, 1080, 0) == [(1440 + 1080, 2 * 1440)]
    assert app_module.schedules_overlap([(0, 60)], [(59, 120)]) and not app_module.schedules_overlap([(0, 60)], [(60, 120)])


def test_days_and_times_are_parsed_strictly(app_module):
    assert app_module.schedule_days_mask(["Mon", "friday", "SUN"]) == 1 | 16 | 64
    assert app_module.schedule_days_mask(31) == 31
    assert app_module.schedule_day_codes(96) == ["sat", "sun"]
    for bad in ([], ["someday"], 0, 128, True, "mon"):
        with pytest.raises(app_module.RuleValidationError):
            app_module.schedule_days_mask(bad)
    assert app_module.schedule_minutes("07:30", "start") == 450
    for bad in ("7:30", "24:00", "12:60", None, "noon"):
        with pytest.raises(app_module.RuleValidationError):
            app_module.schedule_minutes(bad, "start")


def test_the_next_change_follows_the_windows(app_module):
    schedules = [app_module.schedule_item(schedule_row(1, "Business hours")),
                 app_module.schedule_item(schedule_row(2, "Evening", start="18:00", end="22:00")),
                 app_module.schedule_item(schedule_row(3, "Off", enabled=False, days=127, start="00:00", end="23:00"))]

    # Thursday 2026-09-24 10:15: business hours end at 18:00, when the evening window starts.
    change = app_module.next_phase_change(schedules, "2026-09-24T10:15:00")
    assert change == {"InMinutes": 465, "AtLocal": "Thursday 18:00", "PhaseName": "Evening", "ScheduleID": 2}
    # Thursday 22:30: nothing applies until Friday 08:00.
    change = app_module.next_phase_change(schedules, "2026-09-24T22:30:00")
    assert change["AtLocal"] == "Friday 08:00" and change["PhaseName"] == "Business hours"
    # Friday 21:00: at 22:00 the default rule takes over.
    assert app_module.next_phase_change(schedules, "2026-09-25T21:00:00")["PhaseName"] == "Default rule"
    assert app_module.next_phase_change([schedules[2]], "2026-09-25T21:00:00") is None


# -------------------------------------------------------------------- reading


def test_the_policy_combines_the_zone_rule_windows_and_next_change(client, fake_db):
    fake_db.fetchone_rows["GetScalingPolicy"] = {
        "TimeZone": "Eastern Standard Time", "UpdatedBy": "alice@contoso.com", "UpdatedAtUtc": "2026-09-01T10:00:00Z",
        "NowUtc": "2026-09-24T14:15:00Z", "LocalTime": "2026-09-24T10:15:00", "ActiveSource": "Schedule",
        "ActiveScheduleID": 1, "ActivePhaseName": "Business hours", "ActiveMinVMs": 3, "ActiveMaxVMs": 8,
        "ActiveScaleUpRatio": 60, "ActiveScaleUpIncrement": 2, "ActiveScaleDownRatio": 20, "ActiveScaleDownIncrement": 1,
        "ActiveStopMode": "PowerOff", "DefaultRuleID": 1,
    }
    fake_db.fetchall_rows["GetScalingRules"] = [{"RuleID": 1, "MinVMs": 1, "MaxVMs": 5, "IsActive": True}]
    fake_db.fetchall_rows["GetScalingSchedules"] = [schedule_row(1, "Business hours")]
    fake_db.fetchone_rows["GetScalingActivityLog"] = {"ActivityID": 9, "ActionTaken": "No Action"}

    policy = client.get("/api/scaling/policy").get_json()

    assert policy["TimeZone"] == "Eastern Standard Time" and policy["DefaultRule"]["RuleID"] == 1
    assert policy["ActivePhase"]["Name"] == "Business hours" and policy["ActivePhase"]["ScaleUpRatio"] == 60.0
    assert policy["Schedules"][0]["Days"] == ["mon", "tue", "wed", "thu", "fri"]
    assert policy["NextChange"]["AtLocal"] == "Thursday 18:00" and policy["NextChange"]["PhaseName"] == "Default rule"
    assert policy["LastRun"]["ActivityID"] == 9


def test_time_zones_are_cached(client, fake_db):
    fake_db.fetchall_rows["GetTimeZones"] = [{"Name": "UTC", "CurrentUtcOffset": "+00:00", "IsCurrentlyDst": False}]
    assert client.get("/api/scaling/timezones").get_json()[0]["Name"] == "UTC"
    client.get("/api/scaling/timezones")
    assert [call["proc"] for call in fake_db.calls].count("GetTimeZones") == 1


# -------------------------------------------------------------------- writing


def test_a_window_is_saved_after_validation(auth_client, fake_db, audit_entries):
    fake_db.fetchall_rows["GetScalingSchedules"] = []
    fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": "Created", "ScheduleID": 7}
    client = auth_client(ADMIN_USER)

    response = client.post("/api/scaling/schedules/create", json=body(stopmode="deallocate"), headers=auth_client.headers)

    assert response.status_code == 201 and response.get_json()["ScheduleID"] == 7
    params = fake_db.latest_call("SaveScalingSchedule")["params"]
    assert params[:6] == (None, "Business hours", True, 31, "08:00", "18:00")
    assert params[6:13] == (3, 8, 60.0, 2, 20.0, 1, "Deallocate") and params[13] == "alice@contoso.com"
    [entry] = audit_entries
    assert entry["action"] == "scaling.schedule_create" and entry["targetId"] == "7"
    assert json.loads(entry["detailJson"])["schedule"]["days"] == ["mon", "tue", "wed", "thu", "fri"]


@pytest.mark.parametrize("overrides,message", [
    ({"name": " "}, "name is required."),
    ({"name": "x" * 65}, "name must be at most 64 characters."),
    ({"days": []}, "Choose at least one day."),
    ({"start": "8:00"}, "start must be a time as HH:MM, from 00:00 to 23:59."),
    ({"end": "08:00"}, "start and end must differ."),
    ({"minvms": 0}, "minvms must be at least 1."),
    ({"maxvms": 3}, "maxvms must be greater than minvms."),
    ({"scaleupratio": 10}, "scaleupratio must be greater than scaledownratio."),
    ({"stopmode": "Hibernate"}, "stopmode must be PowerOff or Deallocate."),
    ({"enabled": "yes"}, "enabled must be true or false."),
])
def test_invalid_windows_are_refused_with_the_field_named(client, fake_db, overrides, message):
    response = client.post("/api/scaling/schedules/create", json=body(**overrides))
    assert response.status_code == 400
    assert response.get_json()["error"].startswith(message)
    assert "SaveScalingSchedule" not in [call["proc"] for call in fake_db.calls]


def test_an_overlap_names_the_window_it_clashes_with(client, fake_db):
    fake_db.fetchall_rows["GetScalingSchedules"] = [
        schedule_row(1, "Business hours"),
        schedule_row(2, "Weekend", days=96, start="09:00", end="17:00", enabled=False),
    ]

    clash = client.post("/api/scaling/schedules/create", json=body(name="Lunch", days=["wed"], start="11:00", end="14:00"))
    assert clash.status_code == 409
    assert "overlaps 'Business hours' (Mon, Tue, Wed, Thu, Fri 08:00\u201318:00)" in clash.get_json()["error"]

    # A disabled window, the window itself, and a disabled new window never clash.
    fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": "Created", "ScheduleID": 3}
    assert client.post("/api/scaling/schedules/create", json=body(name="Sat", days=["sat"], start="10:00", end="12:00")).status_code == 201
    fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": "Updated", "ScheduleID": 1}
    assert client.post("/api/scaling/schedules/1/update", json=body(start="07:00")).status_code == 200
    assert client.post("/api/scaling/schedules/create", json=body(name="Draft", enabled=False)).status_code in (200, 201)


def test_saving_reports_what_sql_decided(client, fake_db):
    fake_db.fetchall_rows["GetScalingSchedules"] = [schedule_row(1, "Business hours")]
    assert client.post("/api/scaling/schedules/9/update", json=body()).status_code == 404

    fake_db.fetchall_rows["GetScalingSchedules"] = []
    for result, status in (("Overlap", 409), ("Busy", 503), ("Invalid", 400), ("Strange", 500)):
        fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": result, "Message": "minvms must be at least 1.", "OverlapsName": "Other"}
        assert client.post("/api/scaling/schedules/create", json=body()).status_code == status


def test_an_update_audits_only_what_changed(auth_client, fake_db, audit_entries):
    fake_db.fetchall_rows["GetScalingSchedules"] = [schedule_row(1, "Business hours")]
    fake_db.fetchone_rows["SaveScalingSchedule"] = {"Result": "Updated", "ScheduleID": 1}
    client = auth_client(ADMIN_USER)

    client.post("/api/scaling/schedules/1/update", json=body(end="19:00", minvms=4), headers=auth_client.headers)

    changes = json.loads(audit_entries[0]["detailJson"])["changes"]
    assert changes == {"end": {"from": "18:00", "to": "19:00"}, "minvms": {"from": 3, "to": 4}}


def test_deleting_a_window(client, fake_db):
    fake_db.fetchone_rows["DeleteScalingSchedule"] = {"Result": "Deleted", "ScheduleID": 1, "Name": "Business hours"}
    assert client.post("/api/scaling/schedules/1/delete").get_json()["message"] == "Deleted 'Business hours'."
    fake_db.fetchone_rows["DeleteScalingSchedule"] = {"Result": "NotFound"}
    assert client.post("/api/scaling/schedules/1/delete").status_code == 404


def test_the_time_zone_must_be_one_sql_knows(client, fake_db):
    assert client.post("/api/scaling/policy/update", json={}).status_code == 400
    fake_db.fetchone_rows["SetScalingPolicyTimeZone"] = {"Result": "InvalidTimeZone", "TimeZone": "UTC"}
    assert client.post("/api/scaling/policy/update", json={"timezone": "Mars"}).status_code == 400
    fake_db.fetchone_rows["SetScalingPolicyTimeZone"] = {"Result": "Updated", "TimeZone": "UTC", "PreviousTimeZone": "Tokyo Standard Time"}
    assert client.post("/api/scaling/policy/update", json={"timezone": "UTC"}).get_json()["message"] == "Schedules are now read in UTC."


@pytest.mark.parametrize("path", ["/api/scaling/schedules/create", "/api/scaling/schedules/1/update",
                                  "/api/scaling/schedules/1/delete", "/api/scaling/policy/update"])
def test_only_administrators_change_the_policy(auth_client, fake_db, path):
    client = auth_client({"roles": ["Operator"], "scp": "access_as_user"})
    assert client.post(path, json=body(), headers=auth_client.headers).status_code == 403


# -------------------------------------------------------------------- preview


DECISION = {
    "Action": "PowerOn", "RequestCount": 2, "CandidateCount": 2, "CandidatesJson": '[{"Hostname":"lnx-03"},{"Hostname":"lnx-04"}]',
    "Reason": "Serviceable hosts are below the minimum.", "PhaseSource": "Schedule", "ScheduleID": 1,
    "PhaseName": "Business hours", "MinVMs": 3, "MaxVMs": 8, "ScaleUpRatio": 60, "ScaleUpIncrement": 2,
    "ScaleDownRatio": 20, "ScaleDownIncrement": 1, "StopMode": "PowerOff", "PoweredOn": 1, "Serviceable": 1,
    "InUse": 0, "Draining": 0, "Utilization": 0, "TimeZone": "UTC", "LocalTime": "2026-09-24T10:15:00",
    "AtUtc": "2026-09-24T10:15:00Z",
}


def test_the_preview_is_a_dry_run(client, fake_db):
    fake_db.fetchone_rows["TriggerScalingLogic"] = dict(DECISION)

    preview = client.get("/api/scaling/preview").get_json()

    assert preview["Summary"] == "Start 2 hosts (lnx-03, lnx-04)." and preview["Candidates"] == ["lnx-03", "lnx-04"]
    assert preview["Phase"]["Name"] == "Business hours" and preview["Counts"]["Serviceable"] == 1
    assert fake_db.latest_call("TriggerScalingLogic")["params"] == (None, None)
    # A dry run is never committed.
    assert fake_db.commits == 0


def test_the_preview_can_try_proposed_values_at_another_time(client, fake_db):
    fake_db.fetchone_rows["TriggerScalingLogic"] = dict(DECISION, Action="PowerOff", StopMode="Deallocate", CandidatesJson='[{"Hostname":"lnx-09"}]')

    preview = client.post("/api/scaling/preview", json={
        "at": "2026-09-21T23:00:00Z", "rule": dict(RULE_VALUES, stopmode="Deallocate", name="Night draft"),
    }).get_json()

    assert preview["Summary"] == "Deallocate 1 host (lnx-09)."
    at, override = fake_db.latest_call("TriggerScalingLogic")["params"]
    assert at.isoformat() == "2026-09-21T23:00:00"
    assert json.loads(override) == {"MinVMs": 3, "MaxVMs": 8, "ScaleUpRatio": 60.0, "ScaleUpIncrement": 2,
                                    "ScaleDownRatio": 20.0, "ScaleDownIncrement": 1, "StopMode": "Deallocate",
                                    "PhaseName": "Night draft"}


def test_the_preview_validates_its_input(client, fake_db):
    assert client.get("/api/scaling/preview?at=tomorrow").status_code == 400
    assert client.post("/api/scaling/preview", json={"rule": {"minvms": 1}}).status_code == 400
    assert client.post("/api/scaling/preview", json={"rule": dict(RULE_VALUES, maxvms=2)}).status_code == 400
    assert client.post("/api/scaling/preview", json={"rule": "cheap"}).status_code == 400
    assert "TriggerScalingLogic" not in [call["proc"] for call in fake_db.calls]


def test_the_preview_explains_a_database_that_predates_it(client, fake_db):
    fake_db.raise_on_execute["TriggerScalingLogic"] = "Procedure or function TriggerScalingLogic has too many arguments specified."
    response = client.get("/api/scaling/preview")
    assert response.status_code == 409 and "updated database" in response.get_json()["error"]


def test_readers_can_preview(auth_client, fake_db):
    fake_db.fetchone_rows["TriggerScalingLogic"] = dict(DECISION)
    client = auth_client({"roles": ["Reader"], "scp": "access_as_user"})
    assert client.post("/api/scaling/preview", json={}, headers=auth_client.headers).status_code == 200
