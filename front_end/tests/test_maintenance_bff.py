"""BFF endpoints for 2.9 rolling maintenance."""

import pytest

from conftest import API, post


RUN = {"hostnames": ["linux-host-01", "linux-host-02"], "patchMode": "Security", "batchSize": 1, "minReady": 1,
       "signOutDeadlineMinutes": 60, "warningMinutes": 15, "warningMessage": "Patching tonight.",
       "includePoweredOff": True, "maxFailures": 2, "canaryCount": 1, "name": "Tuesday"}


def test_runs_and_details_are_read_through(signed_in_client, broker_api):
    broker_api.get_replies["/maintenance/runs"] = (200, {"Runs": [{"RunID": 7}], "Active": {"RunID": 7}})
    broker_api.get_replies["/maintenance/runs/7"] = (200, {"Run": {"RunID": 7}, "Hosts": []})

    assert signed_in_client.get(f"{API}/maintenance/runs").get_json() == {"Runs": [{"RunID": 7}], "Active": {"RunID": 7}, "Available": True}
    assert signed_in_client.get(f"{API}/maintenance/runs/7").get_json()["Run"]["RunID"] == 7


def test_an_api_without_maintenance_says_so(signed_in_client, broker_api):
    broker_api.get_replies["/maintenance/runs"] = (404, {"error": "That endpoint does not exist."})
    assert signed_in_client.get(f"{API}/maintenance/runs").get_json() == {"Available": False, "Runs": [], "Active": None}


def test_a_new_run_is_forwarded_with_only_its_settings(signed_in_client, broker_api):
    broker_api.post_replies["/maintenance/runs/create"] = (201, {"RunID": 8, "HostCount": 2, "message": "Started."})

    response = post(signed_in_client, f"{API}/maintenance/runs", dict(RUN, extra="ignored"))

    assert response.status_code == 201 and response.get_json()["RunID"] == 8
    assert broker_api.posts[-1]["url"].endswith("/maintenance/runs/create")
    assert broker_api.posts[-1]["json"] == RUN


@pytest.mark.parametrize("change,message", [
    ({"hostnames": []}, "Choose between 1 and 500 hosts."),
    ({"hostnames": ["bad host"]}, "Choose between 1 and 500 hosts."),
    ({"patchMode": "kernel"}, "patchMode must be Security, All or RebootOnly."),
])
def test_an_unusable_run_never_reaches_the_broker(signed_in_client, broker_api, change, message):
    response = post(signed_in_client, f"{API}/maintenance/runs", dict(RUN, **change))
    assert response.status_code == 400 and response.get_json()["error"] == message
    assert not any("/maintenance/" in call["url"] for call in broker_api.posts)


def test_the_brokers_refusal_is_passed_on(signed_in_client, broker_api):
    broker_api.post_replies["/maintenance/runs/create"] = (409, {"error": "Maintenance run 4 is still active."})
    response = post(signed_in_client, f"{API}/maintenance/runs", RUN)
    assert response.status_code == 409 and response.get_json()["error"] == "Maintenance run 4 is still active."


@pytest.mark.parametrize("action", ["pause", "resume", "cancel"])
def test_a_run_can_be_paused_resumed_or_cancelled(signed_in_client, broker_api, action):
    broker_api.post_replies[f"/maintenance/runs/7/{action}"] = (200, {"Result": "Updated", "message": "Done."})
    response = post(signed_in_client, f"{API}/maintenance/runs/7/{action}", {"reason": "  Checking the canary  "})
    assert response.status_code == 200
    assert broker_api.posts[-1]["json"] == {"reason": "Checking the canary"}


def test_other_actions_are_refused(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/maintenance/runs/7/delete")
    assert response.status_code == 400 and not broker_api.posts


def test_changes_need_the_csrf_token(signed_in_client):
    assert signed_in_client.post(f"{API}/maintenance/runs", json=RUN).status_code == 400
    assert signed_in_client.post(f"{API}/maintenance/runs/7/pause", json={}).status_code == 400
