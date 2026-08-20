import re
from pathlib import Path

import pytest

from conftest import VMS, assert_checkbox_checked, assert_form_value, csrf_token, row_for_host, seed_histories


AUTHENTICATED_GET_ROUTES = [
    "/", "/profile", "/vms", "/vms/1", "/vms/add", "/vms/1/update", "/vms/checkout",
    "/vms/history", "/scaling/rules", "/scaling/rules/1", "/scaling/rules/create",
    "/scaling/rules/1/update", "/scaling/log", "/scaling/rules/history",
]


@pytest.mark.parametrize("path", AUTHENTICATED_GET_ROUTES)
def test_authenticated_pages_render_without_bootstrap4_or_cdn(signed_in_client, path):
    response = signed_in_client.get(path)
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    assert "cdn.jsdelivr.net" not in html
    assert not re.search(r"https?://[^\"'\s>]*(?:cdn|jsdelivr|unpkg|cdnjs)[^\"'\s>]*", html, re.I)
    for legacy_class in ("form-row", "form-group", "form-inline", "thead-dark", "jumbotron", "mr-2"):
        assert legacy_class not in html


def test_error_template_exists_and_renders_without_arguments(app):
    """route_user.profile falls back to `render_template('error.html')` with no
    arguments, so the zero-argument path is the one that must not break."""
    with app.test_request_context("/profile"):
        from flask import render_template
        bare = render_template("error.html")
        detailed = render_template("error.html", code=500, title="Test error", message="friendly")

    assert "Something went wrong" in bare
    assert "500" not in bare
    assert "Test error" in detailed
    assert "500" in detailed
    assert "friendly" in detailed


def test_profile_falls_back_to_error_page_when_rendering_fails(signed_in_client):
    """Exercises the real except branch in route_user.profile. Before the fix
    this raised TemplateNotFound because error.html did not exist."""
    with signed_in_client.session_transaction() as session:
        session["user"] = "not-a-mapping"      # makes profile.html raise

    response = signed_in_client.get("/profile")
    assert response.status_code == 200
    assert "Something went wrong" in response.get_data(as_text=True)


def test_deleted_templates_are_not_referenced():
    repo = Path(__file__).resolve().parents[2]
    deleted_templates = {
        "vm/delete_vm.html",
        "vm/release_vm.html",
        "vm/return_vm.html",
        "scaling/delete_rule.html",
    }
    searchable = list((repo / "front_end").glob("*.py")) + list((repo / "front_end" / "templates").glob("**/*.html"))
    for file_path in searchable:
        text = file_path.read_text(encoding="utf-8")
        for template in deleted_templates:
            assert template not in text, f"{template} is still referenced by {file_path}"


@pytest.mark.parametrize("path", ["/vms/history", "/scaling/log", "/scaling/rules/history"])
def test_filter_values_survive_post_redirect_get(signed_in_client, path):
    html = signed_in_client.get(path).get_data(as_text=True)
    token = csrf_token(html)
    response = signed_in_client.post(path, data={
        "csrf_token": token,
        "startdate": "2026-01-15",
        "enddate": "2026-02-20",
        "limit": "37",
    }, follow_redirects=True)
    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert_form_value(body, "startdate", "2026-01-15")
    assert_form_value(body, "enddate", "2026-02-20")
    assert_form_value(body, "limit", "37")


@pytest.mark.parametrize("path", ["/vms/history", "/scaling/log", "/scaling/rules/history"])
def test_ignore_filter_checkboxes_survive_post_redirect_get(signed_in_client, broker_api, path):
    """The ignore checkboxes mark the dates/limit as ignored for the API call,
    but the operator's typed values must still come back so unticking restores
    them. app.js therefore sets those inputs readOnly rather than disabled --
    disabled controls are omitted from submission and the values were lost."""
    html = signed_in_client.get(path).get_data(as_text=True)
    token = csrf_token(html)
    response = signed_in_client.post(path, data={
        "csrf_token": token,
        "startdate": "2026-03-01",
        "enddate": "2026-03-31",
        "limit": "42",
        "ignore_dates": "on",
        "ignore_limit": "on",
    }, follow_redirects=True)
    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert_form_value(body, "startdate", "2026-03-01")
    assert_form_value(body, "enddate", "2026-03-31")
    assert_form_value(body, "limit", "42")
    assert_checkbox_checked(body, "ignore_dates")
    assert_checkbox_checked(body, "ignore_limit")
    # Whatever was typed, the API must still be told to ignore both.
    assert broker_api.posts[-1]["json"] == {"startdate": "null", "enddate": "null", "limit": "null"}


@pytest.mark.parametrize("path", ["/vms/history", "/scaling/log", "/scaling/rules/history"])
def test_ignore_flags_without_values_do_not_break(signed_in_client, broker_api, path):
    """Defensive: a client that omits the ignored fields entirely (no JavaScript,
    or a control left disabled) must still work rather than 500."""
    html = signed_in_client.get(path).get_data(as_text=True)
    response = signed_in_client.post(path, data={
        "csrf_token": csrf_token(html),
        "ignore_dates": "on",
        "ignore_limit": "on",
    }, follow_redirects=True)
    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert_checkbox_checked(body, "ignore_dates")
    assert_checkbox_checked(body, "ignore_limit")
    assert broker_api.posts[-1]["json"] == {"startdate": "null", "enddate": "null", "limit": "null"}


@pytest.mark.parametrize("path", ["/vms/history", "/scaling/log", "/scaling/rules/history"])
def test_pagination_is_windowed_for_many_pages(signed_in_client, path):
    seed_histories(signed_in_client, count=120)
    response = signed_in_client.get(f"{path}?page=6&per_page=10")
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    numeric_links = set(re.findall(r"page=(\d+)&amp;per_page=10", html))
    # Pinned exactly: window=2 around page 6, plus first and last.
    assert numeric_links == {"1", "4", "5", "6", "7", "8", "12"}


@pytest.mark.parametrize("path", ["/vms/history", "/scaling/log", "/scaling/rules/history"])
@pytest.mark.parametrize("query", ["page=abc", "page=0", "page=999999", "per_page=-3"])
def test_hostile_pagination_query_strings_do_not_500(signed_in_client, path, query):
    seed_histories(signed_in_client, count=20)
    response = signed_in_client.get(f"{path}?{query}", follow_redirects=True)
    assert response.status_code < 500


def test_csrf_rejects_missing_token_and_accepts_valid_token(signed_in_client):
    missing = signed_in_client.post("/vms/1/delete", data={})
    assert missing.status_code == 400
    assert "Session expired" in missing.get_data(as_text=True)

    html = signed_in_client.get("/vms").get_data(as_text=True)
    valid = signed_in_client.post("/vms/1/delete", data={"csrf_token": csrf_token(html)})
    assert valid.status_code in {302, 303}


def test_scaling_rule_delete_is_csrf_protected(signed_in_client):
    response = signed_in_client.post("/scaling/rules/1/delete", data={})
    assert response.status_code == 400
    assert "Session expired" in response.get_data(as_text=True)


def test_vm_row_actions_follow_lifecycle_rules(signed_in_client):
    html = signed_in_client.get("/vms").get_data(as_text=True)
    expectations = {
        "linux-host-01": {"release": False, "return": False},
        "linux-host-02": {"release": True, "return": True},
        "linux-host-03": {"release": False, "return": False},
        "linux-host-04": {"release": False, "return": True},
    }
    vm_ids = {vm["Hostname"]: vm["VMID"] for vm in VMS}
    for host, expected in expectations.items():
        row = row_for_host(html, host)
        assert (f'action="/vms/{host}/release"' in row) is expected["release"]
        assert (f'action="/vms/{vm_ids[host]}/return"' in row) is expected["return"]


def test_dashboard_handles_non_list_activity_log(signed_in_client, broker_api):
    broker_api.scaling_log_payload = {"message": "no results"}
    response = signed_in_client.get("/")
    assert response.status_code == 200
    html = response.get_data(as_text=True)
    assert "Pool overview" in html
    assert "No recent scaling activity" in html


def test_dashboard_degrades_when_vm_api_is_unavailable(signed_in_client, broker_api):
    broker_api.raise_get_paths.add("/vms")
    response = signed_in_client.get("/")
    assert response.status_code == 200
    assert "Pool data unavailable" in response.get_data(as_text=True)
