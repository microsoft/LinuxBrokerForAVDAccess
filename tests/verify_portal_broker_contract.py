"""Offline HTTP integration: real broker JWT verification and the real portal BFF.

Run with the API's Python environment and pass the portal's Python executable.
Only Entra signing-key retrieval, Azure secrets, and read-only SQL are substituted.
No Azure service, real account, SSH command, or user profile is contacted.
"""

import argparse
from contextlib import ExitStack, chdir
import importlib
import json
import logging
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
TENANT = "11111111-1111-4111-8111-111111111111"
API = "22222222-2222-4222-8222-222222222222"
PORTAL = "33333333-3333-4333-8333-333333333333"
LAUNCHER = "44444444-4444-4444-8444-444444444444"
USER = "55555555-5555-4555-8555-555555555555"
ADMIN = "66666666-6666-4666-8666-666666666666"
AUTHORITY = "https://login.microsoftonline.com"


def configure():
    os.environ.update({
        "TENANT_ID": TENANT,
        "CLIENT_ID": API,
        "PORTAL_CLIENT_ID": PORTAL,
        "BROKER_LAUNCHER_CLIENT_ID": LAUNCHER,
        "BROKER_CHECKOUT_ENABLED": "true",
        "API_CLIENT_ID": API,
        "AZURE_CLOUD_NAME": "AzurePublic",
        "AZURE_AUTHORITY_HOST": AUTHORITY,
        "STS_ISSUER_HOST": "https://sts.windows.net",
        "APPLICATIONINSIGHTS_CONNECTION_STRING": "",
        "VAULT_URL": "https://integration.invalid",
        "DB_PASSWORD_NAME": "integration-only",
        "FLASK_KEY": secrets.token_hex(32),
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
    })


def portal_worker():
    import requests
    from flask.sessions import SecureCookieSessionInterface

    payload = json.load(sys.stdin)
    os.environ["CLIENT_ID"] = PORTAL
    os.environ["API_URL"] = payload["apiUrl"]
    expected = urlparse(payload["apiUrl"])
    original_request = requests.sessions.Session.request

    def local_request(session, method, url, *args, **kwargs):
        parsed = urlparse(url)
        if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port != expected.port:
            raise AssertionError("Integration test attempted a non-local request.")
        session.trust_env = False
        return original_request(session, method, url, *args, **kwargs)

    with tempfile.TemporaryDirectory(prefix="linuxbroker-portal-contract-") as directory, chdir(directory):
        sys.path.insert(0, str(ROOT / "front_end"))
        with patch.object(requests.sessions.Session, "request", local_request):
            module = importlib.import_module("app")
            module.app.config.update(TESTING=True, WTF_CSRF_ENABLED=False)
            module.app.session_interface = SecureCookieSessionInterface()
            results = []
            client = module.app.test_client()
            for case in payload["cases"]:
                with client.session_transaction() as session:
                    session.clear()
                    if case.get("token"):
                        session["user"] = {
                            "oid": case.get("subject", USER),
                            "tid": TENANT,
                            "name": "Integration account",
                            "roles": ["FullAccess"],
                        }
                        session["access_token"] = case["token"]
                        session["token_expiry"] = time.time() + case.get("sessionLifetime", 240)
                response = client.open(
                    case["path"], method=case.get("method", "GET"),
                    json=case.get("body"),
                )
                assert response.status_code in case["expected"], (
                    f"{case['name']}: expected {case['expected']}, got {response.status_code}"
                )
                results.append({"case": case["name"], "status": response.status_code})
            print(json.dumps(results))


def run(portal_python):
    from cryptography.hazmat.primitives.asymmetric import rsa
    import jwt
    import requests
    from werkzeug.serving import make_server

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key()))
    jwk.update(kid="integration-key", use="sig", alg="RS256")
    database_calls = []
    http_calls = []

    def signing_keys(url, **_kwargs):
        assert url == f"{AUTHORITY}/{TENANT}/discovery/v2.0/keys"
        return SimpleNamespace(raise_for_status=lambda: None, json=lambda: {"keys": [jwk]})

    class Cursor:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, statement, *_args):
            assert " ".join(statement.split()).lower() == "exec getvms", "Unexpected database operation."
            database_calls.append("GetVms")

        def fetchall(self):
            return [{
                "VMID": 1, "Hostname": "integration-linux", "IPAddress": "10.0.0.10",
                "VmStatus": "Available", "PowerState": "On", "NetworkStatus": "Reachable",
                "LeaseId": None, "LeaseGeneration": 0,
            }]

    class Connection:
        def cursor(self, **_kwargs):
            return Cursor()

        def close(self):
            pass

    def token(subject, client, scope=None, roles=(), expired=False):
        now = int(time.time())
        claims = {
            "tid": TENANT, "oid": subject, "sub": subject, "ver": "2.0", "azp": client,
            "aud": API, "iss": f"{AUTHORITY}/{TENANT}/v2.0",
            "iat": now - 60, "nbf": now - 60, "exp": now - 1 if expired else now + 300,
            "roles": list(roles), "idtyp": "user" if scope else "app",
        }
        if scope:
            claims["scp"] = scope
        return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "integration-key"})

    def http(base, path, method="GET", bearer=None, body=None):
        headers = {"Content-Type": "application/json"}
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        request = Request(
            base + path, method=method, headers=headers,
            data=json.dumps(body).encode() if body is not None else None,
        )
        try:
            with urlopen(request, timeout=20) as response:
                return response.status
        except HTTPError as error:
            error.close()
            return error.code

    with ExitStack() as stack:
        stack.enter_context(patch("azure.identity.DefaultAzureCredential", return_value=object()))
        secret_client = stack.enter_context(patch("azure.keyvault.secrets.SecretClient"))
        secret_client.return_value.get_secret.return_value = SimpleNamespace(value="integration-only")
        stack.enter_context(patch.object(requests, "get", signing_keys))
        sys.path.insert(0, str(ROOT / "api"))
        module = importlib.import_module("app")
        module.app.config.update(TESTING=True)
        logging.getLogger("werkzeug").setLevel(logging.ERROR)
        logging.getLogger("linuxbroker.api").setLevel(logging.WARNING)
        stack.enter_context(patch.object(module, "get_db_connection", Connection))
        stack.enter_context(patch.object(module, "run_remote_command", side_effect=AssertionError("Unexpected SSH.")))

        @module.app.before_request
        def record_request():
            http_calls.append((module.request.method, module.request.path))

        server = make_server("127.0.0.1", 0, module.app)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_port}"
            assert http(base, "/api/version") == 200
            admin = token(ADMIN, PORTAL, "access_as_user", ["FullAccess"])
            ordinary = token(USER, PORTAL, "access_as_user")
            workspace = token(USER, LAUNCHER, "connect_as_user", ["WorkspaceUser"])
            denied_checkouts = [
                ("legacy machine", token(USER, LAUNCHER, roles=["AvdHost"]), {}, 403),
                ("scope only", ordinary, {}, 403),
                ("administrator impersonation", admin, {"username": "victim"}, 403),
                ("workspace target override", workspace, {"username": "victim", "avdhost": "avd-01"}, 400),
            ]
            for name, bearer, body, expected in denied_checkouts:
                status = http(base, "/api/vms/checkout", "POST", bearer, body)
                assert status == expected, f"{name}: expected {expected}, got {status}"
            assert not database_calls, "Denied checkout reached database allocation."

            cases = [
                {"name": "signed out", "path": "/api/ui/vms", "expected": [401]},
                {"name": "scope only despite ID-token role", "token": ordinary, "path": "/api/ui/vms", "expected": [403]},
                {"name": "workspace user", "token": workspace, "path": "/api/ui/vms", "expected": [403]},
                {"name": "administrator", "token": admin, "subject": ADMIN, "path": "/api/ui/vms", "expected": [200]},
                {"name": "role absent on new access token", "token": token(ADMIN, PORTAL, "access_as_user"), "subject": ADMIN, "path": "/api/ui/vms", "expected": [403]},
                {"name": "wrong client", "token": token(ADMIN, LAUNCHER, "access_as_user", ["FullAccess"]), "subject": ADMIN, "path": "/api/ui/vms", "expected": [403]},
                {"name": "wrong scope", "token": token(ADMIN, PORTAL, "connect_as_user", ["FullAccess"]), "subject": ADMIN, "path": "/api/ui/vms", "expected": [403]},
                {"name": "subject mismatch", "token": admin, "path": "/api/ui/vms", "expected": [401, 403]},
                {"name": "expired access token", "token": token(ADMIN, PORTAL, "access_as_user", ["FullAccess"], expired=True), "subject": ADMIN, "path": "/api/ui/vms", "expected": [401]},
                {"name": "expired session", "token": admin, "subject": ADMIN, "sessionLifetime": -1, "path": "/api/ui/vms", "expected": [401]},
                {"name": "removed checkout", "token": admin, "subject": ADMIN, "method": "POST", "path": "/api/ui/vms/checkout", "body": {"username": "victim"}, "expected": [404, 405, 410]},
                {"name": "ordinary mutation", "token": ordinary, "method": "POST", "path": "/api/ui/vms", "body": {"hostname": "untrusted"}, "expected": [403]},
            ]
            result = subprocess.run(
                [portal_python, str(Path(__file__).resolve()), "--portal-worker"],
                input=json.dumps({"apiUrl": base + "/api", "cases": cases}),
                text=True, capture_output=True, timeout=90, check=False,
            )
            if result.returncode:
                raise AssertionError(f"Portal contract worker failed:\n{result.stderr}")
            results = json.loads(result.stdout)
            assert len(results) == len(cases)
            assert database_calls == ["GetVms"], "Unauthorized portal request reached the database."
            business_calls = [entry for entry in http_calls if entry[1] != "/api/me"]
            assert business_calls.count(("GET", "/api/vms")) == 1
            assert not any(method == "POST" and path != "/api/vms/checkout" for method, path in business_calls)
            print(f"Passed {len(denied_checkouts)} real-JWT checkout denials and {len(results)} live BFF/broker contract cases.")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=10)


if __name__ == "__main__":
    configure()
    parser = argparse.ArgumentParser()
    parser.add_argument("--portal-python", default=sys.executable)
    parser.add_argument("--portal-worker", action="store_true")
    options = parser.parse_args()
    if options.portal_worker:
        portal_worker()
    else:
        run(options.portal_python)
