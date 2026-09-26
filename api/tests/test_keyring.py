"""3.4 login keyring keys: kept in the keyring vault, sent to create-user.sh at checkout, and
rotated when a profile reset is applied."""

import types

import pytest


LEASE_ID = "8ff6eb09-90ca-4efa-8ea1-695761f950f7"
STORED_KEY = "Aa0_-" + "k" * 38
CREATE_USER_OK = (0, "__CREATE_USER_RESULT=ok__\n", "")


class VaultError(Exception):
    def __init__(self, status_code):
        super().__init__(f"Key Vault answered {status_code}.")
        self.status_code = status_code


class FakeVault:
    """Stands in for the keyring vault's SecretClient."""

    def __init__(self, secrets=None, get_error=None, set_error=None):
        self.secrets = dict(secrets or {})
        self.get_error = get_error
        self.set_error = set_error
        self.calls = []

    def get_secret(self, name):
        self.calls.append(("get", name))
        if self.get_error:
            raise self.get_error
        if name not in self.secrets:
            raise VaultError(404)
        return types.SimpleNamespace(value=self.secrets[name])

    def set_secret(self, name, value, content_type=None):
        self.calls.append(("set", name, content_type))
        if self.set_error:
            raise self.set_error
        self.secrets[name] = value
        return types.SimpleNamespace(value=value)


class Host:
    def __init__(self, *responses):
        self.calls = []
        self._responses = list(responses)

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        self.calls.append({"command": command, "stdin": stdin_input})
        returncode, stdout, stderr = self._responses.pop(0) if self._responses else CREATE_USER_OK
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr), f"avdadmin@{hostname}"

    def create_user_stdin(self):
        return next(call["stdin"] for call in self.calls if "create-user.sh --password-stdin" in call["command"])


@pytest.fixture
def vault(app_module, monkeypatch):
    fake = FakeVault()
    monkeypatch.setattr(app_module, "KEYRING_VAULT_URL", "https://kr.example.invalid/")
    monkeypatch.setattr(app_module, "get_keyring_secret_client", lambda: fake)
    return fake


@pytest.fixture
def host(app_module, monkeypatch):
    fake = Host()
    monkeypatch.setattr(app_module, "run_remote_command", fake)
    monkeypatch.setattr(app_module, "get_or_create_uid", lambda username: 2001)
    return fake


def provision(app_module):
    return app_module.create_or_update_remote_user("lnxhost-01", "alice", "s3cr3t", LEASE_ID)


def test_checkout_sends_the_keyring_key_on_a_second_line(app_module, vault, host):
    vault.secrets["keyring-2001"] = STORED_KEY

    assert provision(app_module) is True

    assert host.calls[0]["stdin"] == f"s3cr3t\n{STORED_KEY}\n"
    assert STORED_KEY not in host.calls[0]["command"]
    assert vault.calls == [("get", "keyring-2001")]


def test_the_first_checkout_creates_the_users_keyring_key(app_module, vault, host):
    assert provision(app_module) is True

    assert vault.calls == [("get", "keyring-2001"), ("set", "keyring-2001", "linuxbroker-keyring")]
    key = vault.secrets["keyring-2001"]
    assert app_module.KEYRING_KEY_PATTERN.match(key)
    assert host.calls[0]["stdin"] == f"s3cr3t\n{key}\n"


def test_a_stored_value_that_is_not_a_key_is_replaced(app_module, vault, host):
    vault.secrets["keyring-2001"] = "not a key!"

    assert provision(app_module) is True

    key = vault.secrets["keyring-2001"]
    assert key != "not a key!" and app_module.KEYRING_KEY_PATTERN.match(key)
    assert host.calls[0]["stdin"] == f"s3cr3t\n{key}\n"


def test_no_key_is_sent_without_the_keyring_vault(app_module, vault, host, monkeypatch):
    monkeypatch.setattr(app_module, "KEYRING_VAULT_URL", None)

    assert provision(app_module) is True

    assert host.calls[0]["stdin"] == "s3cr3t\n"
    assert vault.calls == []


def test_a_key_vault_failure_never_blocks_the_checkout_and_pauses_the_vault(app_module, vault, host, monkeypatch, caplog):
    clock = [1000.0]
    monkeypatch.setattr(app_module.time, "monotonic", lambda: clock[0])
    vault.get_error = VaultError(403)

    assert provision(app_module) is True
    assert host.calls[0]["stdin"] == "s3cr3t\n"
    assert "send no keyring key for the next 5 minutes" in caplog.text

    # Inside the five minutes the vault is not asked again.
    clock[0] += 299
    assert provision(app_module) is True
    assert host.calls[1]["stdin"] == "s3cr3t\n"
    assert vault.calls == [("get", "keyring-2001")]

    vault.get_error = None
    vault.secrets["keyring-2001"] = STORED_KEY
    clock[0] += 2
    assert provision(app_module) is True
    assert host.calls[2]["stdin"] == f"s3cr3t\n{STORED_KEY}\n"


def test_a_deleted_secret_affects_only_its_own_user(app_module, vault, host, caplog):
    vault.set_error = VaultError(409)

    assert provision(app_module) is True

    assert host.calls[0]["stdin"] == "s3cr3t\n"
    assert "must be recovered or purged" in caplog.text
    assert app_module._keyring_state["unavailable_until"] == 0.0


def test_the_legacy_provisioning_path_sends_no_key(app_module, vault, host):
    vault.secrets["keyring-2001"] = STORED_KEY
    usage = "Usage: /usr/local/bin/create-user.sh <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]\n"
    host._responses = [(1, usage, ""), (0, "", ""), (0, "", ""),
                       (0, "tsusers:x:1001:", ""), (0, "alice tsusers", ""),
                       (0, "appusers:x:1002:", ""), (0, "alice appusers", "")]

    assert provision(app_module) is True

    assert all(STORED_KEY not in (call["stdin"] or "") for call in host.calls[1:])


def checkout_row(**values):
    row = {
        "VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5", "Username": "bob", "AvdHost": "avd-01",
        "LeaseId": LEASE_ID, "VmStatus": "CheckedOut", "CheckoutType": "Assigned", "ProfileResetRequested": True,
    }
    row.update(values)
    return row


@pytest.mark.parametrize("reset_result,rotated", [
    ("profile-reset", True),
    ("profile-missing", False),
    ("failed", False),
])
def test_only_an_applied_profile_reset_rotates_the_key(client, fake_db, vault, host, reset_result, rotated):
    vault.secrets["keyring-2001"] = STORED_KEY
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row()]
    fake_db.fetchone_rows["BeginProfileReset"] = {"Result": "Ready"}
    fake_db.fetchone_rows["CompleteProfileReset"] = {"Result": "Completed"}
    host._responses = [(0, f"__SESSION_CONTROL_RESULT={reset_result}\n", ""), CREATE_USER_OK]

    response = client.post("/api/vms/checkout", json={"username": "bob", "avdhost": "avd-01"})

    assert response.status_code == 200
    key = vault.secrets["keyring-2001"]
    assert host.create_user_stdin() == f"{response.get_json()['password']}\n{key}\n"
    if rotated:
        assert vault.calls == [("set", "keyring-2001", "linuxbroker-keyring")]
        assert key != STORED_KEY
    else:
        assert vault.calls == [("get", "keyring-2001")]
        assert key == STORED_KEY


def test_a_reconnect_keeps_the_key(client, fake_db, vault, host):
    vault.secrets["keyring-2001"] = STORED_KEY
    fake_db.fetchall_rows["CheckoutVm"] = [checkout_row(CheckoutType="Reused")]

    assert client.post("/api/vms/checkout", json={"username": "bob", "avdhost": "avd-01"}).status_code == 200
    assert vault.calls == [("get", "keyring-2001")]
    assert host.create_user_stdin().endswith(f"\n{STORED_KEY}\n")
