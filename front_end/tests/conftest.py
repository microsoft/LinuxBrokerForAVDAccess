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

# Mirrors the seeded profile in sql_queries/028_create_table-linux_host_settings.sql.
HOST_SETTINGS = {"GracePeriodSeconds": 1200, "ReconcileIntervalSeconds": 60,
                 "WatcherDebounceSeconds": 10, "WatcherSettleSeconds": 2,
                 "IdleTimeoutSeconds": 0, "IdleWarningSeconds": 120,
                 "ScreenLockEnabled": False, "DisableLockScreen": True,
                 "ScreenIdleDelaySeconds": 0, "ScreenLockDelaySeconds": 0,
                 "ScreenLockSettingsLocked": True, "SettingsVersion": 3}

# Every JSON endpoint the React portal calls.
API = "/api/ui"

# The three history endpoints behave identically apart from the broker path they
# read from, so they are parametrised together throughout the suite.
HISTORY_PATHS = [f"{API}/vms/history", f"{API}/scaling/log", f"{API}/scaling/rules/history"]


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
            # Real requests attaches the response to the error; code that inspects
            # e.response.status_code depends on it, so the stub must match.
            raise requests.exceptions.HTTPError(f"status {self.status_code}", response=self)


class FakeBrokerApi:
    def __init__(self):
        self.posts = []
        # Number of rows the history endpoints report.
        self.history_total = 120
        self.scaling_log_payload = [
            dict(LOG_ENTRY, ActivityID=i) for i in range(1, self.history_total + 1)
        ]
        self.host_settings = dict(HOST_SETTINGS)
        self.apply_result = {"SettingsVersion": HOST_SETTINGS["SettingsVersion"],
                             "TargetCount": 2, "SucceededCount": 2,
                             "Results": [{"Hostname": "linux-host-01", "Applied": True, "Message": "Applied."},
                                         {"Hostname": "linux-host-02", "Applied": True, "Message": "Applied."}]}
        self.raise_get_paths = set()
        self.raise_post_paths = set()

        # Mirrors GetVmSummary for the four seeded VMs in VMS: one Available (on,
        # reachable -> ready), one CheckedOut, one Maintenance (off, unreachable),
        # one Released.
        self.vm_summary = {
            "TotalVMs": 4, "Available": 1, "CheckedOut": 1, "Maintenance": 1,
            "Released": 1, "PoweredOn": 3, "PoweredOff": 1, "Unreachable": 1,
            "Ready": 1,
        }
        # Set to 404/405/500 to simulate an API that predates /vms/summary.
        self.summary_status = None

        # Set True to simulate an API that predates pagination and answers with a
        # bare list regardless of page/per_page.
        self.legacy_history = False

    def get(self, url, **kwargs):
        import requests
        if any(url.endswith(path) for path in self.raise_get_paths):
            raise requests.exceptions.RequestException("broker unavailable")
        if url.endswith("/vms/summary"):
            if self.summary_status is not None:
                return FakeResponse({"error": "not found"}, status_code=self.summary_status)
            return FakeResponse(self.vm_summary)
        if url.endswith("/hosts/settings"):
            return FakeResponse(self.host_settings)
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
        params = kwargs.get("params") or {}
        self.posts.append({"url": url, "json": kwargs.get("json"), "params": params})
        if any(url.endswith(path) for path in self.raise_post_paths):
            raise requests.exceptions.RequestException("broker unavailable")
        if url.endswith("/hosts/settings/update"):
            return FakeResponse(self.host_settings)
        if url.endswith("/hosts/settings/apply"):
            return FakeResponse(self.apply_result)
        if url.endswith("/scaling/log"):
            return self._history(self.scaling_log_payload, params)
        if url.endswith("/scaling/rules/history"):
            rows = [dict(RULE, RuleID=i, SysStartTime="2026-08-01 10:00:00", SysEndTime=None)
                    for i in range(1, self.history_total + 1)]
            return self._history(rows, params)
        if url.endswith("/vms/history"):
            rows = [dict(VMS[i % len(VMS)], VMID=i + 1) for i in range(self.history_total)]
            return self._history(rows, params)
        if url.endswith("/scaling/rules/create"):
            return FakeResponse({"RuleID": 1}, status_code=201)
        if url.endswith("/vms/checkout"):
            return FakeResponse(VMS[0])
        return FakeResponse({})

    def _history(self, rows, params):
        """Mirror the API: a paged envelope when page/per_page are supplied, a bare
        list otherwise."""
        if not isinstance(rows, list):
            return FakeResponse(rows)

        if self.legacy_history or not params:
            return FakeResponse(rows)

        page = int(params.get("page", 1) or 1)
        per_page = int(params.get("per_page", 50) or 50)
        start = (page - 1) * per_page
        total = len(rows)
        return FakeResponse({
            "items": rows[start:start + per_page],
            "page": page,
            "per_page": per_page,
            "total": total,
            "total_pages": (total + per_page - 1) // per_page if per_page else 0,
        })


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


# A minimal stand-in for the Vite output. It carries the same local-only asset
# references as the real shell so the no-CDN assertion is still meaningful.
STUB_SHELL = """<!doctype html>
<html lang="en" data-theme="light">
  <head>
    <meta charset="UTF-8" />
    <title>Linux Broker Management Portal</title>
    <link rel="icon" href="/favicon.ico" sizes="any" />
    <script type="module" crossorigin src="/static/dist/assets/index.js"></script>
    <link rel="stylesheet" crossorigin href="/static/dist/assets/index.css" />
  </head>
  <body><div id="root"></div></body>
</html>
"""


@pytest.fixture
def spa_bundle():
    """Guarantee a built SPA shell exists for the tests that serve it.

    `static/dist` is a build artifact from `npm run build`, so it is absent on a
    fresh checkout and in the Python CI job, which has no Node toolchain. These
    tests are about Flask's routing and headers, not about the bundle's contents,
    so they supply their own shell rather than depending on whether someone has
    run a build. A real build is left untouched.
    """
    import app as app_module

    entry = Path(app_module.SPA_DIST) / app_module.SPA_ENTRY
    if entry.exists():
        yield entry
        return

    entry.parent.mkdir(parents=True, exist_ok=True)
    entry.write_text(STUB_SHELL, encoding="utf-8")
    try:
        yield entry
    finally:
        entry.unlink(missing_ok=True)
        # Only removes the directory when it is empty, so a partial real build
        # is never deleted.
        try:
            entry.parent.rmdir()
        except OSError:
            pass


@pytest.fixture
def missing_spa_bundle(tmp_path, monkeypatch):
    """Point the app at an empty dist folder to exercise the not-built branch."""
    import app as app_module

    monkeypatch.setattr(app_module, "SPA_DIST", str(tmp_path / "dist"))


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


def csrf_token(client):
    """Fetch a CSRF token the way the React client does.

    The portal reads it from the session bootstrap and returns it on every
    state-changing request as an X-CSRFToken header.
    """
    response = client.get(f"{API}/session")
    assert response.status_code == 200
    token = response.get_json()["csrfToken"]
    assert token
    return token


def post(client, path, json=None):
    """POST with a valid CSRF header, as the portal does."""
    return client.post(path, json=json if json is not None else {},
                       headers={"X-CSRFToken": csrf_token(client)})


def vm_by_hostname(hostname):
    return next(vm for vm in VMS if vm["Hostname"] == hostname)
