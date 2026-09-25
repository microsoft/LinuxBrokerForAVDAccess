"""BFF endpoints and dashboard figures for 2.6 trends and unmet demand."""

import pytest

from conftest import API
from function_api import summary_from_api, utilization_percent


UTILIZATION = {"Hours": 24, "BucketMinutes": 15, "Series": [{"BucketStartUtc": "2026-03-04T10:00:00Z", "PoweredOn": 3.0}],
               "Checkouts": {"Total": 4, "NoneAvailable": 1}}
ATTENTION = {"Items": [{"Kind": "no-ready-hosts", "Severity": "critical"}], "Summary": {"Total": 1, "Critical": 1},
             "Incomplete": False}


def test_capacity_trends_are_read_through_for_a_day_or_a_week(signed_in_client, broker_api):
    broker_api.get_replies["/metrics/utilization"] = (200, UTILIZATION)

    body = signed_in_client.get(f"{API}/metrics/utilization").get_json()
    assert body == dict(UTILIZATION, Available=True)
    assert broker_api.gets[-1]["params"] == {"hours": "24"}

    signed_in_client.get(f"{API}/metrics/utilization?hours=168")
    assert broker_api.gets[-1]["params"] == {"hours": "168"}


@pytest.mark.parametrize("hours", ["12", "week", "-1"])
def test_other_windows_never_reach_the_broker(signed_in_client, broker_api, hours):
    response = signed_in_client.get(f"{API}/metrics/utilization?hours={hours}")
    assert response.status_code == 400 and "24 or 168" in response.get_json()["error"]
    assert not any("/metrics/" in call["url"] for call in broker_api.gets)


def test_an_api_without_trends_hides_the_chart_rather_than_failing(signed_in_client, broker_api):
    broker_api.get_replies["/metrics/utilization"] = (404, {"error": "Capacity trends are not available until the database is upgraded."})
    broker_api.get_replies["/metrics/attention"] = (404, {"error": "That endpoint does not exist."})

    assert signed_in_client.get(f"{API}/metrics/utilization?hours=168").get_json() == {"Available": False, "Hours": 168}
    attention = signed_in_client.get(f"{API}/metrics/attention").get_json()
    assert attention["Available"] is False and attention["Items"] == []


def test_attention_items_are_read_through(signed_in_client, broker_api):
    broker_api.get_replies["/metrics/attention"] = (200, ATTENTION)
    assert signed_in_client.get(f"{API}/metrics/attention").get_json() == dict(ATTENTION, Available=True)


def test_other_broker_failures_are_reported(signed_in_client, broker_api):
    broker_api.get_replies["/metrics/attention"] = (500, {"error": "db-prod-01 is down"})
    response = signed_in_client.get(f"{API}/metrics/attention")
    assert response.status_code == 502 and "db-prod-01" not in response.get_data(as_text=True)

    broker_api.raise_get_paths.add("/metrics/utilization")
    assert signed_in_client.get(f"{API}/metrics/utilization").status_code == 502


def test_the_metrics_need_a_signed_in_operator(client):
    assert client.get(f"{API}/metrics/utilization").status_code == 401
    assert client.get(f"{API}/metrics/attention").status_code == 401


# ------------------------------------------------------------------ dashboard utilization


def test_utilization_is_in_use_out_of_serviceable_when_the_broker_reports_both(signed_in_client, broker_api):
    broker_api.vm_summary = dict(broker_api.vm_summary, Serviceable=3, InUse=2)

    stats = signed_in_client.get(f"{API}/dashboard").get_json()["stats"]

    assert (stats["utilization"], stats["utilization_basis"], stats["serviceable"], stats["in_use"]) == (67, "serviceable", 3, 2)


def test_utilization_falls_back_to_the_checked_out_share_from_an_older_api(signed_in_client, broker_api):
    stats = signed_in_client.get(f"{API}/dashboard").get_json()["stats"]
    assert (stats["utilization"], stats["utilization_basis"], stats["serviceable"]) == (25, "total", None)

    broker_api.summary_status = 500
    stats = signed_in_client.get(f"{API}/dashboard").get_json()["stats"]
    assert stats["utilization_basis"] == "total"


@pytest.mark.parametrize("total,checked_out,serviceable,in_use,expected", [
    (10, 3, 4, 3, (75, "serviceable")),
    (10, 3, 0, 0, (0, "serviceable")),
    (10, 3, 0, 2, (100, "serviceable")),
    (10, 3, 2, 3, (100, "serviceable")),
    (10, 3, None, 3, (30, "total")),
    (0, 0, None, None, (0, "total")),
])
def test_utilization_percent(total, checked_out, serviceable, in_use, expected):
    assert utilization_percent(total, checked_out, serviceable, in_use) == expected


def test_a_summary_without_the_scalers_counts_keeps_them_unknown():
    stats = summary_from_api({"TotalVMs": 2, "CheckedOut": 1, "Serviceable": "junk"})
    assert stats["serviceable"] == 0 and stats["in_use"] is None and stats["utilization_basis"] == "total"
