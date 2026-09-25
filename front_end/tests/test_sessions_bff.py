"""BFF endpoints for 2.3 sessions and users."""

import pytest

from conftest import API, post


def test_sessions_forward_the_filters(signed_in_client, broker_api):
    response = signed_in_client.get(f"{API}/sessions?q=alice&state=ACTIVE")

    assert response.status_code == 200
    assert response.get_json()["Sessions"][0]["Username"] == "alice"
    assert broker_api.gets[-1]["url"].endswith("/sessions")
    assert broker_api.gets[-1]["params"] == {"q": "alice", "state": "active"}

    signed_in_client.get(f"{API}/sessions")
    assert broker_api.gets[-1]["params"] is None


def test_sessions_reject_an_unknown_state(signed_in_client, broker_api):
    response = signed_in_client.get(f"{API}/sessions?state=asleep")
    assert response.status_code == 400
    assert broker_api.gets == []


def test_sessions_need_a_signed_in_user(client, broker_api):
    assert client.get(f"{API}/sessions").status_code == 401


def test_user_search_and_details(signed_in_client, broker_api):
    found = signed_in_client.get(f"{API}/users?q=al&limit=10").get_json()
    assert found["Users"][0]["Username"] == "alice"
    assert broker_api.gets[-1]["params"] == {"q": "al", "limit": "10"}

    details = signed_in_client.get(f"{API}/users/alice")
    assert details.status_code == 200 and details.get_json()["Uid"] == 2001
    assert broker_api.gets[-1]["url"].endswith("/users/alice")

    assert signed_in_client.get(f"{API}/users/not.valid").status_code == 400


def test_sign_out_forwards_only_a_real_return_request(signed_in_client, broker_api):
    broker_api.post_replies["/signout"] = (200, {"Result": "SignedOut", "message": "Signed alice out of linux-host-02."})

    response = post(signed_in_client, f"{API}/sessions/linux-host-02/alice/signout", {"returnHost": "yes"})

    assert response.status_code == 200
    assert broker_api.posts[-1]["url"].endswith("/sessions/linux-host-02/alice/signout")
    assert broker_api.posts[-1]["json"] == {}
    assert broker_api.posts[-1]["timeout"] == 120

    post(signed_in_client, f"{API}/sessions/linux-host-02/alice/signout", {"returnHost": True})
    assert broker_api.posts[-1]["json"] == {"returnHost": True}


@pytest.mark.parametrize("path", [
    "/sessions/bad host/alice/signout",
    "/sessions/linux-host-02/al.ice/signout",
])
def test_session_actions_validate_the_path(signed_in_client, broker_api, path):
    assert post(signed_in_client, f"{API}{path}").status_code in (400, 404)
    assert broker_api.posts == []


def test_a_message_is_validated_and_forwarded(signed_in_client, broker_api):
    for message in (None, "  ", "x" * 501, 12):
        response = post(signed_in_client, f"{API}/sessions/linux-host-02/alice/message", {"message": message})
        assert response.status_code == 400
    assert broker_api.posts == []

    broker_api.post_replies["/message"] = (200, {"Delivered": 1, "message": "Sent to alice on linux-host-02."})
    response = post(signed_in_client, f"{API}/sessions/linux-host-02/alice/message", {"message": "  Save your work  "})
    assert response.status_code == 200
    assert broker_api.posts[-1]["json"] == {"message": "Save your work"}
    assert broker_api.posts[-1]["timeout"] == 45


def test_an_outdated_agent_keeps_the_brokers_explanation(signed_in_client, broker_api):
    broker_api.post_replies["/signout"] = (409, {
        "error": "linux-host-02 runs a host agent older than 1.1.0, which cannot sign users out.",
    })
    response = post(signed_in_client, f"{API}/sessions/linux-host-02/alice/signout")
    assert response.status_code == 409 and "older than 1.1.0" in response.get_json()["error"]


def test_profile_reset_forwards_the_confirmation(signed_in_client, broker_api):
    broker_api.post_replies["/reset-profile"] = (200, {"message": "alice gets a fresh profile at their next sign-in."})

    post(signed_in_client, f"{API}/users/alice/reset-profile", {"confirm": " alice "})
    assert broker_api.posts[-1]["url"].endswith("/users/alice/reset-profile")
    assert broker_api.posts[-1]["json"] == {"confirm": "alice"}

    post(signed_in_client, f"{API}/users/alice/reset-profile", {})
    assert broker_api.posts[-1]["json"] == {}

    broker_api.post_replies["/reset-profile/cancel"] = (200, {"Result": "Cancelled"})
    response = post(signed_in_client, f"{API}/users/alice/reset-profile/cancel")
    assert response.get_json()["Result"] == "Cancelled"
    assert broker_api.posts[-1]["url"].endswith("/users/alice/reset-profile/cancel")


def test_session_actions_require_the_csrf_token(signed_in_client, broker_api):
    response = signed_in_client.post(f"{API}/sessions/linux-host-02/alice/signout", json={})
    assert response.status_code == 400
    assert broker_api.posts == []


def test_a_broadcast_is_validated_and_forwarded(signed_in_client, broker_api):
    broker_api.post_replies["/sessions/broadcast"] = (200, {"TargetCount": 2, "Delivered": 3, "message": "Shown in 3 session(s)."})

    response = post(signed_in_client, f"{API}/sessions/broadcast", {"message": " Restarting at 18:00 "})
    assert response.status_code == 200 and response.get_json()["Delivered"] == 3
    assert broker_api.posts[-1]["json"] == {"message": "Restarting at 18:00"}
    assert broker_api.posts[-1]["timeout"] == 110

    post(signed_in_client, f"{API}/sessions/broadcast", {"message": "Hi", "hostnames": ["linux-host-01"]})
    assert broker_api.posts[-1]["json"] == {"message": "Hi", "hostnames": ["linux-host-01"]}


@pytest.mark.parametrize("payload", [
    {"message": ""},
    {"message": "Hi", "hostnames": []},
    {"message": "Hi", "hostnames": "linux-host-01"},
    {"message": "Hi", "hostnames": ["bad host"]},
])
def test_a_bad_broadcast_never_reaches_the_broker(signed_in_client, broker_api, payload):
    assert post(signed_in_client, f"{API}/sessions/broadcast", payload).status_code == 400
    assert broker_api.posts == []
