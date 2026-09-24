from __future__ import annotations

import os
import time
import uuid
from pathlib import Path

import pymssql
import pytest

from apply_scripts import apply_scripts, connect


ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "sql_queries"


def pytest_configure(config):
    if not os.environ.get("SQL_TEST_SERVER"):
        config.addinivalue_line("markers", "sqlserver: requires SQL_TEST_SERVER")


@pytest.fixture(scope="session")
def sql_env():
    server = os.environ.get("SQL_TEST_SERVER")
    if not server:
        pytest.skip("SQL_TEST_SERVER is unset; skipping SQL Server integration suite.")
    password = os.environ.get("SQL_TEST_PASSWORD")
    if not password:
        pytest.skip("SQL_TEST_PASSWORD is unset; skipping SQL Server integration suite.")
    return {"server": server, "user": os.environ.get("SQL_TEST_USER", "sa"), "password": password}


@pytest.fixture(scope="session")
def database_name(sql_env):
    db = "lb_sqltest_" + uuid.uuid4().hex[:12]
    master = connect(sql_env["server"], sql_env["user"], sql_env["password"], "master", autocommit=True)
    try:
        cur = master.cursor()
        cur.execute(f"CREATE DATABASE [{db}]")
        deadline = time.time() + 60
        while time.time() < deadline:
            cur.execute("SELECT state_desc FROM sys.databases WHERE name=%s", (db,))
            row = cur.fetchone()
            if row and row[0] == "ONLINE":
                break
            time.sleep(1)
        cur.execute(f"ALTER DATABASE [{db}] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE")
    finally:
        master.close()

    try:
        conn = connect(sql_env["server"], sql_env["user"], sql_env["password"], db)
        try:
            apply_scripts(conn, SQL_DIR)
            apply_scripts(conn, SQL_DIR)
        finally:
            conn.close()
        yield db
    finally:
        master = connect(sql_env["server"], sql_env["user"], sql_env["password"], "master", autocommit=True)
        try:
            cur = master.cursor()
            cur.execute(f"ALTER DATABASE [{db}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE")
            cur.execute(f"DROP DATABASE [{db}]")
        finally:
            master.close()


@pytest.fixture
def conn(sql_env, database_name):
    c = connect(sql_env["server"], sql_env["user"], sql_env["password"], database_name)
    clean_database(c)
    try:
        yield c
    finally:
        c.close()


@pytest.fixture
def second_conn(sql_env, database_name):
    made = []
    def factory(autocommit=False):
        c = connect(sql_env["server"], sql_env["user"], sql_env["password"], database_name, autocommit=autocommit)
        made.append(c)
        return c
    yield factory
    for c in made:
        c.close()


def clean_database(conn):
    cur = conn.cursor()
    for stmt in [
        "DELETE FROM dbo.VmUsers",
        "DELETE FROM dbo.AuditLog",
        "DELETE FROM dbo.HostHeartbeats",
        "DELETE FROM dbo.VirtualMachines",
        "DELETE FROM dbo.VmScalingActivityLog",
        "DELETE FROM dbo.VmScalingRules",
        "UPDATE dbo.LinuxHostSettings SET GracePeriodSeconds=1200, ReconcileIntervalSeconds=60, WatcherDebounceSeconds=10, WatcherSettleSeconds=2, IdleTimeoutSeconds=0, IdleWarningSeconds=120, ScreenLockEnabled=0, DisableLockScreen=1, ScreenIdleDelaySeconds=0, ScreenLockDelaySeconds=0, ScreenLockSettingsLocked=1, PreserveSessionsOnDisconnect=0, UpdatedBy=NULL WHERE SettingsScope='Global'",
        "INSERT INTO dbo.VmScalingRules (MinVMs, MaxVMs, ScaleUpRatio, ScaleUpIncrement, ScaleDownRatio, ScaleDownIncrement, StopMode) VALUES (2, 10, 70.00, 2, 30.00, 1, NULL)",
    ]:
        cur.execute(stmt)
    conn.commit()


def rows(conn, sql, params=()):
    cur = conn.cursor(as_dict=True)
    cur.execute(sql, params)
    result = cur.fetchall()
    while cur.nextset():
        pass
    return result


def one(conn, sql, params=()):
    result = rows(conn, sql, params)
    return result[0] if result else None


def exec_sql(conn, sql, params=()):
    cur = conn.cursor(as_dict=True)
    cur.execute(sql, params)
    try:
        result = cur.fetchall()
    except pymssql.OperationalError:
        result = []
    while cur.nextset():
        pass
    try:
        conn.commit()
    except pymssql.OperationalError as exc:
        if 'no corresponding BEGIN TRANSACTION' not in str(exc):
            raise
    return result


def add_vm(conn, hostname, power="On", net="Reachable", status="Available", username=None, avdhost=None, lease=None, cleanup=False, released_seconds=None, last_seconds=None, changed_minutes=None):
    cur = conn.cursor(as_dict=True)
    cur.execute(
        """
        INSERT INTO dbo.VirtualMachines (Hostname, IPAddress, PowerState, NetworkStatus, VmStatus, Username, AvdHost, LeaseId)
        OUTPUT INSERTED.VMID
        VALUES (%s, '10.0.0.1', %s, %s, %s, %s, %s, %s)
        """,
        (hostname, power, net, status, username, avdhost, lease),
    )
    vmid = cur.fetchone()["VMID"]
    if cleanup:
        cur.execute(
            "UPDATE dbo.VirtualMachines SET CleanupPending=1, CleanupUsername=%s, CleanupLeaseId=%s WHERE VMID=%s",
            (username or "cleanup", lease, vmid),
        )
    sets = []
    if released_seconds is not None:
        sets.append("ReleasedDate=DATEADD(SECOND, -%d, GETDATE())" % released_seconds)
    if last_seconds is not None:
        sets.append("LastUpdateDate=DATEADD(SECOND, -%d, GETDATE())" % last_seconds)
    if changed_minutes is not None:
        sets.append("PowerStateChangedDate=DATEADD(MINUTE, -%d, GETDATE())" % changed_minutes)
    if sets:
        cur.execute(f"UPDATE dbo.VirtualMachines SET {', '.join(sets)} WHERE VMID=%s", (vmid,))
    conn.commit()
    return vmid

