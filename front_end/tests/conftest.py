import os
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
FRONT_END = REPO_ROOT / "front_end"

# The app reads these during import.
os.environ.setdefault("FLASK_KEY", "test-secret-key")
os.environ.setdefault("CLIENT_ID", "client-id")
os.environ.setdefault("TENANT_ID", "tenant-id")
os.environ.setdefault("API_CLIENT_ID", "api-client-id")
os.environ.setdefault("API_URL", "https://api.example.invalid")
os.environ.setdefault("MICROSOFT_PROVIDER_AUTHENTICATION_SECRET", "secret")

sys.path.insert(0, str(FRONT_END))
os.chdir(FRONT_END)


VMS = [
    {"VMID": 1, "Hostname": "linux-host-01", "IPAddress": "10.0.0.4", "PowerState": "On",
     "NetworkStatus": "Reachable", "VmStatus": "Available", "Username": None,
     "AvdHost": None, "Description": "Pool host", "LastUpdateDate": "2026-08-01 10:00:00",
     "CreateDate": "2026-07-01 10:00:00", "SysStartTime": "2026-08-01 10:00:00", "SysEndTime": None},
    {"VMID": 2, "Hostname": "linux-host-02", "IPAddress": "10.0.0.5", "PowerState": "On",
     "NetworkStatus": "Reachable", "VmStatus": "CheckedOut", "Username": "alice@contoso.com",
     "AvdHost": "avd-01", "Description": "", "LastUpdateDate": "2026-08-02 11:00:00",
     "CreateDate": "2026-07-01 10:00:00", "SysStartTime": "2026-08-02 11:00:00", "SysEndTime": None},
    {"VMID": 3, "Hostname": "linux-host-03", "IPAddress": "10.0.0.6", "PowerState": "Off",
     "NetworkStatus": "Unreachable", "VmStatus": "Maintenance", "Username": None,
     "AvdHost": None, "Description": "Patching", "LastUpdateDate": "2026-08-03 09:00:00",
     "CreateDate": "2026-07-01 10:00:00", "SysStartTime": "2026-08-03 09:00:00", "SysEndTime": None},
    {"VMID": 4, "Hostname": "linux-host-04", "IPAddress": "10.0.0.7", "PowerState": "On",
     "NetworkStatus": "Reachable", "VmStatus": "Released", "Username": "bob@contoso.com",
     "AvdHost": "avd-02", "Description": "", "LastUpdateDate": "2026-08-04 08:00:00",
     "CreateDate": "2026-07-01 10:00:00", "SysStartTime": "2026-08-04 08:00:00", "SysEndTime": None},
]

RULE = {"RuleID": 1, "MinVMs": 2, "MaxVMs": 20, "ScaleUpRatio": 80.0,
        "ScaleUpIncrement": 2, "ScaleDownRatio": 30.0, "ScaleDownIncrement": 1}

LOG_ENTRY = {"ActivityID": 1, "CheckTimestamp": "2026-08-19 10:00:00", "CurrentRunningVMs": 5,
             "CurrentInUseVMs": 4, "ActionTaken": "Scale Up", "VMsPoweredOn": 2,
             "VMsPoweredOff": 0, "NewTotalVMs": 7, "Outcome": "Scaled up by 2 VMs",
             "Notes": "Utilization above threshold"}


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self._payload = payload
        self.status_code = status_code
        self.text = str(payload)

    def json(self):
        return self._payload

    def raise_for_status(self):
        if self.status_code >= 400:
            import requests
            raise requests.exceptions.HTTPError(f"status {self.status_code}")


class FakeBrokerApi:
    def __init__(self):
        self.posts = []
        self.scaling_log_payload = [dict(LOG_ENTRY, ActivityID=i) for i in range(1, 6)]
        self.raise_get_paths = set()
        self.raise_post_paths = set()

    def get(self, url, **kwargs):
        import requests
        if any(url.endswith(path) for path in self.raise_get_paths):
            raise requests.exceptions.RequestException("broker unavailable")
        if re.search(r"/vms/\d+$", url):
            vmid = int(url.rsplit("/", 1)[1])
            return FakeResponse(next((vm for vm in VMS if vm["VMID"] == vmid), VMS[0]))
        if url.endswith("/vms"):
            return FakeResponse(VMS)
        if re.search(r"/scaling/rules/\d+$", url):
            return FakeResponse(RULE)
        if url.endswith("/scaling/rules"):
            return FakeResponse([RULE])
        return FakeResponse({})

    def post(self, url, **kwargs):
        import requests
        self.posts.append({"url": url, "json": kwargs.get("json")})
        if any(url.endswith(path) for path in self.raise_post_paths):
            raise requests.exceptions.RequestException("broker unavailable")
        if url.endswith("/scaling/log"):
            return FakeResponse(self.scaling_log_payload)
        if url.endswith("/scaling/rules/history"):
            return FakeResponse([dict(RULE, RuleID=i, SysStartTime="2026-08-01 10:00:00", SysEndTime=None) for i in range(1, 6)])
        if url.endswith("/vms/history"):
            return FakeResponse(VMS)
        if url.endswith("/scaling/rules/create"):
            return FakeResponse({"RuleID": 1}, status_code=201)
        if url.endswith("/vms/checkout"):
            return FakeResponse(VMS[0])
        return FakeResponse({})


@pytest.fixture(scope="session")
def app():
    import app as app_module
    app_module.app.config.update(TESTING=True)
    yield app_module.app
    shutil.rmtree(FRONT_END / "flask_session", ignore_errors=True)


@pytest.fixture
def broker_api(monkeypatch):
    import requests
    fake = FakeBrokerApi()
    monkeypatch.setattr(requests, "get", fake.get)
    monkeypatch.setattr(requests, "post", fake.post)
    return fake


@pytest.fixture
def client(app, broker_api):
    return app.test_client()


@pytest.fixture
def signed_in_client(client):
    sign_in(client)
    return client


def sign_in(client):
    # Match the app's naive datetime.utcnow().timestamp() convention exactly.
    expiry = (datetime.utcnow() + timedelta(hours=1)).timestamp()
    with client.session_transaction() as sess:
        sess["user"] = {"name": "Test Operator", "preferred_username": "op@contoso.com",
                        "oid": "0000-1111", "tid": "2222-3333"}
        sess["access_token"] = "fake-token"
        sess["token_expiry"] = expiry


def seed_histories(client, count=120):
    with client.session_transaction() as sess:
        sess["vm_history"] = [dict(VMS[i % 4], VMID=i + 1) for i in range(count)]
        sess["scaling_activity_log"] = [dict(LOG_ENTRY, ActivityID=i + 1) for i in range(count)]
        sess["scaling_rules_history"] = [dict(RULE, RuleID=i + 1) for i in range(count)]


def csrf_token(html):
    match = re.search(r'name="csrf_token"[^>]*value="([^"]+)"', html)
    assert match, "expected CSRF token in rendered form"
    return match.group(1)


def assert_form_value(html, name, value):
    assert re.search(rf'<input\b[^>]*name="{re.escape(name)}"[^>]*value="{re.escape(value)}"', html)


def assert_checkbox_checked(html, name):
    assert re.search(rf'<input\b[^>]*name="{re.escape(name)}"[^>]*checked', html)


def row_for_host(html, hostname):
    rows = re.findall(r"<tr>.*?</tr>", html, flags=re.S)
    row = next((candidate for candidate in rows if hostname in candidate), "")
    assert row, f"expected row for {hostname}"
    return row
