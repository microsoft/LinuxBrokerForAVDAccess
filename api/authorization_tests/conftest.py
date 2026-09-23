"""Independent HTTP security tests: real PyJWT/cryptography, with only infrastructure mocked."""

import copy
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa


API_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(API_ROOT))
TENANT = "11111111-1111-4111-8111-111111111111"
API_ID = "22222222-2222-4222-8222-222222222222"
PORTAL = "33333333-3333-4333-8333-333333333333"
LAUNCHER = "44444444-4444-4444-8444-444444444444"
SUBJECT = "55555555-5555-4555-8555-555555555555"
OTHER = "66666666-6666-4666-8666-666666666666"
LEASE = "77777777-7777-4777-8777-777777777777"
OPERATION = "88888888-8888-4888-8888-888888888888"
ENV = {
    "TENANT_ID": TENANT, "CLIENT_ID": API_ID, "PORTAL_CLIENT_ID": PORTAL,
    "BROKER_LAUNCHER_CLIENT_ID": LAUNCHER, "AZURE_CLOUD_NAME": "AzurePublic",
    "AZURE_AUTHORITY_HOST": "https://login.microsoftonline.com",
    "STS_ISSUER_HOST": "https://sts.windows.net", "BROKER_CHECKOUT_ENABLED": "true",
    "VM_SUBSCRIPTION_ID": "local-test-subscription", "VM_RESOURCE_GROUP": "local-test-group",
    "NFS_SHARE": "nfs.example.invalid:/profiles", "DOMAIN_NAME": "example.invalid",
}
os.environ.update(ENV)
os.environ.pop("APPLICATIONINSIGHTS_CONNECTION_STRING", None)


@pytest.fixture(scope="session")
def signing_keys():
    return tuple(rsa.generate_private_key(public_exponent=65537, key_size=2048) for _ in range(2))


@pytest.fixture(scope="session")
def api_module():
    import app
    import authorization
    assert jwt.__file__ and jwt.decode.__func__ is jwt.api_jwt.PyJWT.decode
    assert app.authenticate is authorization.authenticate
    app.app.config["TESTING"] = True
    return app


class SqlBoundary:
    def __init__(self, module):
        self.calls, self.events, self.connections = [], [], []
        self.commits = 0
        self.lease = {
            "Outcome": "Ok", "VMID": 1, "Hostname": "linux-01", "IPAddress": "192.0.2.1",
            "Username": "preserved_profile", "Uid": 2042, "LeaseId": LEASE, "LeaseGeneration": 7,
            "OperationId": OPERATION, "NewAllocation": False,
        }
        settings = {key: bounds[2] for key, bounds in module.LINUX_HOST_SETTING_BOUNDS.items()}
        settings.update(module.LINUX_HOST_SETTING_BOOLEANS)
        settings["SettingsVersion"] = 1
        vm = {**self.lease, "PowerState": "On", "NetworkStatus": "Reachable", "VmStatus": "CheckedOut"}
        self.rows = {
            "GetBrokerHost": {"Hostname": "linux-01"},
            "BeginBrokerCheckout": self.lease,
            "BeginBrokerCleanup": {**self.lease, "LeaseGeneration": 8, "Reason": "admin"},
            "CompleteBrokerOperation": {"Outcome": "Ok"}, "FailBrokerOperation": {"Outcome": "Ok"},
            "ObserveBrokerSession": {"Outcome": "Ok"}, "GetVms": [vm], "GetVmDetails": vm,
            "ReturnReleasedVms": [], "TriggerScalingLogic": [], "GetVmSummary": {},
            "GetLinuxHostSettings": settings, "UpdateLinuxHostSettings": settings,
            "RecordHostSettingsApplied": {"Hostname": "linux-01", "SettingsVersion": 1},
            "UpdateVmAttributes": {"Outcome": "Ok", "VMID": 1},
            "DeleteVm": {"Outcome": "Ok", "DeletedVMID": 1}, "AddVm": {"NewVMID": 2},
            "GetScalingRules": [], "GetScalingRuleDetails": {"RuleID": 1},
            "CreateScalingRule": {"NewRuleID": 1}, "DeleteScalingRule": {"DeletedRuleID": 1},
        }

    def connect(self):
        boundary = self

        class Cursor:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def execute(self, sql, params=None):
                sql = sql.strip()
                self.proc = sql.split()[1] if sql.startswith("EXEC ") else sql
                names = re.findall(r"@(\w+)\s*=\s*%s", sql)
                boundary.calls.append((self.proc, dict(zip(names, params or ()))))
                boundary.events.append(("sql", self.proc))

            def fetchall(self):
                rows = copy.deepcopy(boundary.rows.get(self.proc, []))
                if isinstance(rows, Exception):
                    raise rows
                return rows if isinstance(rows, list) else [rows] if rows is not None else []

            def fetchone(self):
                rows = self.fetchall()
                return rows[0] if rows else None

        class Connection:
            closed = False

            def cursor(self, **_):
                return Cursor()

            def commit(self):
                boundary.commits += 1

            def close(self):
                self.closed = True

        connection = Connection()
        self.connections.append(connection)
        return connection


@pytest.fixture
def boundary(api_module, signing_keys, monkeypatch):
    import authorization
    assert api_module.authenticate is authorization.authenticate, "Authentication must not be substituted."
    assert jwt.decode.__func__ is jwt.api_jwt.PyJWT.decode, "JWT verification must be real."
    for rule in api_module.app.url_map.iter_rules():
        if rule.rule.startswith("/api/") and rule.rule != "/api/version":
            assert hasattr(api_module.app.view_functions[rule.endpoint], "authorization_policy"), "A route was unwrapped."

    def no_network(*_args, **_kwargs):
        raise AssertionError("A test attempted unmocked network access.")

    monkeypatch.setattr(authorization.requests.sessions.Session, "request", no_network)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(signing_keys[0].public_key()))
    jwk.update({"kid": "local-rsa", "use": "sig", "alg": "RS256"})

    def keys(url, *, timeout):
        assert url == f"{authorization.config.AUTHORITY_HOST}/{TENANT}/discovery/v2.0/keys"
        assert timeout == 10
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {"keys": [jwk]})

    monkeypatch.setattr(authorization.requests, "get", keys)
    db = SqlBoundary(api_module)
    monkeypatch.setattr(api_module, "get_db_connection", db.connect)
    db.ssh, db.power = [], []

    def ssh(hostname, command, stdin_input=None, timeout=120):
        db.events.append(("ssh", hostname))
        db.ssh.append((hostname, command, stdin_input))
        words = shlex.split(command)
        if "create-user.sh" in command:
            acknowledgement = {"outcome": "ready", "leaseId": words[-3], "leaseGeneration": int(words[-2]), "operationId": words[-1]}
        elif " cleanup " in command:
            acknowledgement = {"outcome": "cleaned", "leaseId": words[-4], "leaseGeneration": int(words[-3]), "operationId": words[-2]}
        else:
            acknowledgement = {}
        return SimpleNamespace(returncode=0, stdout=json.dumps(acknowledgement), stderr=""), hostname

    monkeypatch.setattr(api_module, "run_remote_command", ssh)
    monkeypatch.setattr(api_module, "DefaultAzureCredential", lambda: object())

    def power(*args):
        db.power.append(args)
        return SimpleNamespace(result=lambda **_kwargs: None, done=lambda: True)

    monkeypatch.setattr(api_module, "ComputeManagementClient", lambda **_kwargs: SimpleNamespace(
        virtual_machines=SimpleNamespace(begin_start=power, begin_power_off=power),
    ))
    return db


@pytest.fixture
def client(api_module, boundary):
    return api_module.app.test_client()


@pytest.fixture
def token(signing_keys):
    def create(kind="workspace", *, changes=None, remove=(), foreign_key=False, algorithm="RS256", kid="local-rsa"):
        now = int(time.time())
        payload = {
            "ver": "2.0", "tid": TENANT, "oid": SUBJECT, "sub": "opaque-user-subject",
            "aud": API_ID, "iss": f"https://login.microsoftonline.com/{TENANT}/v2.0",
            "iat": now - 10, "nbf": now - 10, "exp": now + 300, "azp": LAUNCHER,
            "scp": "connect_as_user", "roles": ["WorkspaceUser"],
        }
        if kind in ("admin", "scope_only", "unassigned", "user_host", "user_task"):
            payload.update({"azp": PORTAL, "scp": "access_as_user", "roles": {
                "admin": ["FullAccess"], "scope_only": [], "unassigned": [],
                "user_host": ["LinuxHost"], "user_task": ["ScheduledTask"],
            }[kind]})
        if kind in ("host", "task", "avd", "group", "app_admin"):
            payload.pop("scp")
            payload.update({"idtyp": "app", "azp": OTHER, "roles": {
                "host": ["LinuxHost"], "task": ["ScheduledTask"], "avd": ["AvdHost"],
                "group": [], "app_admin": ["FullAccess"],
            }[kind]})
            if kind == "group":
                payload["groups"] = ["avd-group-id", "linux-group-id"]
        payload.update(changes or {})
        for claim in remove:
            payload.pop(claim, None)
        key = signing_keys[int(foreign_key)] if algorithm == "RS256" else "a-deliberately-wrong-hmac-key-for-algorithm-rejection"
        return jwt.encode(payload, key, algorithm=algorithm, headers={"kid": kid})
    return create
