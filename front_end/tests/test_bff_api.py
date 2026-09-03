"""Contract tests for the JSON endpoints the React portal calls.

These replace the old assertions against rendered Jinja HTML. Everything the
previous suite protected on the server side is still covered here; the parts that
moved into the client are covered by the Vitest suite in front_end/web.
"""

import pytest

from conftest import API, HISTORY_PATHS, VMS, csrf_token, post


# ============================================================== SPA shell


def test_unknown_page_path_serves_the_spa_shell(signed_in_client):
    """A deep link or a hard refresh has to reach React, not a 404 from Flask."""
    for path in ["/", "/vms", "/vms/1/update", "/scaling/rules/history", "/settings/hosts"]:
        response = signed_in_client.get(path)
        assert response.status_code == 200, path
        assert response.headers["Content-Type"].startswith("text/html"), path


def test_the_shell_is_never_cached(signed_in_client):
    """The shell names hashed asset files, so caching it would leave browsers
    asking for assets a deploy has already replaced."""
    assert signed_in_client.get("/").headers["Cache-Control"] == "no-store"


def test_unknown_api_path_returns_json_not_the_shell(signed_in_client):
    """The catch-all must not swallow API paths; the client expects JSON there."""
    response = signed_in_client.get(f"{API}/does-not-exist")
    assert response.status_code == 404
    assert response.get_json()["error"]


def test_the_shell_references_no_external_assets(signed_in_client):
    """The portal must render in sovereign and air-gapped clouds, so nothing may
    be fetched from a public CDN."""
    html = signed_in_client.get("/").get_data(as_text=True)
    for pattern in ("cdn.jsdelivr.net", "unpkg.com", "cdnjs.", "fonts.googleapis.com"):
        assert pattern not in html


def test_health_reports_the_version(client):
    payload = client.get("/health").get_json()
    assert payload["status"] == "healthy"
    assert payload["version"]


# ========================================================= authentication


ANONYMOUS_API_PATHS = [
    f"{API}/dashboard", f"{API}/vms", f"{API}/vms/1", f"{API}/vms/history",
    f"{API}/scaling/rules", f"{API}/scaling/rules/1", f"{API}/scaling/log",
    f"{API}/scaling/rules/history", f"{API}/hosts/settings",
]


@pytest.mark.parametrize("path", ANONYMOUS_API_PATHS)
def test_api_returns_401_json_when_signed_out(client, path):
    """`fetch` cannot follow a 302 to Entra ID, so an expired session has to come
    back as a 401 the client can act on."""
    response = client.get(path)
    assert response.status_code == 401
    assert response.headers["Content-Type"].startswith("application/json")
    assert response.get_json()["error"]


def test_page_requests_still_redirect_to_login_when_signed_out(client):
    """Only the API speaks JSON; a browser navigation keeps the redirect."""
    response = client.get("/logout")
    assert response.status_code in {302, 303}


def test_session_endpoint_reports_anonymous_without_bouncing(client):
    """The signed-out landing page needs a successful response, not a 401."""
    payload = client.get(f"{API}/session").get_json()
    assert payload["authenticated"] is False
    assert payload["user"] is None
    assert payload["csrfToken"]


def test_session_endpoint_reports_the_signed_in_user(signed_in_client):
    payload = signed_in_client.get(f"{API}/session").get_json()
    assert payload["authenticated"] is True
    assert payload["user"]["name"] == "Test Operator"
    assert payload["user"]["username"] == "op@contoso.com"
    assert payload["version"]


def test_session_endpoint_survives_a_malformed_session(signed_in_client):
    """base.html used to guard against this; a non-mapping user must not turn a
    handled state into a 500."""
    with signed_in_client.session_transaction() as session:
        session["user"] = "not-a-mapping"

    response = signed_in_client.get(f"{API}/session")
    assert response.status_code == 200
    assert response.get_json()["user"] is None


# ==================================================================== CSRF


def test_csrf_rejects_a_missing_token(signed_in_client):
    response = signed_in_client.post(f"{API}/vms/1/delete", json={})
    assert response.status_code == 400
    assert "session expired" in response.get_json()["error"].lower()


def test_csrf_accepts_the_header_token(signed_in_client):
    response = post(signed_in_client, f"{API}/vms/1/delete")
    assert response.status_code == 200


def test_scaling_rule_delete_is_csrf_protected(signed_in_client):
    response = signed_in_client.post(f"{API}/scaling/rules/1/delete", json={})
    assert response.status_code == 400


def test_host_settings_apply_is_csrf_protected(signed_in_client):
    response = signed_in_client.post(f"{API}/hosts/settings/apply", json={})
    assert response.status_code == 400


# =============================================================== dashboard


def test_dashboard_uses_the_summary_endpoint(signed_in_client, broker_api):
    """The dashboard must not pull the whole VM list just to count it."""
    broker_api.vm_summary = {
        "TotalVMs": 9, "Available": 4, "CheckedOut": 3, "Maintenance": 1,
        "Released": 1, "PoweredOn": 7, "PoweredOff": 2, "Unreachable": 2,
        "Ready": 3,
    }
    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["apiError"] is False
    assert payload["stats"]["total"] == 9
    assert payload["stats"]["checked_out"] == 3
    # 3 of 9 checked out.
    assert payload["stats"]["utilization"] == 33


def test_dashboard_falls_back_when_api_predates_the_summary_endpoint(signed_in_client, broker_api):
    """During a rolling deploy the portal can be newer than the API.

    An older API does not 404 on /api/vms/summary -- Werkzeug matches it against the
    older /api/vms/<vmid> rule, which fails converting 'summary' to an int and
    returns 500. The fallback must handle that, not just a clean 404.
    """
    broker_api.summary_status = 500
    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["apiError"] is False
    # Counted client-side from the four seeded VMs.
    assert payload["stats"]["total"] == 4
    assert payload["stats"]["ready"] == 1


def test_dashboard_reports_an_outage_when_both_paths_fail(signed_in_client, broker_api):
    """The fallback must not mask a genuine broker outage."""
    broker_api.summary_status = 500
    broker_api.raise_get_paths.add("/vms")

    payload = signed_in_client.get(f"{API}/dashboard").get_json()
    assert payload["apiError"] is True
    assert payload["stats"] is None


def test_dashboard_handles_a_non_list_activity_log(signed_in_client, broker_api):
    broker_api.scaling_log_payload = {"message": "no results"}
    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["stats"] is not None
    assert payload["recentActivity"] == []


def test_dashboard_survives_a_failing_activity_log(signed_in_client, broker_api):
    """A secondary panel must never take the dashboard down."""
    broker_api.raise_post_paths.add("/scaling/log")
    payload = signed_in_client.get(f"{API}/dashboard").get_json()

    assert payload["stats"] is not None
    assert payload["recentActivity"] == []


def test_dashboard_caps_recent_activity(signed_in_client):
    payload = signed_in_client.get(f"{API}/dashboard").get_json()
    assert len(payload["recentActivity"]) <= 5


# ================================================================= history


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_filters_are_sent_to_the_api_in_the_expected_format(signed_in_client, broker_api, path):
    """The operator enters YYYY-MM-DD; the stored procedures expect MM/DD/YYYY."""
    response = signed_in_client.get(
        f"{path}?startdate=2026-01-15&enddate=2026-02-20&limit=37"
    )
    assert response.status_code == 200

    sent = broker_api.posts[-1]["json"]
    assert sent["startdate"] == "01/15/2026"
    assert sent["enddate"] == "02/20/2026"
    assert sent["limit"] == 37          # a real int, not the string "37"


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_ignore_flags_omit_the_filters(signed_in_client, broker_api, path):
    """The ignore flags mean "omit the filter" rather than sending the
    stringly-typed "null" sentinel the API had to special-case."""
    response = signed_in_client.get(
        f"{path}?startdate=2026-03-01&enddate=2026-03-31&limit=42"
        "&ignore_dates=1&ignore_limit=1"
    )
    assert response.status_code == 200

    sent = broker_api.posts[-1]["json"]
    assert "startdate" not in sent
    assert "enddate" not in sent
    assert "limit" not in sent


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_ignore_flags_without_values_do_not_break(signed_in_client, broker_api, path):
    response = signed_in_client.get(f"{path}?ignore_dates=1&ignore_limit=1")
    assert response.status_code == 200

    sent = broker_api.posts[-1]["json"]
    assert sent == {}


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_an_unparseable_date_is_rejected_with_a_useful_message(signed_in_client, path):
    """Reported against the request that carried it, rather than surfacing later
    as an opaque query failure."""
    response = signed_in_client.get(f"{path}?startdate=15-01-2026")
    assert response.status_code == 400
    assert "YYYY-MM-DD" in response.get_json()["error"]


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_an_unparseable_date_is_accepted_when_dates_are_ignored(signed_in_client, path):
    response = signed_in_client.get(f"{path}?startdate=15-01-2026&ignore_dates=1")
    assert response.status_code == 200


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_history_uses_server_side_pagination(signed_in_client, broker_api, path):
    """Pages come from the API rather than a whole result set cached in the session."""
    response = signed_in_client.get(f"{path}?page=3&per_page=10")
    assert response.status_code == 200

    params = broker_api.posts[-1]["params"]
    assert params["page"] == 3
    assert params["per_page"] == 10

    payload = response.get_json()
    assert payload["page"] == 3
    assert payload["perPage"] == 10
    assert payload["total"] == 120
    assert payload["totalPages"] == 12
    assert len(payload["items"]) == 10


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_filters_are_not_stored_in_the_session(signed_in_client, path):
    """Filters live in the URL now, so two tabs cannot clobber each other and the
    session cannot grow without bound."""
    signed_in_client.get(f"{path}?startdate=2026-01-15&limit=37")

    with signed_in_client.session_transaction() as session:
        for key in session.keys():
            assert "history" not in key
            assert "filters" not in key
            assert "scaling_activity_log" not in key


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_history_falls_back_when_api_predates_pagination(signed_in_client, broker_api, path):
    """During a rolling deploy the API may still answer with a bare list."""
    broker_api.legacy_history = True
    response = signed_in_client.get(f"{path}?page=1&per_page=10")

    assert response.status_code == 200
    payload = response.get_json()
    assert payload["total"] == 120
    assert payload["totalPages"] == 12
    assert len(payload["items"]) == 10


@pytest.mark.parametrize("path", HISTORY_PATHS)
@pytest.mark.parametrize("query", ["page=abc", "page=0", "page=999999", "per_page=-3",
                                   "per_page=abc", "per_page=100000"])
def test_hostile_pagination_query_strings_do_not_500(signed_in_client, path, query):
    response = signed_in_client.get(f"{path}?{query}")
    assert response.status_code < 500


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_per_page_is_capped(signed_in_client, broker_api, path):
    signed_in_client.get(f"{path}?per_page=100000")
    assert broker_api.posts[-1]["params"]["per_page"] == 200


@pytest.mark.parametrize("path", HISTORY_PATHS)
def test_history_reports_a_broker_outage(signed_in_client, broker_api, path):
    broker_api.raise_post_paths.add(path.replace(API, ""))
    response = signed_in_client.get(path)
    assert response.status_code == 502
    assert "Unable to retrieve" in response.get_json()["error"]


# ===================================================================== VMs


def test_vms_are_returned_as_json(signed_in_client):
    payload = signed_in_client.get(f"{API}/vms").get_json()
    assert [vm["Hostname"] for vm in payload] == [vm["Hostname"] for vm in VMS]


def test_vm_details_are_returned_as_json(signed_in_client):
    payload = signed_in_client.get(f"{API}/vms/2").get_json()
    assert payload["Hostname"] == "linux-host-02"


def test_vm_list_reports_a_broker_outage(signed_in_client, broker_api):
    broker_api.raise_get_paths.add("/vms")
    response = signed_in_client.get(f"{API}/vms")
    assert response.status_code == 502
    assert "Unable to retrieve VM data" in response.get_json()["error"]


def test_add_vm_forwards_the_full_payload(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms", {
        "hostname": "linux-host-09",
        "ipaddress": "10.0.0.9",
        "powerstate": "On",
        "networkstatus": "Reachable",
        "vmstatus": "Available",
    })
    assert response.status_code == 201

    sent = broker_api.posts[-1]["json"]
    assert sent["hostname"] == "linux-host-09"
    # Optional fields are sent as empty strings rather than omitted, matching what
    # the form used to submit.
    assert sent["username"] == ""
    assert sent["avdhost"] == ""
    assert sent["description"] == ""


def test_add_vm_names_the_missing_fields(signed_in_client):
    """`request.form['x']` used to raise and surface as a bare 400, which said
    nothing about which field was wrong."""
    response = post(signed_in_client, f"{API}/vms", {"hostname": "linux-host-09"})
    assert response.status_code == 400

    error = response.get_json()["error"]
    for field in ("ipaddress", "powerstate", "networkstatus", "vmstatus"):
        assert field in error


def test_add_vm_rejects_a_blank_required_field(signed_in_client):
    response = post(signed_in_client, f"{API}/vms", {
        "hostname": "   ",
        "ipaddress": "10.0.0.9",
        "powerstate": "On",
        "networkstatus": "Reachable",
        "vmstatus": "Available",
    })
    assert response.status_code == 400
    assert "hostname" in response.get_json()["error"]


def test_update_vm_attributes_forwards_the_three_fields(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/vms/1/update-attributes", {
        "powerstate": "Off",
        "networkstatus": "Unreachable",
        "vmstatus": "Maintenance",
    })
    assert response.status_code == 200
    assert broker_api.posts[-1]["json"] == {
        "powerstate": "Off", "networkstatus": "Unreachable", "vmstatus": "Maintenance",
    }


def test_release_uses_the_hostname_and_return_uses_the_vmid(signed_in_client, broker_api):
    """The broker's own routes differ, and the portal must not swap them."""
    post(signed_in_client, f"{API}/vms/linux-host-02/release")
    assert broker_api.posts[-1]["url"].endswith("/vms/linux-host-02/release")

    post(signed_in_client, f"{API}/vms/2/return")
    assert broker_api.posts[-1]["url"].endswith("/vms/2/return")


def test_checkout_requires_both_fields(signed_in_client):
    response = post(signed_in_client, f"{API}/vms/checkout", {"username": "op@contoso.com"})
    assert response.status_code == 400
    assert "avdhost" in response.get_json()["error"]


def test_checkout_returns_the_assigned_vm(signed_in_client):
    response = post(signed_in_client, f"{API}/vms/checkout", {
        "username": "op@contoso.com", "avdhost": "avd-01",
    })
    assert response.status_code == 200
    assert response.get_json()["VMID"] == 1


def test_history_route_is_not_shadowed_by_the_vm_detail_route(signed_in_client):
    """/vms/history and /vms/<int:vmid> share a prefix; the static rule must win."""
    payload = signed_in_client.get(f"{API}/vms/history").get_json()
    assert "items" in payload


# ================================================================= scaling


def test_scaling_rules_are_returned_as_json(signed_in_client):
    payload = signed_in_client.get(f"{API}/scaling/rules").get_json()
    assert payload[0]["RuleID"] == 1


def test_rule_details_are_returned_as_json(signed_in_client):
    payload = signed_in_client.get(f"{API}/scaling/rules/1").get_json()
    assert payload["MinVMs"] == 2


def test_create_rule_forwards_every_threshold(signed_in_client, broker_api):
    body = {
        "minvms": "2", "maxvms": "20", "scaleupratio": "80",
        "scaleupincrement": "2", "scaledownratio": "30", "scaledownincrement": "1",
    }
    response = post(signed_in_client, f"{API}/scaling/rules", body)

    assert response.status_code == 201
    assert broker_api.posts[-1]["json"] == body


def test_create_rule_names_the_missing_fields(signed_in_client):
    response = post(signed_in_client, f"{API}/scaling/rules", {"minvms": "2"})
    assert response.status_code == 400

    error = response.get_json()["error"]
    for field in ("maxvms", "scaleupratio", "scaleupincrement",
                  "scaledownratio", "scaledownincrement"):
        assert field in error


def test_update_rule_targets_the_right_rule(signed_in_client, broker_api):
    response = post(signed_in_client, f"{API}/scaling/rules/7/update", {
        "minvms": "1", "maxvms": "9", "scaleupratio": "70",
        "scaleupincrement": "1", "scaledownratio": "20", "scaledownincrement": "1",
    })
    assert response.status_code == 200
    assert broker_api.posts[-1]["url"].endswith("/scaling/rules/7/update")


def test_rules_history_route_is_not_shadowed_by_the_rule_detail_route(signed_in_client):
    payload = signed_in_client.get(f"{API}/scaling/rules/history").get_json()
    assert "items" in payload


# ============================================================ error mapping


def test_a_broker_4xx_keeps_its_status_and_message(signed_in_client, monkeypatch):
    """The broker explains exactly what it rejected, which is far more useful to
    an admin than a generic failure."""
    from conftest import FakeResponse

    def bad_request(url, **kwargs):
        return FakeResponse({"error": "GracePeriodSeconds must be between 60 and 86400."},
                            status_code=400)

    import requests
    monkeypatch.setattr(requests, "post", bad_request)

    response = post(signed_in_client, f"{API}/hosts/settings", {"graceperiodseconds": "5"})
    assert response.status_code == 400
    assert "GracePeriodSeconds must be between" in response.get_json()["error"]


def test_a_broker_5xx_becomes_a_502(signed_in_client, monkeypatch):
    """A broker failure is not the operator's bad request."""
    from conftest import FakeResponse

    def server_error(url, **kwargs):
        return FakeResponse({"error": "boom"}, status_code=500)

    import requests
    monkeypatch.setattr(requests, "post", server_error)

    response = post(signed_in_client, f"{API}/vms/1/delete")
    assert response.status_code == 502


def test_an_expired_token_returns_401_json(signed_in_client):
    from datetime import datetime, timedelta

    with signed_in_client.session_transaction() as session:
        # Matches the app's naive datetime.utcnow().timestamp() convention.
        session["token_expiry"] = (datetime.utcnow() - timedelta(minutes=5)).timestamp()

    response = signed_in_client.get(f"{API}/vms")
    assert response.status_code == 401
    assert response.get_json()["error"]


def test_deleted_templates_are_not_referenced():
    """The Jinja portal is gone; nothing may still try to render it."""
    from pathlib import Path

    front_end = Path(__file__).resolve().parents[1]
    assert not (front_end / "templates").exists()
    assert not (front_end / "static" / "bootstrap").exists()

    for module in front_end.glob("*.py"):
        text = module.read_text(encoding="utf-8")
        assert "render_template" not in text, f"{module.name} still renders a template"
        assert "flash(" not in text, f"{module.name} still uses flash messages"
