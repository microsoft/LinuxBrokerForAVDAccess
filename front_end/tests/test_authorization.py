"""Portal authorization uses the broker's verified capabilities, not token parsing."""

from time import time
from types import SimpleNamespace

import pytest
import requests

from conftest import API, SUBJECT, VMS, FakeResponse, csrf_token

LEASE = {"leaseId": VMS[1]["LeaseId"], "leaseGeneration": VMS[1]["LeaseGeneration"]}
NEW_VM = {
    "hostname": "linux-host-09", "ipaddress": "10.0.0.9", "powerstate": "On",
    "networkstatus": "Reachable", "vmstatus": "Available",
}
RULE = {
    "minvms": "1", "maxvms": "9", "scaleupratio": "80", "scaleupincrement": "2",
    "scaledownratio": "20", "scaledownincrement": "1",
}
BUSINESS_ROUTES = [
    ("GET", "/dashboard", None),
    ("GET", "/vms", None),
    ("GET", "/vms/2", None),
    ("GET", "/vms/history", None),
    ("GET", "/scaling/rules", None),
    ("GET", "/scaling/rules/1", None),
    ("GET", "/scaling/rules/history", None),
    ("GET", "/scaling/log", None),
    ("GET", "/hosts/settings", None),
    ("POST", "/vms", NEW_VM),
    ("POST", "/vms/1/update-attributes", {
        "powerstate": "On", "networkstatus": "Reachable", "vmstatus": "Maintenance",
    }),
    ("POST", "/vms/1/delete", {}),
    ("POST", "/vms/linux-host-02/release", LEASE),
    ("POST", "/vms/2/return", LEASE),
    ("POST", "/scaling/rules", RULE),
    ("POST", "/scaling/rules/1/update", RULE),
    ("POST", "/scaling/rules/1/delete", {}),
    ("POST", "/hosts/settings", {"graceperiodseconds": "1200"}),
    ("POST", "/hosts/settings/apply", {}),
]


def call_route(client, method, path, body, token):
    return client.open(f"{API}{path}", method=method, json=body,
                       headers={"X-CSRFToken": token})


def assert_only_capability_calls(broker_api):
    assert broker_api.gets
    assert all(call["url"].endswith("/me") for call in broker_api.gets)
    assert broker_api.posts == []


def test_authorization_matrix_covers_every_business_route(app):
    adapter = app.url_map.bind("localhost")
    covered = {adapter.match(f"{API}{path}", method=method)[0]
               for method, path, _ in BUSINESS_ROUTES}
    registered = {rule.endpoint for rule in app.url_map.iter_rules()
                  if rule.rule.startswith(API) and rule.rule != f"{API}/session"}
    assert covered == registered


@pytest.mark.parametrize("method,path,body", BUSINESS_ROUTES)
def test_administrators_keep_all_management_routes(signed_in_client, broker_api, method, path, body):
    token = csrf_token(signed_in_client)
    broker_api.gets.clear()
    response = call_route(signed_in_client, method, path, body, token)
    assert response.status_code in (200, 201)
    assert broker_api.gets[0]["url"].endswith("/me")
    assert response.headers["Cache-Control"] == "no-store"


@pytest.mark.parametrize("method,path,body", BUSINESS_ROUTES)
@pytest.mark.parametrize("roles,scope,connect", [
    (["WorkspaceUser"], "connect_as_user", True),
    ([], "access_as_user", False),
    (["FullAccess"], "access_as_user", False),
])
def test_non_admins_cannot_call_business_routes_even_with_csrf(
        signed_in_client, broker_api, method, path, body, roles, scope, connect):
    token = csrf_token(signed_in_client)
    with signed_in_client.session_transaction() as session:
        session["user"] = dict(session["user"], roles=roles, scp=scope, groups=["FullAccess"])
    broker_api.capability_response["capabilities"] = {"manage": False, "connect": connect}
    broker_api.gets.clear()

    response = call_route(signed_in_client, method, path, body, token)

    assert response.status_code == 403
    assert response.get_json()["code"] == "administrator_required"
    assert "AVD access is unchanged" in response.get_json()["error"]
    assert "Location" not in response.headers
    assert_only_capability_calls(broker_api)


def test_id_token_roles_cannot_override_trusted_admin_capability(signed_in_client, broker_api):
    with signed_in_client.session_transaction() as session:
        session["user"]["roles"] = ["WorkspaceUser"]
        session["access_token"] = "opaque-api-token-not-decoded-by-the-portal"

    response = signed_in_client.get(f"{API}/session")

    assert response.status_code == 200
    payload = response.get_json()
    assert payload["subject"] == SUBJECT
    assert payload["capabilities"] == {"manage": True, "connect": False}
    assert "roles" not in payload["user"]
    assert broker_api.gets[-1]["headers"]["Authorization"] == "Bearer opaque-api-token-not-decoded-by-the-portal"
    assert broker_api.gets[-1]["allow_redirects"] is False


def test_denied_bootstrap_contains_only_own_identity_and_capabilities(signed_in_client, broker_api):
    broker_api.capability_response["capabilities"] = {"manage": False, "connect": True}
    response = signed_in_client.get(f"{API}/session")
    payload = response.get_json()
    assert response.status_code == 200
    assert payload["authenticated"] is True
    assert payload["subject"] == SUBJECT
    assert payload["capabilities"] == {"manage": False, "connect": True}
    assert set(payload) == {"authenticated", "subject", "capabilities", "user", "version", "csrfToken"}
    assert_only_capability_calls(broker_api)
    assert signed_in_client.get("/logout").status_code == 302


def test_permissions_are_rechecked_on_every_request(signed_in_client, broker_api):
    assert signed_in_client.get(f"{API}/vms").status_code == 200
    broker_api.capability_response["capabilities"]["manage"] = False
    broker_api.gets.clear()
    assert signed_in_client.get(f"{API}/vms").status_code == 403
    assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("key,value", [
    ("user", None), ("user", {}), ("user", "invalid"),
    ("user", {"tid": SUBJECT["tenantId"]}), ("user", {"tid": [], "oid": "object"}),
    ("access_token", None), ("access_token", ""), ("access_token", []),
    ("token_expiry", None), ("token_expiry", 0), ("token_expiry", True),
    ("token_expiry", "999999999999"), ("token_expiry", float("nan")),
    ("token_expiry", float("inf")), ("token_expiry", 10 ** 400),
])
@pytest.mark.parametrize("method,path,body", [
    ("GET", "/vms", None), ("POST", "/vms/2/return", LEASE),
])
def test_malformed_or_missing_sessions_fail_before_upstream(
        signed_in_client, broker_api, key, value, method, path, body):
    token = csrf_token(signed_in_client)
    with signed_in_client.session_transaction() as session:
        if value is None:
            session.pop(key, None)
        else:
            session[key] = value
    broker_api.gets.clear()

    response = call_route(signed_in_client, method, path, body, token)
    assert response.status_code == 401
    assert response.get_json()["code"] == "session_expired"
    assert broker_api.gets == []
    assert broker_api.posts == []


def test_expired_bootstrap_reports_expiry_then_signed_out_without_a_capability_call(signed_in_client, broker_api):
    with signed_in_client.session_transaction() as session:
        session["token_expiry"] = time() - 1
    response = signed_in_client.get(f"{API}/session")
    assert response.status_code == 401
    assert response.get_json()["code"] == "session_expired"
    signed_out = signed_in_client.get(f"{API}/session").get_json()
    assert signed_out["authenticated"] is False
    assert signed_out["capabilities"] == {"manage": False, "connect": False}
    assert signed_out["subject"] is None
    assert broker_api.gets == []


@pytest.mark.parametrize("field", ["tenantId", "objectId"])
@pytest.mark.parametrize("path", ["/session", "/dashboard"])
def test_capability_subject_must_match_authenticated_subject(signed_in_client, broker_api, field, path):
    broker_api.capability_response["subject"][field] = "99999999-9999-4999-8999-999999999999"
    response = signed_in_client.get(f"{API}{path}")
    assert response.status_code == 401
    assert "99999999" not in response.get_data(as_text=True)
    assert_only_capability_calls(broker_api)
    with signed_in_client.session_transaction() as session:
        assert "access_token" not in session


@pytest.mark.parametrize("payload", [
    None, [], {}, {"subject": SUBJECT},
    {"subject": SUBJECT, "capabilities": {"manage": "true", "connect": False}},
    {"subject": SUBJECT, "capabilities": {"manage": 1, "connect": False}},
    {"subject": SUBJECT, "capabilities": {"manage": True}},
    {"subject": {"tenantId": None, "objectId": SUBJECT["objectId"]},
     "capabilities": {"manage": True, "connect": False}},
])
def test_invalid_capability_response_never_defaults_to_authorized(signed_in_client, broker_api, payload):
    broker_api.capability_response = payload
    response = signed_in_client.get(f"{API}/dashboard")
    assert response.status_code == 503
    assert response.get_json()["code"] == "authorization_unavailable"
    assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("status,expected", [(401, 401), (403, 403), (302, 503), (404, 503),
                                           (429, 503), (500, 503), (503, 503)])
@pytest.mark.parametrize("path", ["/session", "/dashboard"])
def test_capability_http_errors_are_distinct_and_do_not_leak_details(
        signed_in_client, broker_api, status, expected, path, caplog):
    broker_api.capability_response = {"error": "PRIVATE_RESPONSE_SECRET"}
    broker_api.capability_status = status
    response = signed_in_client.get(f"{API}{path}")
    assert response.status_code == expected
    assert "PRIVATE_RESPONSE_SECRET" not in response.get_data(as_text=True)
    assert "PRIVATE_RESPONSE_SECRET" not in caplog.text
    assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("method,path,body", BUSINESS_ROUTES)
def test_capability_outage_blocks_all_business_calls(signed_in_client, broker_api, method, path, body):
    token = csrf_token(signed_in_client)
    broker_api.raise_get_paths.add("/me")
    broker_api.gets.clear()
    response = call_route(signed_in_client, method, path, body, token)
    assert response.status_code == 503
    assert response.get_json()["code"] == "authorization_unavailable"
    assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("failure", [requests.exceptions.Timeout, ValueError])
def test_capability_transport_and_json_errors_are_sanitized(
        signed_in_client, broker_api, monkeypatch, failure, caplog):
    def unavailable(url, **kwargs):
        raise failure("PRIVATE_RESPONSE_SECRET")

    monkeypatch.setattr(requests, "get", unavailable)
    response = signed_in_client.get(f"{API}/session")
    assert response.status_code == 503
    assert "PRIVATE_RESPONSE_SECRET" not in response.get_data(as_text=True)
    assert "PRIVATE_RESPONSE_SECRET" not in caplog.text
    assert broker_api.posts == []


def test_token_cannot_expire_during_the_capability_check(signed_in_client, broker_api, monkeypatch):
    from flask import session

    def slow_capabilities(url, **kwargs):
        session["token_expiry"] = time() - 1
        return broker_api.get(url, **kwargs)

    monkeypatch.setattr(requests, "get", slow_capabilities)
    assert signed_in_client.get(f"{API}/dashboard").status_code == 401
    assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("status", [401, 403])
@pytest.mark.parametrize("path,upstream", [
    ("/dashboard", "/vms/summary"),
    ("/dashboard", "/scaling/log"),
    ("/hosts/settings", "/vms"),
])
def test_secondary_panels_and_summary_fallback_do_not_hide_authorization_loss(
        signed_in_client, broker_api, monkeypatch, status, path, upstream):
    def get(url, **kwargs):
        if url.endswith(upstream):
            return FakeResponse({"error": "PRIVATE_RESPONSE_SECRET"}, status)
        return broker_api.get(url, **kwargs)

    def post(url, **kwargs):
        if url.endswith(upstream):
            return FakeResponse({"error": "PRIVATE_RESPONSE_SECRET"}, status)
        return broker_api.post(url, **kwargs)

    monkeypatch.setattr(requests, "get", get)
    monkeypatch.setattr(requests, "post", post)
    response = signed_in_client.get(f"{API}{path}")
    assert response.status_code == status
    assert "PRIVATE_RESPONSE_SECRET" not in response.get_data(as_text=True)
    if upstream == "/vms/summary":
        assert_only_capability_calls(broker_api)


@pytest.mark.parametrize("path", ["/vms/linux-host-02/release", "/vms/2/return"])
@pytest.mark.parametrize("guard", [
    {}, {"leaseId": LEASE["leaseId"]}, {"leaseGeneration": 7},
    {"leaseId": None, "leaseGeneration": 7},
    {"leaseId": "not-a-lease", "leaseGeneration": 7},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": "7"},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": True},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": -1},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": 0},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": 7.1},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": "9007199254740991"},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": 9007199254740992},
    {"leaseId": LEASE["leaseId"], "leaseGeneration": 9223372036854775807},
    {**LEASE, "username": "another-user"},
    {**LEASE, "targetObjectId": SUBJECT["objectId"]},
])
def test_lease_mutations_require_real_guards(signed_in_client, broker_api, path, guard):
    token = csrf_token(signed_in_client)
    response = call_route(signed_in_client, "POST", path, guard, token)
    assert response.status_code == 400
    assert broker_api.posts == []


@pytest.mark.parametrize("path", ["/vms/linux-host-02/release", "/vms/2/return"])
@pytest.mark.parametrize("generation", [1, 7, 9007199254740991])
def test_lease_generations_preserve_exact_safe_json_integers(signed_in_client, broker_api, path, generation):
    token = csrf_token(signed_in_client)
    guard = {"leaseId": LEASE["leaseId"], "leaseGeneration": generation}
    response = call_route(signed_in_client, "POST", path, guard, token)
    assert response.status_code == 200
    assert len(broker_api.posts) == 1
    assert broker_api.posts[0]["json"] == guard
    assert type(broker_api.posts[0]["json"]["leaseGeneration"]) is int


@pytest.mark.parametrize("path", ["/vms/linux-host-02/release", "/vms/2/return"])
def test_stale_lease_is_a_safe_actionable_409(signed_in_client, monkeypatch, path):
    token = csrf_token(signed_in_client)
    monkeypatch.setattr(requests, "post", lambda *args, **kwargs: FakeResponse(
        {"error": "PRIVATE_LEASE_DETAILS"}, 409))
    response = call_route(signed_in_client, "POST", path, LEASE, token)
    assert response.status_code == 409
    assert "Refresh the VM" in response.get_json()["error"]
    assert "PRIVATE_LEASE_DETAILS" not in response.get_data(as_text=True)


@pytest.mark.parametrize("extra", [
    {"username": "victim"}, {"avdhost": "avd-host"}, {"leaseId": LEASE["leaseId"]},
    {"tenantId": SUBJECT["tenantId"]}, {"objectId": SUBJECT["objectId"]},
    {"vmstatus": "CheckedOut"}, {"vmstatus": "Released"},
])
def test_add_vm_cannot_create_assignments(signed_in_client, broker_api, extra):
    token = csrf_token(signed_in_client)
    response = call_route(signed_in_client, "POST", "/vms", {**NEW_VM, **extra}, token)
    assert response.status_code == 400
    assert broker_api.posts == []


@pytest.mark.parametrize("extra", [
    {"username": "another-user"}, {"leaseId": LEASE["leaseId"]},
    {"vmstatus": "CheckedOut"}, {"vmstatus": "Released"},
])
def test_attribute_updates_cannot_forge_or_change_assignments(signed_in_client, broker_api, extra):
    token = csrf_token(signed_in_client)
    payload = {"powerstate": "On", "networkstatus": "Reachable", "vmstatus": "Available", **extra}
    response = call_route(signed_in_client, "POST", "/vms/1/update-attributes", payload, token)
    assert response.status_code == 400
    assert broker_api.posts == []


@pytest.mark.parametrize("method,path", [
    ("GET", "/vms/checkout"), ("POST", "/vms/checkout"),
    ("POST", "/vms/checkout/return"), ("POST", "/vms/checkout/release"),
    ("POST", "/vms/checkout/update-attributes"), ("POST", "/vms/checkout/delete"),
])
def test_legacy_checkout_is_not_a_proxy_or_an_admin_vm_mutation(
        signed_in_client, broker_api, method, path):
    token = csrf_token(signed_in_client)
    response = call_route(signed_in_client, method, path, LEASE, token)
    assert response.status_code in (404, 405)
    assert broker_api.posts == []


@pytest.fixture
def msal_result(monkeypatch):
    result = {
        "id_token_claims": {
            "name": "Test Operator", "preferred_username": "op@contoso.com",
            "tid": SUBJECT["tenantId"], "oid": SUBJECT["objectId"], "roles": ["WorkspaceUser"],
        },
        "access_token": "opaque-api-token", "expires_in": 3600,
    }
    msal_app = SimpleNamespace(acquire_token_by_authorization_code=lambda **kwargs: result)
    monkeypatch.setattr("route_authentication.ConfidentialClientApplication", lambda *args, **kwargs: msal_app)
    return result


def test_login_callback_checks_capability_and_uses_real_epoch_expiry(
        client, broker_api, msal_result, spa_bundle):
    before = time()
    response = client.get("/getAToken?code=test-code")
    assert response.status_code == 302
    assert_only_capability_calls(broker_api)
    with client.session_transaction() as session:
        assert before + 3600 <= session["token_expiry"] <= time() + 3600


def test_login_callback_denies_non_admin_without_losing_sign_out(
        client, broker_api, msal_result, spa_bundle):
    broker_api.capability_response["capabilities"]["manage"] = False
    response = client.get("/getAToken?code=test-code")
    assert response.status_code == 403
    assert "Location" not in response.headers
    assert client.get(f"{API}/session").get_json()["authenticated"] is True
    assert client.get("/logout").status_code == 302
    with client.session_transaction() as session:
        assert "access_token" not in session


def test_login_callback_fails_closed_on_capability_outage(client, broker_api, msal_result, spa_bundle):
    broker_api.raise_get_paths.add("/me")
    assert client.get("/getAToken?code=test-code").status_code == 503
    assert client.get(f"{API}/session").status_code == 503
    assert_only_capability_calls(broker_api)


def test_login_errors_do_not_echo_msal_details(client, msal_result, caplog):
    msal_result.update(error="access_denied", error_description="PRIVATE_TOKEN_DETAILS")
    response = client.get("/getAToken?code=test-code")
    assert response.status_code == 401
    assert "PRIVATE_TOKEN_DETAILS" not in response.get_data(as_text=True)
    assert "PRIVATE_TOKEN_DETAILS" not in caplog.text
