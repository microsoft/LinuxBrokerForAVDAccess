import json
import subprocess
from types import SimpleNamespace

import pytest

from conftest import API_ID, LAUNCHER, LEASE, OPERATION, OTHER, PORTAL, SUBJECT, TENANT


GUARDS = {"leaseId": LEASE, "leaseGeneration": 7}
RULE = {"minvms": 1, "maxvms": 5, "scaleupratio": 80, "scaleupincrement": 1, "scaledownratio": 20, "scaledownincrement": 1}
ROUTES = [
    ("GET", "/api/me", "capabilities", {}),
    ("GET", "/api/vms", "inventory", {}),
    ("GET", "/api/vms/summary", "manage", {}),
    ("POST", "/api/vms/checkout", "connect", {"avdhost": "avd-01"}),
    ("POST", "/api/vms/1/update-attributes", "maintenance", {"networkstatus": "Reachable"}),
    ("POST", "/api/vms/1/delete", "manage", {}),
    ("POST", "/api/vms/add", "manage", {"hostname": "linux-02", "ipaddress": "192.0.2.2", "powerstate": "On", "networkstatus": "Reachable", "vmstatus": "Available"}),
    ("GET", "/api/vms/1", "manage", {}),
    ("POST", "/api/vms/1/return", "manage", GUARDS),
    ("POST", "/api/vms/linux-01/release", "manage", GUARDS),
    ("POST", "/api/vms/linux-01/session", "host", {**GUARDS, "state": "active"}),
    ("POST", "/api/vms/released", "maintenance", {}),
    ("POST", "/api/vms/history", "manage", {}),
    ("POST", "/api/scaling/log", "manage", {}),
    ("POST", "/api/scaling/trigger", "maintenance", {}),
    ("GET", "/api/scaling/rules", "manage", {}),
    ("GET", "/api/scaling/rules/1", "manage", {}),
    ("POST", "/api/scaling/rules/create", "manage", RULE),
    ("POST", "/api/scaling/rules/1/update", "manage", RULE),
    ("POST", "/api/scaling/rules/1/delete", "manage", {}),
    ("POST", "/api/scaling/rules/history", "manage", {}),
    ("GET", "/api/hosts/settings", "host_settings", {}),
    ("POST", "/api/hosts/settings/update", "manage", {"GracePeriodSeconds": 900}),
    ("POST", "/api/hosts/settings/apply", "manage", {}),
    ("POST", "/api/hosts/linux-01/settings/ack", "host", {"settingsVersion": 1}),
]
ALLOWED = {
    "capabilities": {"admin", "workspace", "scope_only", "unassigned", "user_host", "user_task"},
    "manage": {"admin"}, "connect": {"workspace"}, "inventory": {"admin", "task"},
    "maintenance": {"admin", "task"}, "host_settings": {"admin", "host"}, "host": {"host"},
}


def headers(value):
    return {"Authorization": f"Bearer {value}"}


def assert_no_effects(boundary):
    assert boundary.calls == []
    assert boundary.ssh == []
    assert boundary.power == []
    assert boundary.connections == []


def test_every_route_has_an_explicit_tested_policy(api_module):
    adapter = api_module.app.url_map.bind("localhost")
    tested = set()
    for method, path, policy, _body in ROUTES:
        endpoint, _ = adapter.match(path, method=method)
        assert api_module.app.view_functions[endpoint].authorization_policy.value == policy
        tested.add(endpoint)
    actual = {
        rule.endpoint for rule in api_module.app.url_map.iter_rules()
        if rule.rule.startswith("/api/") and rule.rule != "/api/version"
    }
    assert actual == tested


@pytest.mark.parametrize("method,path,policy,body", ROUTES)
@pytest.mark.parametrize("kind", ["workspace", "admin", "host", "task", "avd", "group", "scope_only", "unassigned", "user_host", "user_task", "app_admin"])
def test_signed_principal_route_matrix(client, boundary, token, method, path, policy, body, kind):
    response = client.open(path, method=method, headers=headers(token(kind)), json=body)
    if kind in ALLOWED[policy]:
        assert response.status_code in (200, 201), response.get_data(as_text=True)
    else:
        assert response.status_code == 403
        assert_no_effects(boundary)
    assert response.headers["Cache-Control"] == "no-store"
    assert all(connection.closed for connection in boundary.connections)


@pytest.mark.parametrize("method,path,policy,body", ROUTES)
def test_missing_tokens_never_enter_any_business_route(client, boundary, method, path, policy, body):
    assert client.open(path, method=method, json=body).status_code == 401
    assert_no_effects(boundary)


@pytest.mark.parametrize("authorization", ["", "Basic x", "Bearer", "Bearer one two"])
def test_malformed_bearer_header(client, boundary, authorization):
    assert client.post("/api/vms/checkout", headers={"Authorization": authorization}, json={"avdhost": "avd-01"}).status_code == 401
    assert_no_effects(boundary)


@pytest.mark.parametrize("changes,remove,extra", [
    ({}, (), {"foreign_key": True}),
    ({}, (), {"kid": "unknown"}),
    ({}, (), {"algorithm": "HS256"}),
    ({"aud": OTHER}, (), {}),
    ({"aud": [API_ID]}, (), {}),
    ({"iss": "https://issuer.example.invalid"}, (), {}),
    ({"tid": OTHER}, (), {}),
    ({"exp": 1}, (), {}),
    ({"nbf": 4102444800}, (), {}),
    ({"iat": 4102444800}, (), {}),
    ({}, ("oid",), {}),
    ({}, ("tid",), {}),
    ({}, ("sub",), {}),
    ({}, ("exp",), {}),
    ({}, ("iat",), {}),
    ({}, ("nbf",), {}),
    ({}, ("ver",), {}),
    ({}, ("azp",), {}),
    ({"oid": []}, (), {}),
    ({"oid": "not-a-guid"}, (), {}),
    ({"oid": "00000000-0000-0000-0000-000000000000"}, (), {}),
    ({"tid": 1}, (), {}),
    ({"sub": {}}, (), {}),
    ({"sub": ""}, (), {}),
    ({"roles": "WorkspaceUser"}, (), {}),
    ({"roles": [3]}, (), {}),
    ({"scp": ["connect_as_user"]}, (), {}),
    ({"scp": ""}, (), {}),
    ({"azp": [LAUNCHER]}, (), {}),
    ({"appid": OTHER}, (), {}),
    ({"idtyp": "app"}, (), {}),
    ({"idtyp": 1}, (), {}),
    ({"exp": "4102444800"}, (), {}),
    ({"iat": True}, (), {}),
    ({"nbf": 1.5}, (), {}),
    ({"ver": "3.0"}, (), {}),
])
def test_real_signature_and_required_claim_validation(client, boundary, token, changes, remove, extra):
    response = client.post("/api/vms/checkout", headers=headers(token(changes=changes, remove=remove, **extra)), json={"avdhost": "avd-01"})
    assert response.status_code == 401
    assert_no_effects(boundary)


@pytest.mark.parametrize("kind,changes,remove,path", [
    ("workspace", {"azp": PORTAL}, (), "/api/vms/checkout"),
    ("workspace", {"azp": OTHER}, (), "/api/vms/checkout"),
    ("workspace", {}, ("roles",), "/api/vms/checkout"),
    ("workspace", {"scp": "access_as_user"}, (), "/api/vms/checkout"),
    ("workspace", {}, ("scp",), "/api/vms/checkout"),
    ("admin", {"azp": LAUNCHER}, (), "/api/vms"),
    ("admin", {"roles": ["FullAccess", "WorkspaceUser"]}, (), "/api/vms/checkout"),
    ("admin", {}, ("scp",), "/api/vms"),
    ("host", {}, ("idtyp",), "/api/hosts/settings"),
    ("host", {"scp": "access_as_user", "azp": PORTAL}, (), "/api/hosts/settings"),
    ("task", {"idtyp": "user"}, (), "/api/vms/released"),
])
def test_role_scope_client_and_principal_type_are_all_required(client, boundary, token, kind, changes, remove, path):
    method = "GET" if path in ("/api/vms", "/api/hosts/settings") else "POST"
    response = client.open(path, method=method, headers=headers(token(kind, changes=changes, remove=remove)), json={"avdhost": "avd-01"})
    assert response.status_code in (401, 403)
    assert_no_effects(boundary)


@pytest.mark.parametrize("kind,manage,connect", [("admin", True, False), ("workspace", False, True), ("scope_only", False, False)])
def test_exact_capability_contract(client, boundary, token, kind, manage, connect):
    response = client.get("/api/me", headers=headers(token(kind)))
    assert response.status_code == 200
    assert response.get_json() == {
        "subject": {"tenantId": TENANT, "objectId": SUBJECT},
        "capabilities": {"manage": manage, "connect": connect},
    }
    assert_no_effects(boundary)


@pytest.mark.parametrize("version,issuer", [
    ("1.0", f"https://sts.windows.net/{TENANT}/"),
    ("1.0", f"https://login.microsoftonline.com/{TENANT}/"),
    ("2.0", f"https://login.microsoftonline.com/{TENANT}/v2.0"),
])
def test_supported_issuer_and_client_claim_shapes(client, token, version, issuer):
    changes = {"ver": version, "iss": issuer}
    if version == "1.0":
        changes["appid"] = LAUNCHER
    response = client.get("/api/me", headers=headers(token(changes=changes, remove=("azp",) if version == "1.0" else ())))
    assert response.status_code == 200
    assert response.get_json()["capabilities"]["connect"]


@pytest.mark.parametrize("profile_state", ["existing_active", "existing_inactive", "never_assigned"])
@pytest.mark.parametrize("field", ["username", "targetObjectId", "tenantId", "objectId", "uid", "leaseId", "leaseGeneration", "Username", "target", "user"])
def test_all_target_overrides_fail_before_identity_allocation(client, boundary, token, field, profile_state):
    boundary.rows["VictimProfileState"] = profile_state
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01", field: "victim"})
    assert response.status_code == 400
    assert_no_effects(boundary)


@pytest.mark.parametrize("body", [None, [], "username", {}, {"avdhost": []}, {"avdhost": "-injected"}, {"avdhost": "host\ninjected"}])
def test_checkout_rejects_malformed_input_before_effects(client, boundary, token, body):
    assert client.post("/api/vms/checkout", headers=headers(token()), json=body).status_code == 400
    assert_no_effects(boundary)


def test_checkout_uses_only_verified_subject_and_returns_server_identity(client, boundary, token, caplog):
    caplog.set_level("INFO", logger="linuxbroker.api")
    bearer = token(changes={"preferred_username": "renamed@example.invalid"})
    response = client.post("/api/vms/checkout", headers=headers(bearer), json={"avdhost": "avd-01"})
    assert response.status_code == 200
    body = response.get_json()
    assert set(body) == {"VMID", "Hostname", "IPAddress", "Username", "LeaseId", "LeaseGeneration", "password"}
    assert body["Username"] == "preserved_profile"
    assert body["LeaseId"] == LEASE
    assert body["LeaseGeneration"] == 7
    assert boundary.calls[0] == ("BeginBrokerCheckout", {"TenantId": TENANT, "ObjectId": SUBJECT, "AvdHost": "avd-01"})
    assert len(boundary.ssh) == 1
    assert "2042 preserved_profile" in boundary.ssh[0][1]
    assert body["password"] not in boundary.ssh[0][1]
    assert boundary.ssh[0][2] == body["password"] + "\n"
    assert body["password"] not in caplog.text
    assert bearer not in caplog.text
    assert boundary.events == [("sql", "BeginBrokerCheckout"), ("ssh", "linux-01"), ("sql", "CompleteBrokerOperation")]


def test_checkout_pause_does_not_weaken_policy_or_allocate(client, boundary, token, api_module, monkeypatch):
    monkeypatch.setattr(api_module, "BROKER_CHECKOUT_ENABLED", False)
    assert client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"}).status_code == 503
    assert client.post("/api/vms/checkout", headers=headers(token("avd")), json={"avdhost": "avd-01"}).status_code == 403
    assert_no_effects(boundary)


@pytest.mark.parametrize("new_allocation", [True, False])
@pytest.mark.parametrize("failure", ["exit", "timeout", "bad_ack"])
def test_failed_provision_or_rotation_never_returns_assignment(client, boundary, token, api_module, monkeypatch, caplog, new_allocation, failure):
    caplog.set_level("INFO", logger="linuxbroker.api")
    boundary.rows["BeginBrokerCheckout"]["NewAllocation"] = new_allocation
    secret = "a-secret-that-must-never-be-logged"
    monkeypatch.setattr(api_module, "generate_secure_password", lambda: secret)

    def uncertain(*args, **kwargs):
        if failure == "timeout":
            raise subprocess.TimeoutExpired("ssh", 120, output=secret)
        return SimpleNamespace(returncode=1 if failure == "exit" else 0, stdout=secret, stderr=secret), "linux-01"

    monkeypatch.setattr(api_module, "run_remote_command", uncertain)
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert response.get_json()["retryable"]
    assert [name for name, _ in boundary.calls] == ["BeginBrokerCheckout", "FailBrokerOperation"]
    assert secret not in caplog.text + response.get_data(as_text=True)
    assert "password" not in response.get_json()


@pytest.mark.parametrize("path", ["/api/vms/linux-02/session", "/api/hosts/linux-02/settings/ack"])
def test_workload_host_binding_precedes_mutations(client, boundary, token, path):
    response = client.post(path, headers=headers(token("host")), json={**GUARDS, "state": "active"})
    assert response.status_code == 403
    assert [name for name, _ in boundary.calls] == ["GetBrokerHost"]
    assert boundary.ssh == []
    assert LEASE not in response.get_data(as_text=True)


def test_unregistered_linux_identity_cannot_read_global_settings(client, boundary, token):
    boundary.rows["GetBrokerHost"] = None
    assert client.get("/api/hosts/settings", headers=headers(token("host"))).status_code == 403
    assert [name for name, _ in boundary.calls] == ["GetBrokerHost"]


@pytest.mark.parametrize("path,kind", [("/api/vms/1/return", "admin"), ("/api/vms/linux-01/release", "admin"), ("/api/vms/linux-01/session", "host")])
@pytest.mark.parametrize("guard", [{}, {"leaseId": LEASE}, {"leaseGeneration": 7}, {**GUARDS, "leaseGeneration": True}, {**GUARDS, "leaseGeneration": "7"}, {**GUARDS, "leaseGeneration": 0}, {**GUARDS, "username": "victim"}])
def test_lifecycle_requires_exact_typed_guards(client, boundary, token, path, kind, guard):
    body = {**guard, "state": "active"} if kind == "host" else guard
    assert client.post(path, headers=headers(token(kind)), json=body).status_code == 400
    assert all(name == "GetBrokerHost" for name, _ in boundary.calls)
    assert boundary.ssh == []


@pytest.mark.parametrize("path,kind,procedure", [
    ("/api/vms/1/return", "admin", "BeginBrokerCleanup"),
    ("/api/vms/linux-01/release", "admin", "ObserveBrokerSession"),
    ("/api/vms/linux-01/session", "host", "ObserveBrokerSession"),
])
def test_stale_lease_never_discloses_current_assignment(client, boundary, token, path, kind, procedure):
    boundary.rows[procedure] = {"Outcome": "Conflict", "LeaseId": OTHER, "Username": "victim", "LeaseGeneration": 999}
    body = {**GUARDS, "state": "active"} if kind == "host" else GUARDS
    response = client.post(path, headers=headers(token(kind)), json=body)
    assert response.status_code == 409
    assert OTHER not in response.get_data(as_text=True)
    assert "victim" not in response.get_data(as_text=True)
    assert "999" not in response.get_data(as_text=True)
    assert not boundary.ssh


def test_automatic_reconnect_reports_active_without_rotating_credentials(client, boundary, token):
    response = client.post("/api/vms/linux-01/session", headers=headers(token("host")), json={**GUARDS, "state": "active"})
    assert response.status_code == 200
    assert [name for name, _ in boundary.calls] == ["GetBrokerHost", "ObserveBrokerSession"]
    assert boundary.calls[-1][1]["State"] == "active"
    assert boundary.ssh == []


def test_initial_disconnect_does_not_run_host_cleanup(client, boundary, token):
    response = client.post("/api/vms/linux-01/session", headers=headers(token("host")), json={**GUARDS, "state": "disconnected"})
    assert response.status_code == 200
    assert boundary.ssh == []


def test_cleanup_finishes_only_after_matching_host_acknowledgement(client, boundary, token):
    response = client.post("/api/vms/1/return", headers=headers(token("admin")), json=GUARDS)
    assert response.status_code == 200
    assert response.get_json() == {"status": "cleaned"}
    assert boundary.events == [("sql", "BeginBrokerCleanup"), ("ssh", "linux-01"), ("sql", "CompleteBrokerOperation")]
    assert boundary.calls[-1][1]["LeaseGeneration"] == 8


def test_unreachable_cleanup_stays_explicitly_retryable(client, boundary, token, api_module, monkeypatch):
    def unreachable(*_args, **_kwargs):
        raise subprocess.TimeoutExpired("ssh", 120)
    monkeypatch.setattr(api_module, "run_remote_command", unreachable)
    response = client.post("/api/vms/1/return", headers=headers(token("admin")), json=GUARDS)
    assert response.status_code == 503
    assert response.get_json()["retryable"]
    assert [name for name, _ in boundary.calls] == ["BeginBrokerCleanup", "FailBrokerOperation"]


@pytest.mark.parametrize("path,payload", [
    ("/api/vms/add", {"hostname": "h", "username": "victim"}),
    ("/api/vms/add", {"hostname": "h", "OwnerObjectId": OTHER}),
    ("/api/vms/1/update-attributes", {"username": "victim"}),
    ("/api/vms/1/update-attributes", {"leaseId": LEASE}),
    ("/api/vms/1/update-attributes", {"vmstatus": "CheckedOut"}),
    ("/api/vms/1/update-attributes", {"ipaddress": "203.0.113.77"}),
])
def test_management_cannot_forge_assignments(client, boundary, token, path, payload):
    assert client.post(path, headers=headers(token("admin")), json=payload).status_code == 400
    assert_no_effects(boundary)


def test_scheduled_inventory_excludes_lease_and_user_metadata(client, boundary, token):
    response = client.get("/api/vms", headers=headers(token("task")))
    assert response.status_code == 200
    assert set(response.get_json()[0]) == {"VMID", "Hostname", "IPAddress", "PowerState", "NetworkStatus"}


@pytest.mark.parametrize("payload", [{"powerstate": "On"}, {"vmstatus": "Available"}, {"networkstatus": "Reachable", "powerstate": "Off"}])
def test_scheduled_attribute_updates_only_allow_actual_reachability_operation(client, boundary, token, payload):
    assert client.post("/api/vms/1/update-attributes", headers=headers(token("task")), json=payload).status_code == 403
    assert_no_effects(boundary)


@pytest.mark.parametrize("action,outcome", [("PowerOn", "On"), ("PowerOff", "Off")])
def test_power_operations_use_guarded_completion(client, boundary, token, action, outcome):
    boundary.rows["TriggerScalingLogic"] = [{"VMID": 1, "VMName": "linux-01", "ActionType": action, "OperationId": OPERATION, "LeaseGeneration": 9}]
    response = client.post("/api/scaling/trigger", headers=headers(token("task")), json={})
    assert response.status_code == 200
    assert boundary.calls[-1] == ("CompleteBrokerOperation", {"VMID": 1, "OperationId": OPERATION, "LeaseGeneration": 9, "Outcome": outcome})


def test_settings_actor_cannot_be_supplied_by_client(client, boundary, token):
    response = client.post("/api/hosts/settings/update", headers=headers(token("admin")), json={"GracePeriodSeconds": 900, "updatedBy": "victim"})
    assert response.status_code == 400
    assert_no_effects(boundary)


@pytest.mark.parametrize("query", ["username=victim", "targetObjectId=" + OTHER, "leaseId=" + OTHER])
def test_query_string_target_overrides_are_rejected(client, boundary, token, query):
    response = client.post("/api/vms/checkout?" + query, headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 400
    assert_no_effects(boundary)


def test_jwks_outage_is_not_authorization_success(client, boundary, token, monkeypatch):
    import authorization

    def unavailable(*_args, **_kwargs):
        raise authorization.requests.Timeout("test-only timeout")

    monkeypatch.setattr(authorization.requests, "get", unavailable)
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert_no_effects(boundary)


def test_malformed_signing_key_document_is_dependency_failure(client, boundary, token, monkeypatch):
    import authorization
    monkeypatch.setattr(authorization.requests, "get", lambda *_args, **_kwargs: SimpleNamespace(
        raise_for_status=lambda: None,
        json=lambda: {"keys": [{"kid": "local-rsa", "use": "sig", "kty": "RSA", "n": "broken", "e": []}]},
    ))
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert_no_effects(boundary)


def test_malformed_jwks_json_is_unavailable_without_token_refresh_or_secret_disclosure(client, boundary, token, monkeypatch, caplog):
    import authorization
    caplog.set_level("INFO", logger="linuxbroker.api")
    private_detail = "sensitive-upstream-response-body"

    def malformed_document():
        raise ValueError(private_detail)

    monkeypatch.setattr(authorization.requests, "get", lambda *_args, **_kwargs: SimpleNamespace(
        raise_for_status=lambda: None, json=malformed_document,
    ))
    bearer = token()
    response = client.post("/api/vms/checkout", headers=headers(bearer), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert response.get_json() == {"error": "Authentication is temporarily unavailable."}
    assert response.headers["Cache-Control"] == "no-store"
    assert private_detail not in response.get_data(as_text=True) + caplog.text
    assert bearer not in response.get_data(as_text=True) + caplog.text
    assert_no_effects(boundary)


@pytest.mark.parametrize("bearer", ["invalid.jwt.header", "bm90LWpzb24.e30.c2ln"])
def test_malformed_jwt_header_remains_401_without_requesting_jwks(client, boundary, monkeypatch, bearer):
    import authorization

    def must_not_fetch(*_args, **_kwargs):
        raise AssertionError("Malformed JWT headers must fail before signing-key retrieval.")

    monkeypatch.setattr(authorization.requests, "get", must_not_fetch)
    response = client.post("/api/vms/checkout", headers=headers(bearer), json={"avdhost": "avd-01"})
    assert response.status_code == 401
    assert_no_effects(boundary)


@pytest.mark.parametrize("outcome", ["active", "disconnected"])
def test_actual_host_state_cancels_expiry_without_making_available(client, boundary, token, api_module, monkeypatch, outcome):
    boundary.rows["ReturnReleasedVms"] = [{"VMID": 1, **{"LeaseId": LEASE, "LeaseGeneration": 7}, "Reason": "expired"}]
    boundary.rows["BeginBrokerCleanup"]["Reason"] = "expired"
    monkeypatch.setattr(api_module, "run_remote_command", lambda *_args, **_kwargs: (
        SimpleNamespace(returncode=0, stderr="", stdout=json.dumps({
            "outcome": outcome, "leaseId": LEASE, "leaseGeneration": 8, "operationId": OPERATION,
        })), "linux-01",
    ))
    response = client.post("/api/vms/released", headers=headers(token("task")))
    assert response.status_code == 200
    assert response.get_json()["results"] == [{"VMID": 1, "status": outcome}]
    assert boundary.calls[-1][1]["Outcome"] == outcome


def test_power_uncertainty_retains_durable_guard(client, boundary, token, api_module, monkeypatch):
    boundary.rows["TriggerScalingLogic"] = [{"VMID": 1, "VMName": "linux-01", "ActionType": "PowerOn", "OperationId": OPERATION, "LeaseGeneration": 9}]
    poller = SimpleNamespace(result=lambda **_kwargs: None, done=lambda: False)
    monkeypatch.setattr(api_module, "ComputeManagementClient", lambda **_kwargs: SimpleNamespace(
        virtual_machines=SimpleNamespace(begin_start=lambda *_args: poller),
    ))
    response = client.post("/api/scaling/trigger", headers=headers(token("task")), json={})
    assert response.status_code == 503
    assert response.get_json()["RetryRequiredVMs"] == ["linux-01"]
    assert [name for name, _ in boundary.calls] == ["TriggerScalingLogic", "FailBrokerOperation"]


def test_settings_update_audit_uses_verified_actor(client, boundary, token):
    response = client.post("/api/hosts/settings/update", headers=headers(token("admin")), json={"GracePeriodSeconds": 900})
    assert response.status_code == 200
    assert boundary.calls[-1][1]["UpdatedBy"] == f"{TENANT}/{SUBJECT}"


def test_api_uri_audience_remains_supported(client, boundary, token):
    response = client.get("/api/me", headers=headers(token(changes={"aud": f"api://{API_ID}"})))
    assert response.status_code == 200
    assert response.get_json()["capabilities"]["connect"]
    assert_no_effects(boundary)


def test_sovereign_authority_is_pinned_to_configured_cloud(client, boundary, token, monkeypatch):
    import authorization
    authority = "https://login.microsoftonline.us"
    monkeypatch.setattr(authorization.config, "AUTHORITY_HOST", authority)
    valid = token(changes={"iss": f"{authority}/{TENANT}/v2.0"})
    assert client.get("/api/me", headers=headers(valid)).status_code == 200
    assert client.get("/api/me", headers=headers(token())).status_code == 401
    assert_no_effects(boundary)


@pytest.mark.parametrize("generation", [2147483648, 9007199254740990, 9007199254740991])
def test_checkout_preserves_exact_json_safe_int64_generations(client, boundary, token, generation):
    boundary.rows["BeginBrokerCheckout"]["LeaseGeneration"] = generation
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 200
    assert response.get_json()["LeaseGeneration"] == generation
    assert str(generation) in response.get_data(as_text=True)


@pytest.mark.parametrize("generation", [9007199254740992, 9007199254740993, 9223372036854775807])
@pytest.mark.parametrize("path,kind", [
    ("/api/vms/1/return", "admin"),
    ("/api/vms/linux-01/release", "admin"),
    ("/api/vms/linux-01/session", "host"),
])
def test_unsafe_json_generations_are_denied_before_lease_mutation(client, boundary, token, generation, path, kind):
    payload = {**GUARDS, "leaseGeneration": generation}
    if kind == "host":
        payload["state"] = "active"
    response = client.post(path, headers=headers(token(kind)), json=payload)
    assert response.status_code == 400
    assert all(name == "GetBrokerHost" for name, _ in boundary.calls)
    assert boundary.ssh == []


def test_unsafe_stored_generation_cannot_rotate_a_password(client, boundary, token):
    boundary.rows["BeginBrokerCheckout"]["LeaseGeneration"] = 9007199254740992
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert boundary.ssh == []
    assert [name for name, _ in boundary.calls] == ["BeginBrokerCheckout", "FailBrokerOperation"]
    assert "password" not in response.get_json()


def test_inventory_never_serializes_an_unsafe_stored_generation(client, boundary, token):
    boundary.rows["GetVms"][0]["LeaseGeneration"] = 9007199254740992
    response = client.get("/api/vms", headers=headers(token("admin")))
    assert response.status_code == 500
    assert "9007199254740992" not in response.get_data(as_text=True)


def workload_version(version):
    if version == "1.0":
        return {"ver": version, "appid": OTHER, "iss": f"https://sts.windows.net/{TENANT}/"}, ("azp",)
    return {"ver": version}, ()


WORKLOAD_ROUTES = [
    ("host", "GET", "/api/hosts/settings", {}),
    ("host", "POST", "/api/vms/linux-01/session", {**GUARDS, "state": "active"}),
    ("host", "POST", "/api/hosts/linux-01/settings/ack", {"settingsVersion": 1}),
    ("task", "GET", "/api/vms", {}),
    ("task", "POST", "/api/vms/released", {}),
    ("task", "POST", "/api/vms/1/update-attributes", {"networkstatus": "Reachable"}),
    ("task", "POST", "/api/scaling/trigger", {}),
]


@pytest.mark.parametrize("version", ["1.0", "2.0"])
@pytest.mark.parametrize("audience", [API_ID, f"api://{API_ID}"])
@pytest.mark.parametrize("kind,method,path,body", WORKLOAD_ROUTES)
def test_configured_idtyp_app_works_for_v1_and_v2_workload_tokens(client, token, version, audience, kind, method, path, body):
    changes, remove = workload_version(version)
    bearer = token(kind, changes={**changes, "aud": audience}, remove=remove)
    response = client.open(path, method=method, headers=headers(bearer), json=body)
    assert response.status_code == 200, response.get_data(as_text=True)
    assert "password" not in response.get_json()


@pytest.mark.parametrize("version", ["1.0", "2.0"])
@pytest.mark.parametrize("kind,path", [("host", "/api/hosts/settings"), ("task", "/api/vms")])
def test_preconfiguration_cached_workload_tokens_stay_denied_until_reissued(client, boundary, token, caplog, version, kind, path):
    caplog.set_level("INFO", logger="linuxbroker.api")
    changes, remove = workload_version(version)
    cached = token(kind, changes=changes, remove=(*remove, "idtyp"))
    for _ in range(2):
        assert client.get(path, headers=headers(cached)).status_code == 401
        assert_no_effects(boundary)
    renewed = token(kind, changes=changes, remove=remove)
    assert client.get(path, headers=headers(renewed)).status_code == 200
    assert cached not in caplog.text
    assert renewed not in caplog.text
    assert boundary.ssh == []
    assert boundary.power == []


@pytest.mark.parametrize("version", ["1.0", "2.0"])
@pytest.mark.parametrize("kind", ["admin", "workspace"])
@pytest.mark.parametrize("identity_type", [None, "user", "app"])
def test_optional_idtyp_does_not_reclassify_delegated_users(client, boundary, token, version, kind, identity_type):
    changes = {"ver": version}
    remove = ()
    if version == "1.0":
        changes.update({"appid": PORTAL if kind == "admin" else LAUNCHER, "iss": f"https://sts.windows.net/{TENANT}/"})
        remove = ("azp",)
    if identity_type is not None:
        changes["idtyp"] = identity_type
    response = client.get("/api/me", headers=headers(token(kind, changes=changes, remove=remove)))
    if identity_type == "app":
        assert response.status_code == 401
    else:
        assert response.status_code == 200
        assert response.get_json()["capabilities"] == {"manage": kind == "admin", "connect": kind == "workspace"}
    assert_no_effects(boundary)


@pytest.mark.parametrize("uid", [65534, 65535])
def test_reserved_sql_uid_cannot_reach_host_provisioning(client, boundary, token, uid):
    boundary.rows["BeginBrokerCheckout"]["Uid"] = uid
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 503
    assert boundary.ssh == []
    assert [name for name, _ in boundary.calls] == ["BeginBrokerCheckout", "FailBrokerOperation"]
    assert "password" not in response.get_json()


def test_unenrolled_inventory_cannot_return_an_endpoint_or_rotate_credentials(client, boundary, token):
    boundary.rows["BeginBrokerCheckout"] = {"Outcome": "Unavailable"}
    response = client.post("/api/vms/checkout", headers=headers(token()), json={"avdhost": "avd-01"})
    assert response.status_code == 409
    assert set(response.get_json()) == {"error"}
    assert boundary.ssh == []
    assert [name for name, _ in boundary.calls] == ["BeginBrokerCheckout"]
