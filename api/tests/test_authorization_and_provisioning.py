"""Authorization, caching, and provisioning behavior added in Phase 1."""

import types

import pytest


LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"

READ = {"Reader", "Operator", "FullAccess"}
OPERATE = {"Operator", "FullAccess"}
ADMIN = {"FullAccess"}

# The authorization contract from docs: every route and the roles that may call it.
EXPECTED_ROLES = {
    "get_me": set(),
    "get_all_vms": READ | {"ScheduledTask"},
    "get_vm_summary": READ | {"ScheduledTask"},
    "get_vm_details": READ,
    "get_vm_history": READ,
    "get_scaling_activity_log": READ,
    "get_scaling_rules": READ,
    "get_scaling_rule_details": READ,
    "get_scaling_rules_history": READ,
    "checkout_vm": {"AvdHost", "FullAccess"},
    "release_vm": OPERATE | {"LinuxHost"},
    "return_vm": OPERATE,
    "retry_vm_cleanup": OPERATE,
    "set_vm_maintenance": OPERATE,
    "set_vm_network_status": {"ScheduledTask", "FullAccess"},
    "update_vm_attributes": ADMIN | {"ScheduledTask"},
    "add_new_vm": ADMIN,
    "delete_vm": ADMIN,
    "return_released_vm_api": {"ScheduledTask", "FullAccess"},
    "trigger_scaling_logic": {"ScheduledTask", "FullAccess"},
    "create_scaling_rule": ADMIN,
    "update_scaling_rule": ADMIN,
    "delete_scaling_rule": ADMIN,
    "get_host_settings": READ | {"LinuxHost", "ScheduledTask"},
    "update_host_settings": ADMIN,
    "apply_host_settings": OPERATE | {"ScheduledTask"},
    "acknowledge_host_settings": {"LinuxHost", "FullAccess"},
    "get_host_settings_history": READ,
    "start_vm": OPERATE,
    "stop_vm": OPERATE,
    "restart_vm": OPERATE,
    "drain_vm": OPERATE,
    "undrain_vm": OPERATE,
    "sync_power_states": OPERATE,
    "record_host_heartbeat": {"LinuxHost", "FullAccess"},
    "get_host_health": READ,
    "get_audit_log": READ,
    "purge_audit_log": {"ScheduledTask", "FullAccess"},
    "get_sessions": READ,
    "search_users": READ,
    "get_user_details": READ,
    "sign_out_session": OPERATE,
    "message_session": OPERATE,
    "request_profile_reset": ADMIN,
    "cancel_profile_reset": ADMIN,
    "broadcast_message": OPERATE,
}

EXPECTED_GROUPS = {
    "checkout_vm": "AVD_HOST_GROUP_ID",
    "release_vm": "LINUX_HOST_GROUP_ID",
    "get_host_settings": "LINUX_HOST_GROUP_ID",
    "acknowledge_host_settings": "LINUX_HOST_GROUP_ID",
    "record_host_heartbeat": "LINUX_HOST_GROUP_ID",
}


def _protected_views(app_module):
    return {
        endpoint: view
        for endpoint, view in app_module.app.view_functions.items()
        if hasattr(view, "_allowed_roles")
    }


def test_every_route_enforces_the_documented_roles(app_module):
    views = _protected_views(app_module)
    assert set(views) == set(EXPECTED_ROLES), "a route was added or removed without updating the contract"

    for endpoint, view in views.items():
        assert set(view._allowed_roles) == EXPECTED_ROLES[endpoint], endpoint
        expected_group = EXPECTED_GROUPS.get(endpoint)
        expected_groups = (getattr(app_module, expected_group),) if expected_group else ()
        assert view._allowed_groups == expected_groups, endpoint

    assert views["get_me"]._allow_any_authenticated is True


def test_no_route_accepts_the_delegated_scope_as_a_permission(app_module):
    for endpoint, view in _protected_views(app_module).items():
        assert "access_as_user" not in view._allowed_roles, endpoint


def test_unprotected_routes_are_only_health_and_version(app_module):
    unprotected = {
        endpoint for endpoint, view in app_module.app.view_functions.items()
        if not hasattr(view, "_allowed_roles")
    }
    assert unprotected - {"static"} == {"health", "get_version"}


@pytest.mark.parametrize("role,status", [("Reader", 403), ("Operator", 403), ("FullAccess", 200)])
def test_admin_routes_reject_readers_and_operators(auth_client, fake_db, role, status):
    fake_db.fetchone_rows["DeleteVm"] = {"DeletedVMID": 5}
    client = auth_client({"roles": [role], "scp": "access_as_user"})
    response = client.post("/api/vms/5/delete", headers=auth_client.headers)
    assert response.status_code == status


@pytest.mark.parametrize("role,status", [("Reader", 403), ("Operator", 200), ("FullAccess", 200)])
def test_operator_routes_reject_readers(auth_client, fake_db, role, status):
    fake_db.fetchone_rows["SetVmMaintenance"] = {
        "Result": "Updated", "VMID": 5, "Hostname": "lnxhost-05", "VmStatus": "Maintenance",
    }
    client = auth_client({"roles": [role], "scp": "access_as_user"})
    response = client.post("/api/vms/5/maintenance", json={"enabled": True}, headers=auth_client.headers)
    assert response.status_code == status


def test_a_portal_user_without_a_role_can_read_nothing(auth_client, fake_db):
    client = auth_client({"scp": "access_as_user"})
    assert client.get("/api/vms", headers=auth_client.headers).status_code == 403


def test_the_legacy_toggle_maps_the_scope_to_full_access(app_module, auth_client, fake_db, monkeypatch):
    monkeypatch.setattr(app_module, "ALLOW_LEGACY_SCOPE_ACCESS", True)
    client = auth_client({"scp": "access_as_user"})

    assert client.get("/api/vms", headers=auth_client.headers).status_code == 200
    me = client.get("/api/me", headers=auth_client.headers).get_json()
    assert me == {
        "roles": [],
        "permissions": {"read": True, "operate": True, "admin": True},
        "legacyScopeAccess": True,
    }


def test_the_legacy_toggle_does_not_apply_to_managed_identities(app_module, auth_client, fake_db, monkeypatch):
    monkeypatch.setattr(app_module, "ALLOW_LEGACY_SCOPE_ACCESS", True)
    client = auth_client({"roles": ["ScheduledTask"]})
    assert client.post("/api/vms/5/delete", headers=auth_client.headers).status_code == 403


@pytest.mark.parametrize("roles,permissions", [
    (["Reader"], {"read": True, "operate": False, "admin": False}),
    (["Operator"], {"read": True, "operate": True, "admin": False}),
    (["FullAccess"], {"read": True, "operate": True, "admin": True}),
    ([], {"read": False, "operate": False, "admin": False}),
])
def test_me_reports_roles_and_permissions(auth_client, roles, permissions):
    client = auth_client({"roles": roles, "scp": "access_as_user"})
    response = client.get("/api/me", headers=auth_client.headers)
    assert response.status_code == 200
    assert response.get_json() == {"roles": sorted(roles), "permissions": permissions, "legacyScopeAccess": False}


def test_group_membership_is_not_checked_when_a_role_already_authorizes(auth_client, fake_db):
    client = auth_client({"roles": ["LinuxHost"]}, group_member=False)
    fake_db.fetchone_rows["RecordHostSettingsApplied"] = {"VMID": 1, "Hostname": "lnxhost-01"}

    response = client.post("/api/hosts/lnxhost-01/settings/ack", json={"settingsVersion": 3}, headers=auth_client.headers)

    assert response.status_code == 200
    assert auth_client.state["group_checks"] == []


def test_group_membership_still_authorizes_a_host_without_the_role(app_module, auth_client, fake_db):
    client = auth_client({}, group_member=True)
    fake_db.fetchone_rows["RecordHostSettingsApplied"] = {"VMID": 1, "Hostname": "lnxhost-01"}

    response = client.post("/api/hosts/lnxhost-01/settings/ack", json={"settingsVersion": 3}, headers=auth_client.headers)

    assert response.status_code == 200
    assert auth_client.state["group_checks"] == [("user-oid", (app_module.LINUX_HOST_GROUP_ID,))]


# ---------------------------------------------------------------------------
# Caching of the signing keys, the Graph token and the SSH key.


class _Jwks:
    def __init__(self, kids):
        self.status_code = 200
        self._kids = kids

    def json(self):
        return {"keys": [{"kid": kid, "kty": "RSA", "use": "sig", "n": "n", "e": "e"} for kid in self._kids]}


def test_signing_keys_are_downloaded_once_per_cache_window(app_module, auth_client, fake_db, monkeypatch):
    downloads = []

    def fake_get(url, **kwargs):
        downloads.append(kwargs.get("timeout"))
        return _Jwks(["test-kid"])

    client = auth_client({"roles": ["Reader"]})
    monkeypatch.setattr(app_module.requests, "get", fake_get)

    for _ in range(3):
        assert client.get("/api/vms", headers=auth_client.headers).status_code == 200

    assert downloads == [10]


def test_an_unknown_key_id_forces_one_refresh(app_module, auth_client, fake_db, monkeypatch):
    responses = [_Jwks(["old-kid"]), _Jwks(["old-kid", "test-kid"])]
    downloads = []

    def fake_get(url, **kwargs):
        downloads.append(url)
        return responses[min(len(downloads) - 1, len(responses) - 1)]

    client = auth_client({"roles": ["Reader"]})
    monkeypatch.setattr(app_module.requests, "get", fake_get)

    assert client.get("/api/vms", headers=auth_client.headers).status_code == 200
    assert len(downloads) == 2


def test_cached_signing_keys_survive_a_failed_refresh(app_module, auth_client, fake_db, monkeypatch):
    client = auth_client({"roles": ["Reader"]})
    monkeypatch.setattr(app_module.requests, "get", lambda url, **kwargs: _Jwks(["test-kid"]))
    assert client.get("/api/vms", headers=auth_client.headers).status_code == 200

    class _Down:
        status_code = 503

        def json(self):
            return {}

    monkeypatch.setattr(app_module, "JWKS_CACHE_SECONDS", 0)
    monkeypatch.setattr(app_module.requests, "get", lambda url, **kwargs: _Down())
    assert client.get("/api/vms", headers=auth_client.headers).status_code == 200


def test_the_graph_token_is_reused_until_it_expires(app_module, monkeypatch):
    calls = []

    class _Token:
        status_code = 200

        def json(self):
            return {"access_token": "graph-token", "expires_in": 3600}

    def fake_post(url, **kwargs):
        calls.append(kwargs.get("timeout"))
        return _Token()

    monkeypatch.setattr(app_module.requests, "post", fake_post)

    assert app_module.get_access_token("tenant", "client", "secret") == "graph-token"
    assert app_module.get_access_token("tenant", "client", "secret") == "graph-token"
    assert calls == [10]


def test_the_ssh_key_is_read_from_key_vault_once(app_module, monkeypatch, tmp_path):
    key_file = tmp_path / "private_key.pem"
    key_file.write_text("key\n")
    reads = []
    monkeypatch.setattr(
        app_module, "retrieve_pem_key_from_key_vault",
        lambda vault, name: reads.append(name) or str(key_file)
    )

    assert app_module.get_ssh_key_path() == str(key_file)
    assert app_module.get_ssh_key_path() == str(key_file)
    assert reads == [app_module.KEY_NAME]


# ---------------------------------------------------------------------------
# Database concurrency limit.


def test_a_saturated_database_pool_answers_503_not_500(app_module, client, fake_db, monkeypatch):
    exhausted = app_module.threading.BoundedSemaphore(1)
    exhausted.acquire()
    monkeypatch.setattr(app_module, "_db_slots", exhausted)
    monkeypatch.setattr(app_module, "DB_ACQUIRE_TIMEOUT_SECONDS", 0.01)

    response = client.get("/api/vms")

    assert response.status_code == 503
    assert response.get_json() == {"error": "The broker is busy. Please retry shortly."}
    assert fake_db.connections == []


def test_the_database_slot_is_released_when_a_query_fails(app_module, client, fake_db, monkeypatch):
    single = app_module.threading.BoundedSemaphore(1)
    monkeypatch.setattr(app_module, "_db_slots", single)
    fake_db.raise_on_execute["GetVms"] = "boom"

    assert client.get("/api/vms").status_code == 500
    assert single.acquire(timeout=0), "the failed request kept its database slot"


# ---------------------------------------------------------------------------
# UID allocation.


def test_uids_come_from_the_allocator_procedure(app_module, fake_db):
    fake_db.fetchone_rows["GetOrCreateVmUserUid"] = {"uid": 2042}
    assert app_module.get_or_create_uid("alice") == 2042
    assert fake_db.latest_call("GetOrCreateVmUserUid")["params"] == ("alice",)
    assert fake_db.commits == 1


def test_uids_fall_back_to_the_legacy_allocator_before_the_procedure_exists(app_module, fake_db):
    fake_db.raise_on_execute["GetOrCreateVmUserUid"] = "Could not find stored procedure 'GetOrCreateVmUserUid'."
    fake_db.fetchone_rows["SELECT MAX(uid) AS max_uid FROM VmUsers"] = {"max_uid": 2005}

    assert app_module.get_or_create_uid("alice") == 2006


def test_uid_failures_other_than_a_missing_procedure_are_not_masked(app_module, fake_db):
    fake_db.raise_on_execute["GetOrCreateVmUserUid"] = "Unable to allocate a uid."
    assert app_module.get_or_create_uid("alice") is None


# ---------------------------------------------------------------------------
# Single-call provisioning.


class _Host:
    def __init__(self, *responses):
        self.calls = []
        self._responses = list(responses)

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        self.calls.append({"command": command, "stdin": stdin_input, "timeout": timeout})
        returncode, stdout, stderr = self._responses.pop(0) if self._responses else (0, "", "")
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr), f"avdadmin@{hostname}"


def test_checkout_provisions_the_user_in_one_ssh_session(app_module, monkeypatch):
    host = _Host((0, "__CREATE_USER_RESULT=ok__\n", ""))
    monkeypatch.setattr(app_module, "run_remote_command", host)
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)

    assert app_module.create_or_update_remote_user("lnxhost-01", "alice", "s3cr3t:pass", LEASE_ID) is True

    assert len(host.calls) == 1
    call = host.calls[0]
    assert call["command"].startswith("sudo /usr/local/bin/create-user.sh --password-stdin ")
    assert call["command"].endswith(f" 2001 alice {LEASE_ID}")
    assert "s3cr3t" not in call["command"]
    assert call["stdin"] == "s3cr3t:pass\n"


def test_checkout_falls_back_for_a_host_with_the_previous_script(app_module, monkeypatch):
    usage = "Usage: /usr/local/bin/create-user.sh <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]\n"
    host = _Host(
        (1, usage, ""),          # the new form is rejected before anything changes
        (0, "", ""),             # legacy create-user.sh
        (0, "", ""),             # chpasswd
        (0, "tsusers:x:1001:", ""), (0, "alice tsusers", ""),
        (0, "appusers:x:1002:", ""), (0, "alice appusers", ""),
    )
    monkeypatch.setattr(app_module, "run_remote_command", host)
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)

    assert app_module.create_or_update_remote_user("lnxhost-01", "alice", "s3cr3t", LEASE_ID) is True

    commands = [call["command"] for call in host.calls]
    assert "--password-stdin" in commands[0]
    assert commands[1] == f"sudo /usr/local/bin/create-user.sh /mnt/test 2001 alice {LEASE_ID}"
    assert commands[2] == "sudo chpasswd"
    assert host.calls[2]["stdin"] == "alice:s3cr3t\n"


def test_checkout_does_not_fall_back_when_the_new_script_fails(app_module, monkeypatch):
    host = _Host((1, "", "Failed to mount the NFS share.\n"))
    monkeypatch.setattr(app_module, "run_remote_command", host)
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)

    assert app_module.create_or_update_remote_user("lnxhost-01", "alice", "s3cr3t", LEASE_ID) is False
    assert len(host.calls) == 1


def test_checkout_rejects_a_username_with_no_usable_characters(client, fake_db):
    response = client.post("/api/vms/checkout", json={"username": "...", "avdhost": "avd-01"})
    assert response.status_code == 400
    assert fake_db.calls == []


def test_checkout_hides_sql_errors_behind_a_generic_message(client, fake_db):
    fake_db.fetchall_rows["CheckoutVm"] = [
        {"Message": "Violation of constraint on db-prod-01", "ErrorNumber": 547, "Severity": 16, "State": 1}
    ]
    response = client.post("/api/vms/checkout", json={"username": "alice", "avdhost": "avd-01"})
    assert response.status_code == 500
    assert "db-prod-01" not in response.get_data(as_text=True)
