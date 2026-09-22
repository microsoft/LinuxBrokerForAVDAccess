"""Tests for the Linux host settings endpoints."""

from conftest import API, HOST_SETTINGS, VMS, csrf_token, post

SETTINGS_PATH = f"{API}/hosts/settings"
APPLY_PATH = f"{API}/hosts/settings/apply"

BASE_FORM = {
    "graceperiodseconds": "1200",
    "reconcileintervalseconds": "60",
    "watcherdebounceseconds": "10",
    "watchersettleseconds": "2",
    "idletimeoutseconds": "0",
    "idlewarningseconds": "120",
    "screenidledelayseconds": "0",
    "screenlockdelayseconds": "0",
}


def get_settings(client):
    response = client.get(SETTINGS_PATH)
    assert response.status_code == 200
    return response.get_json()


def save_settings(client, overrides=None):
    body = dict(BASE_FORM)
    body.update(overrides or {})
    return post(client, SETTINGS_PATH, body)


def update_payload(broker_api):
    return next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/update"))


def apply_payload(broker_api):
    return next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/apply"))


def test_requires_sign_in(client):
    response = client.get(SETTINGS_PATH)
    assert response.status_code == 401
    assert response.get_json()["error"]


def test_returns_the_current_values(signed_in_client):
    payload = get_settings(signed_in_client)

    assert payload["settings"]["SettingsVersion"] == HOST_SETTINGS["SettingsVersion"]
    assert payload["settings"]["GracePeriodSeconds"] == 1200
    assert payload["settings"]["ReconcileIntervalSeconds"] == 60
    assert payload["settings"]["IdleTimeoutSeconds"] == 0


def test_returns_the_hosts_for_the_drift_table(signed_in_client):
    payload = get_settings(signed_in_client)
    assert [host["Hostname"] for host in payload["hosts"]] == [vm["Hostname"] for vm in VMS]


def test_screen_lock_defaults_reflect_the_disabled_lock_screen(signed_in_client):
    # The shipped posture removes the lock screen, because a locked greeter inside an
    # xrdp session can strand the host lease.
    settings = get_settings(signed_in_client)["settings"]

    assert settings["DisableLockScreen"] is True
    assert settings["ScreenLockSettingsLocked"] is True
    assert settings["ScreenLockEnabled"] is False


def test_drift_data_distinguishes_host_states(signed_in_client, broker_api):
    broker_api.host_settings = dict(HOST_SETTINGS, SettingsVersion=4)
    VMS[0]["SettingsVersion"] = 4
    VMS[0]["SettingsAppliedDate"] = "2026-08-19 20:00:00"
    VMS[1]["SettingsVersion"] = 3
    VMS[1]["SettingsAppliedDate"] = "2026-08-19 18:00:00"
    VMS[2]["SettingsVersion"] = None
    VMS[2]["SettingsAppliedDate"] = None

    try:
        payload = get_settings(signed_in_client)
        hosts = {host["Hostname"]: host for host in payload["hosts"]}

        # Current, behind, and never reported: the three states the drift table renders.
        assert payload["settings"]["SettingsVersion"] == 4
        assert hosts["linux-host-01"]["SettingsVersion"] == 4
        assert hosts["linux-host-02"]["SettingsVersion"] == 3
        assert hosts["linux-host-03"]["SettingsVersion"] is None
    finally:
        for vm in VMS:
            vm.pop("SettingsVersion", None)
            vm.pop("SettingsAppliedDate", None)


def test_save_sends_integers_to_the_api(signed_in_client, broker_api):
    response = save_settings(signed_in_client,
                             {"graceperiodseconds": "900", "idletimeoutseconds": "1800"})
    assert response.status_code == 200

    payload = update_payload(broker_api)
    assert payload["GracePeriodSeconds"] == 900
    assert payload["IdleTimeoutSeconds"] == 1800
    assert payload["updatedBy"] == "op@contoso.com"


def test_save_returns_a_message_the_client_can_show(signed_in_client):
    payload = save_settings(signed_in_client).get_json()

    assert payload["tone"] == "success"
    assert "Apply Now" in payload["message"]
    assert payload["settings"]["SettingsVersion"] == HOST_SETTINGS["SettingsVersion"]


def test_omitted_booleans_are_sent_as_false(signed_in_client, broker_api):
    # A boolean the client leaves out must be sent explicitly rather than omitted,
    # which the API reads as "leave unchanged".
    save_settings(signed_in_client)

    payload = update_payload(broker_api)
    assert payload["ScreenLockEnabled"] is False
    assert payload["DisableLockScreen"] is False
    assert payload["ScreenLockSettingsLocked"] is False


def test_true_booleans_are_forwarded(signed_in_client, broker_api):
    save_settings(signed_in_client,
                  {"disablelockscreen": True, "screenlocksettingslocked": True})

    payload = update_payload(broker_api)
    assert payload["DisableLockScreen"] is True
    assert payload["ScreenLockSettingsLocked"] is True
    assert payload["ScreenLockEnabled"] is False


def test_blank_integers_are_left_unchanged_rather_than_zeroed(signed_in_client, broker_api):
    save_settings(signed_in_client, {"graceperiodseconds": ""})

    payload = update_payload(broker_api)
    assert "GracePeriodSeconds" not in payload


def test_non_numeric_value_never_reaches_the_api(signed_in_client, broker_api):
    response = save_settings(signed_in_client, {"graceperiodseconds": "not-a-number"})

    assert response.status_code == 400
    assert "GracePeriodSeconds must be a whole number" in response.get_json()["error"]
    assert not any(p["url"].endswith("/hosts/settings/update") for p in broker_api.posts)


def test_save_requires_a_csrf_token(signed_in_client):
    response = signed_in_client.post(SETTINGS_PATH, json={"graceperiodseconds": "900"})
    assert response.status_code == 400


def test_broker_failure_on_save_is_reported(signed_in_client, broker_api):
    broker_api.raise_post_paths.add("/hosts/settings/update")
    response = save_settings(signed_in_client)

    assert response.status_code == 502
    assert "Unable to save host settings" in response.get_json()["error"]


def test_broker_failure_on_load_is_reported(signed_in_client, broker_api):
    broker_api.raise_get_paths.add("/hosts/settings")
    response = signed_in_client.get(SETTINGS_PATH)

    assert response.status_code == 502
    assert "Unable to retrieve host settings" in response.get_json()["error"]


def test_drift_table_failure_does_not_hide_the_settings(signed_in_client, broker_api):
    # The settings form must still be usable when the VM list cannot be loaded.
    broker_api.raise_get_paths.add("/vms")
    payload = get_settings(signed_in_client)

    assert payload["settings"]["SettingsVersion"] == HOST_SETTINGS["SettingsVersion"]
    assert payload["hosts"] == []


def test_apply_to_all_hosts_sends_no_hostname_filter(signed_in_client, broker_api):
    response = post(signed_in_client, APPLY_PATH, {})
    assert response.status_code == 200
    assert apply_payload(broker_api) == {}


def test_apply_to_single_host_targets_that_host(signed_in_client, broker_api):
    post(signed_in_client, APPLY_PATH, {"hostname": "linux-host-02"})
    assert apply_payload(broker_api) == {"hostnames": ["linux-host-02"]}


def test_full_apply_reports_success(signed_in_client):
    payload = post(signed_in_client, APPLY_PATH, {}).get_json()

    assert payload["tone"] == "success"
    assert payload["succeededCount"] == 2
    assert payload["targetCount"] == 2
    assert payload["unreachable"] == []
    assert "2 of 2" in payload["message"]


def test_partial_apply_names_the_hosts_that_failed(signed_in_client, broker_api):
    broker_api.apply_result = {
        "SettingsVersion": 3, "TargetCount": 2, "SucceededCount": 1,
        "Results": [{"Hostname": "linux-host-01", "Applied": True, "Message": "Applied."},
                    {"Hostname": "linux-host-02", "Applied": False, "Message": "unreachable"}],
    }
    payload = post(signed_in_client, APPLY_PATH, {}).get_json()

    assert payload["tone"] == "warning"
    assert payload["unreachable"] == ["linux-host-02"]
    assert "linux-host-02" in payload["message"]
    assert "converge" in payload["message"]


def test_apply_with_no_reachable_hosts_reassures_rather_than_alarms(signed_in_client, broker_api):
    broker_api.apply_result = {"SettingsVersion": 3, "TargetCount": 0,
                               "SucceededCount": 0, "Results": []}
    payload = post(signed_in_client, APPLY_PATH, {}).get_json()

    assert payload["tone"] == "info"
    assert "converge on their own" in payload["message"]


def test_apply_requires_a_csrf_token(signed_in_client):
    response = signed_in_client.post(APPLY_PATH, json={})
    assert response.status_code == 400


def test_apply_reports_a_broker_failure(signed_in_client, broker_api):
    broker_api.raise_post_paths.add("/hosts/settings/apply")
    response = post(signed_in_client, APPLY_PATH, {})

    assert response.status_code == 502
    assert "Unable to push host settings" in response.get_json()["error"]


def test_csrf_token_is_available_from_the_session_endpoint(signed_in_client):
    """The client has no form to read a hidden field from, so the token has to
    come from the bootstrap payload."""
    assert csrf_token(signed_in_client)
