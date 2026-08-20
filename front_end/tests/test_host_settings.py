"""Tests for the Linux host settings page."""

from conftest import HOST_SETTINGS, assert_checkbox_checked, assert_form_value, csrf_token, row_for_host


def get_settings_page(client):
    response = client.get("/settings/hosts")
    assert response.status_code == 200
    return response.get_data(as_text=True)


def post_settings(client, overrides=None, follow_redirects=False):
    html = get_settings_page(client)
    form = {
        "csrf_token": csrf_token(html),
        "graceperiodseconds": "1200",
        "reconcileintervalseconds": "60",
        "watcherdebounceseconds": "10",
        "watchersettleseconds": "2",
        "idletimeoutseconds": "0",
        "idlewarningseconds": "120",
        "screenidledelayseconds": "0",
        "screenlockdelayseconds": "0",
    }
    form.update(overrides or {})
    return client.post("/settings/hosts", data=form, follow_redirects=follow_redirects)


def test_requires_sign_in(client):
    response = client.get("/settings/hosts")
    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_page_renders_current_values(signed_in_client):
    html = get_settings_page(signed_in_client)

    assert "Linux Host Settings" in html
    assert f"Settings version {HOST_SETTINGS['SettingsVersion']}" in html
    assert_form_value(html, "graceperiodseconds", "1200")
    assert_form_value(html, "reconcileintervalseconds", "60")
    assert_form_value(html, "idletimeoutseconds", "0")


def test_disabled_idle_enforcement_is_called_out(signed_in_client):
    html = get_settings_page(signed_in_client)
    assert "Idle enforcement is currently disabled" in html


def test_screen_lock_defaults_reflect_the_disabled_lock_screen(signed_in_client):
    html = get_settings_page(signed_in_client)

    # The shipped posture removes the lock screen, because a locked greeter inside an xrdp
    # session can strand the host lease.
    assert_checkbox_checked(html, "disablelockscreen")
    assert_checkbox_checked(html, "screenlocksettingslocked")
    assert 'name="screenlockenabled"' in html
    assert 'name="screenlockenabled" checked' not in html


def test_drift_table_distinguishes_host_states(signed_in_client, broker_api):
    broker_api.host_settings = dict(HOST_SETTINGS, SettingsVersion=4)
    from conftest import VMS
    VMS[0]["SettingsVersion"] = 4
    VMS[0]["SettingsAppliedDate"] = "2026-08-19 20:00:00"
    VMS[1]["SettingsVersion"] = 3
    VMS[1]["SettingsAppliedDate"] = "2026-08-19 18:00:00"
    VMS[2]["SettingsVersion"] = None
    VMS[2]["SettingsAppliedDate"] = None

    try:
        html = get_settings_page(signed_in_client)

        assert "text-bg-success" in row_for_host(html, "linux-host-01")
        assert "pending 4" in row_for_host(html, "linux-host-02")
        assert "not reported" in row_for_host(html, "linux-host-03")
    finally:
        for vm in VMS:
            vm.pop("SettingsVersion", None)
            vm.pop("SettingsAppliedDate", None)


def test_save_sends_integers_to_the_api(signed_in_client, broker_api):
    response = post_settings(signed_in_client, {"graceperiodseconds": "900", "idletimeoutseconds": "1800"})
    assert response.status_code == 302

    payload = next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/update"))
    assert payload["GracePeriodSeconds"] == 900
    assert payload["IdleTimeoutSeconds"] == 1800
    assert payload["updatedBy"] == "op@contoso.com"


def test_unchecked_boxes_are_sent_as_false(signed_in_client, broker_api):
    # Checkboxes are absent from the form when unchecked, so they must be sent explicitly
    # rather than omitted, which the API reads as "leave unchanged".
    post_settings(signed_in_client)

    payload = next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/update"))
    assert payload["ScreenLockEnabled"] is False
    assert payload["DisableLockScreen"] is False
    assert payload["ScreenLockSettingsLocked"] is False


def test_checked_boxes_are_sent_as_true(signed_in_client, broker_api):
    post_settings(signed_in_client, {"disablelockscreen": "on", "screenlocksettingslocked": "on"})

    payload = next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/update"))
    assert payload["DisableLockScreen"] is True
    assert payload["ScreenLockSettingsLocked"] is True
    assert payload["ScreenLockEnabled"] is False


def test_non_numeric_value_never_reaches_the_api(signed_in_client, broker_api):
    response = post_settings(signed_in_client, {"graceperiodseconds": "not-a-number"})
    assert response.status_code == 302
    assert not any(p["url"].endswith("/hosts/settings/update") for p in broker_api.posts)


def test_save_requires_a_csrf_token(signed_in_client):
    response = signed_in_client.post("/settings/hosts", data={"graceperiodseconds": "900"})
    assert response.status_code == 400


def test_broker_failure_on_save_is_reported(signed_in_client, broker_api):
    broker_api.raise_post_paths.add("/hosts/settings/update")
    response = post_settings(signed_in_client, follow_redirects=True)
    assert "Unable to save host settings" in response.get_data(as_text=True)


def test_broker_failure_on_load_redirects_home(signed_in_client, broker_api):
    broker_api.raise_get_paths.add("/hosts/settings")
    response = signed_in_client.get("/settings/hosts")
    assert response.status_code == 302


def test_drift_table_failure_does_not_hide_the_form(signed_in_client, broker_api):
    # The settings form must still be usable when the VM list cannot be loaded.
    broker_api.raise_get_paths.add("/vms")
    html = get_settings_page(signed_in_client)
    assert "Linux Host Settings" in html
    assert "No Linux hosts registered" in html


def test_apply_to_all_hosts_sends_no_hostname_filter(signed_in_client, broker_api):
    html = get_settings_page(signed_in_client)
    response = signed_in_client.post("/settings/hosts/apply", data={"csrf_token": csrf_token(html)})
    assert response.status_code == 302

    payload = next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/apply"))
    assert payload == {}


def test_apply_to_single_host_targets_that_host(signed_in_client, broker_api):
    html = get_settings_page(signed_in_client)
    signed_in_client.post("/settings/hosts/apply",
                          data={"csrf_token": csrf_token(html), "hostname": "linux-host-02"})

    payload = next(p["json"] for p in broker_api.posts if p["url"].endswith("/hosts/settings/apply"))
    assert payload == {"hostnames": ["linux-host-02"]}


def test_partial_apply_names_the_hosts_that_failed(signed_in_client, broker_api):
    broker_api.apply_result = {
        "SettingsVersion": 3, "TargetCount": 2, "SucceededCount": 1,
        "Results": [{"Hostname": "linux-host-01", "Applied": True, "Message": "Applied."},
                    {"Hostname": "linux-host-02", "Applied": False, "Message": "unreachable"}],
    }
    html = get_settings_page(signed_in_client)
    response = signed_in_client.post("/settings/hosts/apply",
                                     data={"csrf_token": csrf_token(html)},
                                     follow_redirects=True)

    body = response.get_data(as_text=True)
    assert "linux-host-02" in body
    assert "Unreachable" in body


def test_apply_requires_a_csrf_token(signed_in_client):
    response = signed_in_client.post("/settings/hosts/apply", data={})
    assert response.status_code == 400


def test_nav_links_to_host_settings(signed_in_client):
    html = get_settings_page(signed_in_client)
    assert "/settings/hosts" in html
    assert "Host Settings" in html
