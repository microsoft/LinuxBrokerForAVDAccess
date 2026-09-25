"""Broker API tests against a real SQL Server with every script in sql_queries applied.

The unit tests in api/tests replace pymssql with a fake, so they cannot catch a mismatch
between a stored procedure and the handler that calls it, or the driver's behavior: pymssql
wraps every statement in its own transaction, so a procedure that rolls that transaction
back makes the handler's commit fail.

Skipped unless SQL_TEST_SERVER is set (for example localhost:14330). Run separately from
the unit tests, because those install fake database and Azure modules for the whole
process: `pytest tests_integration`.
"""

import os
import sys
import types
import uuid
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
API_ROOT = REPO_ROOT / "api"
SQL_DIR = REPO_ROOT / "sql_queries"

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
    "NFS_SHARE": "nfs.example.invalid:/share/home",
}
for key, value in _ENV.items():
    os.environ.setdefault(key, value)

SQL_SERVER = os.environ.get("SQL_TEST_SERVER")
SQL_USER = os.environ.get("SQL_TEST_USER", "sa")
SQL_PASSWORD = os.environ.get("SQL_TEST_PASSWORD", "")


def _fake_driver_loaded():
    driver = sys.modules.get("pymssql")
    return driver is not None and not hasattr(driver, "__version__")


def pytest_collection_modifyitems(config, items):
    reason = None
    if not SQL_SERVER:
        reason = "SQL_TEST_SERVER is not set."
    elif _fake_driver_loaded():
        reason = "The unit tests' fake pymssql is loaded; run `pytest tests_integration` on its own."
    if reason:
        for item in items:
            item.add_marker(pytest.mark.skip(reason=reason))


@pytest.fixture(scope="session")
def sql():
    sys.path.insert(0, str(SQL_DIR / "tests"))
    from apply_scripts import apply_scripts, connect

    database = f"LinuxBrokerApiIt_{uuid.uuid4().hex[:10]}"
    master = connect(SQL_SERVER, SQL_USER, SQL_PASSWORD, "master", autocommit=True)
    try:
        cursor = master.cursor()
        cursor.execute(f"CREATE DATABASE [{database}]")
        cursor.execute(f"ALTER DATABASE [{database}] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE")
    finally:
        master.close()

    conn = connect(SQL_SERVER, SQL_USER, SQL_PASSWORD, database, autocommit=True)
    try:
        apply_scripts(conn, SQL_DIR)
    finally:
        conn.close()

    def open_connection(autocommit=False):
        # autocommit=False by default, exactly as the API connects in production.
        return connect(SQL_SERVER, SQL_USER, SQL_PASSWORD, database, autocommit=autocommit)

    yield open_connection

    master = connect(SQL_SERVER, SQL_USER, SQL_PASSWORD, "master", autocommit=True)
    try:
        cursor = master.cursor()
        cursor.execute(f"ALTER DATABASE [{database}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE")
        cursor.execute(f"DROP DATABASE [{database}]")
    finally:
        master.close()


class Db:
    def __init__(self, open_connection):
        self._open = open_connection

    def run(self, statement, params=()):
        conn = self._open(autocommit=True)
        try:
            cursor = conn.cursor(as_dict=True)
            cursor.execute(statement, params)
            try:
                return cursor.fetchall()
            except Exception:
                return []
        finally:
            conn.close()

    def one(self, statement, params=()):
        rows = self.run(statement, params)
        return rows[0] if rows else None

    def vm(self, hostname):
        return self.one("SELECT * FROM dbo.VirtualMachines WHERE Hostname = %s", (hostname,))

    def add_vm(self, hostname, power="On", network="Reachable", status="Available", **columns):
        self.run(
            "INSERT INTO dbo.VirtualMachines (Hostname, IPAddress, PowerState, NetworkStatus, VmStatus) "
            "VALUES (%s, %s, %s, %s, %s)",
            (hostname, "10.0.0.4", power, network, status),
        )
        for column, value in columns.items():
            self.run(f"UPDATE dbo.VirtualMachines SET {column} = %s WHERE Hostname = %s", (value, hostname))
        return self.vm(hostname)


@pytest.fixture
def db(sql):
    database = Db(sql)
    for statement in (
        "DELETE FROM dbo.VmUsers",
        "DELETE FROM dbo.AuditLog",
        "DELETE FROM dbo.HostHeartbeats",
        "DELETE FROM dbo.CheckoutEvents",
        "DELETE FROM dbo.HostStartEvents",
        "DELETE FROM dbo.MaintenanceRunHosts",
        "DELETE FROM dbo.MaintenanceRuns",
        "DELETE FROM dbo.VirtualMachines",
        "DELETE FROM dbo.VmScalingActivityLog",
        "DELETE FROM dbo.VmScalingRules",
        "DELETE FROM dbo.ScalingSchedules",
        "UPDATE dbo.ScalingPolicy SET TimeZone=N'UTC', UpdatedBy=NULL",
        "UPDATE dbo.LinuxHostSettings SET GracePeriodSeconds=1200, ReconcileIntervalSeconds=60, "
        "IdleTimeoutSeconds=0, IdleWarningSeconds=120, ScreenLockEnabled=0, DisableLockScreen=1, "
        "PreserveSessionsOnDisconnect=0 WHERE SettingsScope='Global'",
        "INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement) "
        "VALUES (2, 10, 70.00, 2, 30.00, 1)",
    ):
        database.run(statement)
    return database


@pytest.fixture(scope="session")
def app_module(sql):
    sys.path.insert(0, str(API_ROOT))
    import app as module
    module.app.config.update(TESTING=True)
    return module


@pytest.fixture
def client(app_module, sql, db, monkeypatch):
    monkeypatch.setattr(app_module, "get_db_connection", lambda: sql())
    app_module.reset_caches()
    for endpoint, view in list(app_module.app.view_functions.items()):
        original = getattr(view, "__wrapped__", None)
        if original is not None:
            monkeypatch.setitem(app_module.app.view_functions, endpoint, original)
    return app_module.app.test_client()


class RemoteHost:
    """Scripted stand-in for run_remote_command, keyed by what the command does."""

    DEFAULTS = {
        "create": (0, "__CREATE_USER_RESULT=ok__\n", ""),
        "clear": (0, "__LEASE_ACTION=cleared__\n", ""),
        "clear-any": (0, "__LEASE_ACTION=cleared__\n", ""),
        "signout": (0, "__SESSION_CONTROL_RESULT=signed-out\n", ""),
        "message": (0, "__SESSION_CONTROL_RESULT=delivered\n__SESSION_CONTROL_SESSIONS=1\n__SESSION_CONTROL_DELIVERED=1\n", ""),
        "message-all": (0, "__SESSION_CONTROL_RESULT=delivered\n__SESSION_CONTROL_SESSIONS=1\n__SESSION_CONTROL_DELIVERED=1\n", ""),
        "reset-profile": (0, "__SESSION_CONTROL_RESULT=profile-reset\n__SESSION_CONTROL_RENAMED_TO=renamed\n", ""),
    }

    def __init__(self):
        self.calls = []
        self.stdin = []
        self.replies = {}

    def reply(self, kind, returncode=0, stdout="", stderr=""):
        self.replies[kind] = (returncode, stdout, stderr)

    @staticmethod
    def kind_of(command):
        if "create-user.sh --password-stdin" in command:
            return "create"
        if "manage-lease.sh clear-any" in command:
            return "clear-any"
        if "manage-lease.sh clear " in command:
            return "clear"
        if "userdel" in command:
            return "userdel"
        if "apply-host-settings.sh" in command:
            return "apply"
        if "session-control.sh" in command:
            verb = command.split("session-control.sh", 1)[1].split()
            return verb[0] if verb else "other"
        return "other"

    def __call__(self, hostname, command, stdin_input=None, timeout=120):
        kind = self.kind_of(command)
        self.calls.append((hostname, kind))
        self.stdin.append(stdin_input)
        returncode, stdout, stderr = self.replies.get(kind, self.DEFAULTS.get(kind, (0, "", "")))
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr), f"avdadmin@{hostname}"


@pytest.fixture
def remote(app_module, monkeypatch):
    host = RemoteHost()
    monkeypatch.setattr(app_module, "run_remote_command", host)
    return host
