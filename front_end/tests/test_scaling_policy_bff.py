"""BFF endpoints for 2.5 scaling policy and schedules."""

import pytest

from conftest import API, post


WINDOW = {"name": "Business hours", "days": ["mon", "fri"], "start": "08:00", "end": "18:00", "enabled": False,
          "minvms": 3, "maxvms": 8, "scaleupratio": 60, "scaleupincrement": 2, "scaledownratio": 20,
          "scaledownincrement": 1, "stopmode": "Deallocate"}


def test_the_policy_and_time_zones_are_read_through(signed_in_client, broker_api):
    broker_api.get_replies["/scaling/policy"] = (200, {"TimeZone": "UTC", "Schedules": []})
    broker_api.get_replies["/scaling/timezones"] = (200, [{"Name": "UTC"}])

    assert signed_in_client.get(f"{API}/scaling/policy").get_json()["TimeZone"] == "UTC"
    assert signed_in_client.get(f"{API}/scaling/timezones").get_json() == [{"Name": "UTC"}]


def test_a_window_is_forwarded_with_only_its_fields(signed_in_client, broker_api):
    broker_api.post_replies["/scaling/schedules/create"] = (201, {"ScheduleID": 4})

    response = post(signed_in_client, f"{API}/scaling/schedules", dict(WINDOW, extra="ignored"))

    assert response.status_code == 201 and response.get_json()["ScheduleID"] == 4
    assert broker_api.posts[-1]["json"] == WINDOW

    post(signed_in_client, f"{API}/scaling/schedules/4/update", WINDOW)
    assert broker_api.posts[-1]["url"].endswith("/scaling/schedules/4/update")
    post(signed_in_client, f"{API}/scaling/schedules/4/delete")
    assert broker_api.posts[-1]["url"].endswith("/scaling/schedules/4/delete")


@pytest.mark.parametrize("missing", ["name", "days", "start", "minvms"])
def test_an_incomplete_window_never_reaches_the_broker(signed_in_client, broker_api, missing):
    payload = dict(WINDOW)
    payload.pop(missing)
    response = post(signed_in_client, f"{API}/scaling/schedules", payload)
    assert response.status_code == 400 and missing in response.get_json()["error"]
    assert broker_api.posts == []


def test_an_overlap_keeps_the_brokers_message(signed_in_client, broker_api):
    broker_api.post_replies["/scaling/schedules/create"] = (409, {"error": "This window overlaps 'Evening' (Mon 18:00\u201322:00)."})
    response = post(signed_in_client, f"{API}/scaling/schedules", WINDOW)
    assert response.status_code == 409 and "overlaps 'Evening'" in response.get_json()["error"]


def test_the_time_zone_is_set(signed_in_client, broker_api):
    assert post(signed_in_client, f"{API}/scaling/policy", {"timezone": " "}).status_code == 400
    broker_api.post_replies["/scaling/policy/update"] = (200, {"TimeZone": "UTC", "message": "Schedules are now read in UTC."})
    post(signed_in_client, f"{API}/scaling/policy", {"timezone": "UTC"})
    assert broker_api.posts[-1]["json"] == {"timezone": "UTC"}


def test_the_preview_forwards_a_time_and_proposed_values(signed_in_client, broker_api):
    broker_api.get_replies["/scaling/preview"] = (200, {"Action": "None", "Summary": "No change."})
    signed_in_client.get(f"{API}/scaling/preview?at=2026-09-21T09:00:00Z")
    assert broker_api.gets[-1]["params"] == {"at": "2026-09-21T09:00:00Z"}

    broker_api.post_replies["/scaling/preview"] = (200, {"Action": "PowerOn", "Summary": "Start 1 host."})
    response = post(signed_in_client, f"{API}/scaling/preview", {
        "at": "2026-09-21T09:00:00Z", "rule": {"minvms": 3, "maxvms": 8, "junk": True, "name": "Draft"},
    })
    assert response.get_json()["Summary"] == "Start 1 host."
    assert broker_api.posts[-1]["json"] == {"at": "2026-09-21T09:00:00Z", "rule": {"minvms": 3, "maxvms": 8, "name": "Draft"}}
