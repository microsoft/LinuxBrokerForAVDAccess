import os
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
API_ROOT = REPO_ROOT / "api"

# The API reads these at import time.
_ENV = {
    "TENANT_ID": "tenant-id",
    "CLIENT_ID": "client-id",
    "VM_SUBSCRIPTION_ID": "subscription-id",
    "VM_RESOURCE_GROUP": "resource-group",
    "AVD_HOST_GROUP_ID": "avd-group-id",
    "LINUX_HOST_GROUP_ID": "linux-group-id",
    "DOMAIN_NAME": "example.invalid",
    "VAULT_URL": "https://vault.example.invalid",
    "KEY_NAME": "ssh-key",
    "DB_SERVER": "db.example.invalid",
    "DB_DATABASE": "LinuxBrokerTest",
    "DB_USERNAME": "api-user",
    "DB_PASSWORD_NAME": "db-password",
    "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET": "provider-secret",
    "NFS_SHARE": "/mnt/test",
}
for key, value in _ENV.items():
    os.environ.setdefault(key, value)

sys.path.insert(0, str(API_ROOT))
os.chdir(API_ROOT)


def _install_import_fakes():
    pymssql = types.ModuleType("pymssql")
    pymssql.Error = Exception
    pymssql.connect = lambda **kwargs: None
    sys.modules.setdefault("pymssql", pymssql)

    jwt = types.ModuleType("jwt")

    class ExpiredSignatureError(Exception):
        pass

    class InvalidAudienceError(Exception):
        pass

    class InvalidIssuerError(Exception):
        pass

    class RSAAlgorithm:
        @staticmethod
        def from_jwk(jwk):
            return {"from_jwk": jwk}

    jwt.ExpiredSignatureError = ExpiredSignatureError
    jwt.InvalidAudienceError = InvalidAudienceError
    jwt.InvalidIssuerError = InvalidIssuerError
    jwt.algorithms = types.SimpleNamespace(RSAAlgorithm=RSAAlgorithm)
    jwt.get_unverified_header = lambda token: {"kid": "test-kid"}
    jwt.decode = lambda *args, **kwargs: {"oid": "user-oid", "scp": "access_as_user"}
    sys.modules.setdefault("jwt", jwt)

    azure = types.ModuleType("azure")
    azure_monitor = types.ModuleType("azure.monitor")
    azure_monitor_opentelemetry = types.ModuleType("azure.monitor.opentelemetry")
    azure_monitor_opentelemetry.configure_azure_monitor = lambda **kwargs: None
    azure_identity = types.ModuleType("azure.identity")
    azure_identity.DefaultAzureCredential = lambda *args, **kwargs: object()
    azure_mgmt = types.ModuleType("azure.mgmt")
    azure_mgmt_compute = types.ModuleType("azure.mgmt.compute")

    class ComputeManagementClient:
        def __init__(self, *args, **kwargs):
            self.virtual_machines = types.SimpleNamespace(
                begin_start=lambda *a, **k: None,
                begin_power_off=lambda *a, **k: None,
            )

    azure_mgmt_compute.ComputeManagementClient = ComputeManagementClient
    azure_keyvault = types.ModuleType("azure.keyvault")
    azure_keyvault_secrets = types.ModuleType("azure.keyvault.secrets")

    class SecretClient:
        def __init__(self, *args, **kwargs):
            pass

        def get_secret(self, name):
            return types.SimpleNamespace(value="fake-secret")

    azure_keyvault_secrets.SecretClient = SecretClient

    for module in (
        azure, azure_monitor, azure_monitor_opentelemetry, azure_identity,
        azure_mgmt, azure_mgmt_compute, azure_keyvault, azure_keyvault_secrets,
    ):
        sys.modules.setdefault(module.__name__, module)


_install_import_fakes()


class FakeJwksResponse:
    status_code = 200
    text = "jwks"

    def json(self):
        return {"keys": [{"kid": "test-kid", "kty": "RSA", "use": "sig", "n": "n", "e": "e"}]}


class FakeCursor:
    def __init__(self, db, as_dict=False):
        self.db = db
        self.as_dict = as_dict
        self.proc = None
        self.params = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def execute(self, sql, params=None):
        self.proc = _proc_name(sql)
        self.params = params
        self.db.calls.append({"sql": sql, "proc": self.proc, "params": params})
        if self.proc in self.db.raise_on_execute:
            raise RuntimeError(self.db.raise_on_execute[self.proc])

    def fetchall(self):
        # A queued sequence lets a test model calls that must differ, such as the
        # out-of-range page probe re-querying the same procedure.
        queue = self.db.fetchall_sequence.get(self.proc)
        if queue:
            return list(queue.pop(0))
        if self.proc in self.db.fetchall_rows:
            return list(self.db.fetchall_rows[self.proc])
        return []

    def fetchone(self):
        if self.proc in self.db.fetchone_rows:
            return self.db.fetchone_rows[self.proc]
        rows = self.fetchall()
        return rows[0] if rows else None


class FakeConnection:
    def __init__(self, db):
        self.db = db
        self.closed = False
        self.db.connections.append(self)

    def cursor(self, as_dict=False):
        return FakeCursor(self.db, as_dict=as_dict)

    def commit(self):
        self.db.commits += 1

    def close(self):
        self.closed = True


class FakeDb:
    def __init__(self):
        self.connections = []
        self.calls = []
        self.commits = 0
        self.raise_on_execute = {}
        self.fetchall_sequence = {}
        self.fetchall_rows = {
            "GetVms": [{"VMID": 1, "Hostname": "linux-01"}],
            "GetScalingRules": [{"RuleID": 1, "MinVMs": 1}],
            "GetVmHistory": [{"VMID": 1, "Hostname": "linux-01"}],
            "GetScalingActivityLog": [{"ActivityID": 1, "ActionTaken": "None"}],
            "GetVMScalingRulesHistory": [{"RuleID": 1, "SysStartTime": "2026-08-01"}],
            "GetVmHistoryPaged": [
                {"VMID": 2, "Hostname": "linux-02", "TotalCount": 3},
                {"VMID": 3, "Hostname": "linux-03", "TotalCount": 3},
            ],
            "GetScalingActivityLogPaged": [
                {"ActivityID": 2, "ActionTaken": "Scale Up", "TotalCount": 2},
            ],
            "GetVmScalingRulesHistoryPaged": [
                {"RuleID": 2, "MinVMs": 2, "TotalCount": 4},
            ],
        }
        self.fetchone_rows = {
            "GetVmSummary": {
                "TotalVMs": 5,
                "Available": 1,
                "CheckedOut": 1,
                "Maintenance": 1,
                "Released": 1,
                "PoweredOn": 3,
                "PoweredOff": 2,
                "Unreachable": 1,
                "Ready": 1,
            }
        }

    def connect(self):
        return FakeConnection(self)

    def latest_call(self, proc):
        return next(call for call in reversed(self.calls) if call["proc"] == proc)


def _proc_name(sql):
    text = " ".join(str(sql).replace("\n", " ").split())
    if text.upper().startswith("EXEC "):
        return text.split()[1]
    return text


@pytest.fixture(scope="session")
def app_module():
    import app as module
    module.app.config.update(TESTING=True)
    return module


@pytest.fixture
def fake_db(app_module, monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(app_module, "get_db_connection", db.connect)
    return db


@pytest.fixture
def client(app_module, fake_db, monkeypatch):
    for endpoint, view in list(app_module.app.view_functions.items()):
        original = getattr(view, "__wrapped__", None)
        if original is not None:
            monkeypatch.setitem(app_module.app.view_functions, endpoint, original)
    return app_module.app.test_client()
