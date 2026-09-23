"""Execute migrations and competing transactions in a new local disposable SQL Server only.

Usage: python sql_queries\\tests\\run_sql_integration.py --docker
There is deliberately no server/connection-string option and no use of deployment credentials.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
import time
import unittest
import uuid

import pymssql


SCRIPTS = Path(__file__).resolve().parents[1]
TENANT = str(uuid.UUID("11111111-1111-4111-8111-111111111111"))
ACTOR = str(uuid.UUID("22222222-2222-4222-8222-222222222222"))


def docker(*args, env=None, timeout=30):
    result = subprocess.run(["docker", *args], capture_output=True, text=True, env=env, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Local Docker command failed: {args[0]}. {result.stderr.strip()}")
    return result.stdout.strip()


@contextmanager
def disposable_server():
    configured_host = os.environ.get("DOCKER_HOST")
    if configured_host and not configured_host.startswith(("unix://", "npipe://")):
        raise RuntimeError("Refusing a non-local Docker endpoint.")
    endpoint = json.loads(docker("context", "inspect", "--format", "{{json .Endpoints.docker.Host}}"))
    if not endpoint.startswith(("unix://", "npipe://")):
        raise RuntimeError("Refusing a non-local Docker context.")
    if docker("info", "--format", "{{.OSType}}") != "linux":
        raise RuntimeError("A local Linux Docker engine is required.")
    password = "Broker_Test_9!" + secrets.token_urlsafe(32)
    environment = {**os.environ, "MSSQL_SA_PASSWORD": password}
    container = None
    try:
        container = docker(
            "run", "--detach", "--rm", "--name", "linuxbroker-sql-test-" + uuid.uuid4().hex,
            "--label", "linuxbroker.disposable-test=true", "--publish", "127.0.0.1::1433",
            "--env", "ACCEPT_EULA=Y", "--env", "MSSQL_PID=Developer", "--env", "MSSQL_SA_PASSWORD",
            "mcr.microsoft.com/mssql/server:2022-latest", env=environment, timeout=600,
        )
        if not re.fullmatch(r"[0-9a-f]{64}", container):
            raise RuntimeError("Docker did not return an owned container ID.")
        address = docker("port", container, "1433/tcp")
        if not re.fullmatch(r"127\.0\.0\.1:[0-9]+", address):
            raise RuntimeError("The disposable SQL port is not loopback-only.")
        connection = {
            "server": "127.0.0.1", "port": int(address.rsplit(":", 1)[1]), "user": "sa",
            "password": password, "database": "master", "login_timeout": 2, "timeout": 30,
            "autocommit": True,
        }
        deadline = time.monotonic() + 120
        while True:
            try:
                with pymssql.connect(**connection) as sql:
                    with sql.cursor() as cursor:
                        cursor.execute("SELECT 1")
                        cursor.fetchone()
                break
            except pymssql.Error:
                if time.monotonic() >= deadline:
                    raise RuntimeError("The disposable SQL Server did not become ready.") from None
                time.sleep(2)
        yield connection
    finally:
        if container and re.fullmatch(r"[0-9a-f]{64}", container):
            docker("stop", "--time", "10", container, timeout=30)


class SqlIntegration(unittest.TestCase):
    server = None

    def setUp(self):
        self.database = "BrokerTest_" + uuid.uuid4().hex[:16]
        self.execute(f"CREATE DATABASE [{self.database}]", master=True)
        self.apply()

    def tearDown(self):
        self.execute(f"DROP DATABASE [{self.database}]", master=True)

    def execute(self, sql, parameters=(), *, master=False):
        configuration = {**self.server, "database": "master" if master else self.database}
        with pymssql.connect(**configuration) as connection:
            with connection.cursor(as_dict=True) as cursor:
                cursor.execute(sql, parameters)
                # Some migration batches and legacy procedures have no result set.
                while cursor.description is None:
                    if not cursor.nextset():
                        return []
                return cursor.fetchall()

    def proc(self, name, **values):
        sql = f"EXEC dbo.{name} " + ", ".join(f"@{key} = %s" for key in values)
        return self.execute(sql, tuple(values.values()))

    def apply(self, first=1, last=999):
        for path in sorted(SCRIPTS.glob("*.sql")):
            number = int(path.name.split("_", 1)[0])
            if not first <= number <= last:
                continue
            text = path.read_text(encoding="utf-8-sig")
            text = re.sub(r"(?im)^(\s*)(?:CREATE|ALTER)\s+PROCEDURE\b", r"\1CREATE OR ALTER PROCEDURE", text)
            for batch in re.split(r"(?im)^\s*GO\s*(?:--[^\n]*)?$", text):
                if batch.strip():
                    try:
                        self.execute(batch)
                    except pymssql.Error as exc:
                        raise AssertionError(f"Migration {path.name} failed: {exc}") from exc

    def host(self, number=1):
        hostname = f"linux-{number:02d}"
        row = self.proc("RegisterLinuxHostVm", Hostname=hostname, IPAddress=f"192.0.2.{number}")[0]
        self.proc(
            "RegisterBrokerHost", TenantId=TENANT, ObjectId=str(uuid.uuid4()), Hostname=hostname,
            ResourceId=f"/subscriptions/{TENANT}/resourceGroups/test/providers/Microsoft.Compute/virtualMachines/{hostname}",
        )
        return row["VMID"]

    def checkout(self, subject=ACTOR):
        return self.proc("BeginBrokerCheckout", TenantId=TENANT, ObjectId=subject, AvdHost="avd-test")[0]

    def complete(self, row, outcome="ready"):
        return self.proc("CompleteBrokerOperation", VMID=row["VMID"], OperationId=row["OperationId"],
                         LeaseGeneration=row["LeaseGeneration"], Outcome=outcome)[0]

    def observe(self, row, state):
        return self.proc("ObserveBrokerSession", Hostname=row["Hostname"], LeaseId=row["LeaseId"],
                         LeaseGeneration=row["LeaseGeneration"], State=state)[0]

    def cleanup(self, row, reason="admin"):
        return self.proc("BeginBrokerCleanup", VMID=row["VMID"], ExpectedLeaseId=row["LeaseId"],
                         ExpectedLeaseGeneration=row["LeaseGeneration"], Reason=reason,
                         ActorTenantId=TENANT, ActorObjectId=ACTOR)[0]

    def race(self, operations):
        barrier = threading.Barrier(len(operations))

        def invoke(operation):
            barrier.wait(timeout=10)
            return operation()

        with ThreadPoolExecutor(max_workers=len(operations)) as workers:
            return list(workers.map(invoke, operations))

    def test_fresh_install_and_full_rerun_preserve_temporal_schema(self):
        self.host()
        row = self.checkout()
        self.complete(row)
        self.apply()
        state = self.proc("GetVmDetails", VMID=row["VMID"])[0]
        self.assertEqual(str(state["LeaseId"]).lower(), str(row["LeaseId"]).lower())
        self.assertEqual(state["LeaseGeneration"], row["LeaseGeneration"])
        self.assertEqual(state["Username"], row["Username"])
        tables = self.execute("SELECT temporal_type FROM sys.tables WHERE name = 'VirtualMachines'")
        self.assertEqual(tables[0]["temporal_type"], 2)

    def test_reviewed_legacy_bindings_preserve_profile_and_refuse_unresolved_owners(self):
        # Re-create just this owned test database to exercise the pre-040 schema.
        self.execute(f"DROP DATABASE [{self.database}]", master=True)
        self.execute(f"CREATE DATABASE [{self.database}]", master=True)
        self.apply(last=39)
        legacy_lease = str(uuid.uuid4())
        self.execute("INSERT dbo.VmUsers(uid, username) VALUES (2042, 'legacy_profile')")
        self.execute("INSERT dbo.VirtualMachines(Hostname, PowerState, NetworkStatus, VmStatus, Username, LeaseId) "
                     "VALUES ('linux-01', 'On', 'Reachable', 'CheckedOut', 'legacy_profile', %s)", (legacy_lease,))
        self.apply(first=40)
        with self.assertRaises(pymssql.Error):
            self.proc("GetBrokerLeaseMigrationState", Hostname="linux-01")
        self.proc("BindBrokerUser", TenantId=TENANT, ObjectId=ACTOR, Username="legacy_profile", Uid=2042)
        self.proc("BindBrokerUser", TenantId=TENANT, ObjectId=ACTOR, Username="legacy_profile", Uid=2042)
        row = self.proc("GetBrokerLeaseMigrationState", Hostname="linux-01")[0]
        self.assertEqual(set(row), {"Username", "Uid", "LeaseId", "LeaseGeneration"})
        self.assertEqual((row["Username"], row["Uid"], str(row["LeaseId"]).lower(), row["LeaseGeneration"]),
                         ("legacy_profile", 2042, legacy_lease, 1))
        for subject, uid, tenant in ((str(uuid.uuid4()), 2042, TENANT), (ACTOR, 2043, TENANT), (ACTOR, 2042, str(uuid.uuid4()))):
            with self.assertRaises(pymssql.Error):
                self.proc("BindBrokerUser", TenantId=tenant, ObjectId=subject, Username="legacy_profile", Uid=uid)
        self.execute("INSERT dbo.VmUsers(uid,username) VALUES(2043,'Legacy_Profile-1'),(2044,'Legacy.Profile')")
        upper_subject = str(uuid.uuid4())
        self.proc("BindBrokerUser", TenantId=TENANT, ObjectId=upper_subject, Username="Legacy_Profile-1", Uid=2043)
        self.assertEqual(self.proc("ResolveBrokerUser", TenantId=TENANT, ObjectId=upper_subject)[0]["Username"], "Legacy_Profile-1")
        with self.assertRaises(pymssql.Error):
            self.proc("BindBrokerUser", TenantId=TENANT, ObjectId=str(uuid.uuid4()), Username="Legacy.Profile", Uid=2044)
        unbound = self.execute("SELECT username,TenantId,ObjectId FROM dbo.VmUsers WHERE uid=2044")[0]
        self.assertEqual(unbound["username"], "Legacy.Profile")
        self.assertIsNone(unbound["TenantId"])
        with self.assertRaises(pymssql.Error):
            self.execute("UPDATE dbo.VmUsers SET username = 'renamed_profile' WHERE uid = 2042")
        with self.assertRaises(pymssql.Error):
            self.execute("DELETE dbo.VmUsers WHERE uid = 2042")

    def test_simultaneous_uid_allocation_and_no_legacy_name_claiming(self):
        self.host()
        self.execute("INSERT dbo.VmUsers(uid, username) VALUES (2099, 'broker_2100')")
        owners = [str(uuid.uuid4()) for _ in range(12)]
        rows = self.race([
            lambda owner=owner: self.proc("ResolveBrokerUser", TenantId=TENANT, ObjectId=owner)[0]
            for owner in owners
        ])
        self.assertEqual(len({row["Uid"] for row in rows}), 12)
        self.assertEqual(len({row["Username"] for row in rows}), 12)
        self.assertNotIn("broker_2100", {row["Username"] for row in rows})
        same = self.race([lambda: self.proc("ResolveBrokerUser", TenantId=TENANT, ObjectId=owners[0])[0] for _ in range(8)])
        self.assertEqual(len({(row["Username"], row["Uid"]) for row in same}), 1)

    def test_different_owners_cannot_overallocate_or_share_a_host(self):
        self.host(1)
        self.host(2)
        rows = self.race([lambda owner=str(uuid.uuid4()): self.checkout(owner) for _ in range(12)])
        successes = [row for row in rows if row["Outcome"] == "Ok"]
        self.assertEqual(len(successes), 2)
        self.assertEqual(len({row["VMID"] for row in successes}), 2)
        self.assertEqual(len({row["Username"] for row in successes}), 2)
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 0)

    def test_uid_allocation_skips_reserved_ids_even_after_name_collisions(self):
        self.host()
        self.execute("INSERT dbo.VmUsers(uid,username) VALUES(65532,'broker_65533')")
        rows = self.race([
            lambda owner=str(uuid.uuid4()): self.proc("ResolveBrokerUser", TenantId=TENANT, ObjectId=owner)[0]
            for _ in range(8)
        ])
        self.assertEqual(len({row["Uid"] for row in rows}), 8)
        self.assertEqual(min(row["Uid"] for row in rows), 65536)
        self.assertFalse({65534, 65535} & {row["Uid"] for row in rows})
        self.execute("INSERT dbo.VmUsers(uid,username) VALUES(65534,'legacy_reserved_a'),(65535,'legacy_reserved_b')")
        for uid, username in ((65534, "legacy_reserved_a"), (65535, "legacy_reserved_b")):
            with self.assertRaises(pymssql.Error):
                self.proc("BindBrokerUser", TenantId=TENANT, ObjectId=str(uuid.uuid4()), Username=username, Uid=uid)
            with self.assertRaises(pymssql.Error):
                self.execute("UPDATE dbo.VmUsers SET TenantId=%s,ObjectId=%s WHERE uid=%s", (TENANT, str(uuid.uuid4()), uid))
            unchanged = self.execute("SELECT username,TenantId FROM dbo.VmUsers WHERE uid=%s", (uid,))[0]
            self.assertEqual(unchanged["username"], username)
            self.assertIsNone(unchanged["TenantId"])
        self.apply(first=40, last=40)

    def test_reconnect_rotation_is_serialized_and_failed_rotation_keeps_assignment(self):
        self.host()
        initial = self.checkout()
        self.complete(initial)
        self.observe(initial, "disconnected")
        rows = self.race([self.checkout for _ in range(10)])
        successes = [row for row in rows if row["Outcome"] == "Ok"]
        self.assertEqual(len(successes), 1)
        current = successes[0]
        self.assertEqual(str(current["LeaseId"]), str(initial["LeaseId"]))
        self.assertEqual((current["Username"], current["Uid"]), (initial["Username"], initial["Uid"]))
        self.proc("FailBrokerOperation", VMID=current["VMID"], OperationId=current["OperationId"],
                  LeaseGeneration=current["LeaseGeneration"], ErrorCode="HostUncertain")
        state = self.proc("GetVmDetails", VMID=current["VMID"])[0]
        self.assertNotEqual(state["VmStatus"], "Available")
        retry = self.checkout()
        self.assertEqual(retry["Outcome"], "Ok")
        self.assertGreater(retry["LeaseGeneration"], current["LeaseGeneration"])
        self.assertEqual(self.complete(current)["Outcome"], "Conflict")
        self.assertEqual(self.complete(retry)["Outcome"], "Ok")

    def test_grace_uses_disconnect_time_and_automatic_reconnect_cancels_expiry(self):
        self.host()
        self.proc("UpdateLinuxHostSettings", GracePeriodSeconds=73)
        row = self.checkout()
        self.complete(row)
        self.observe(row, "disconnected")
        before = self.proc("GetVmDetails", VMID=row["VMID"])[0]["DisconnectedAt"]
        self.observe(row, "disconnected")
        self.proc("UpdateVmAttributes", VMID=row["VMID"], NetworkStatus="Reachable")
        after = self.proc("GetVmDetails", VMID=row["VMID"])[0]["DisconnectedAt"]
        self.assertEqual(before, after)
        for elapsed, eligible in ((68, False), (73, True), (78, True)):
            self.execute("UPDATE dbo.VirtualMachines SET DisconnectedAt = DATEADD(SECOND, %s, SYSUTCDATETIME()) WHERE VMID = %s",
                         (-elapsed, row["VMID"]))
            self.assertEqual(bool(self.proc("ReturnReleasedVms")), eligible)
        self.assertEqual(self.observe(row, "active")["Outcome"], "Ok")
        self.assertEqual(self.proc("ReturnReleasedVms"), [])
        self.assertIsNone(self.proc("GetVmDetails", VMID=row["VMID"])[0]["DisconnectedAt"])

    def test_cleanup_and_checkout_races_never_reassign_before_completion(self):
        self.host()
        for _ in range(6):
            initial = self.checkout()
            self.complete(initial)
            self.observe(initial, "disconnected")
            cleanup, reconnect = self.race([lambda: self.cleanup(initial), self.checkout])
            self.assertEqual(sum(row["Outcome"] == "Ok" for row in (cleanup, reconnect)), 1)
            self.assertNotEqual(self.checkout(str(uuid.uuid4()))["Outcome"], "Ok")
            winner = cleanup if cleanup["Outcome"] == "Ok" else reconnect
            self.assertEqual(self.observe(initial, "active")["Outcome"], "Conflict")
            self.complete(winner, "cleaned" if winner is cleanup else "ready")

    def test_cleanup_failure_stale_finalization_and_inventory_mutations_fail_closed(self):
        vmid = self.host()
        initial = self.checkout()
        self.complete(initial)
        reserved = self.cleanup(initial)
        self.proc("FailBrokerOperation", VMID=vmid, OperationId=reserved["OperationId"],
                  LeaseGeneration=reserved["LeaseGeneration"], ErrorCode="MountBusy")
        self.assertEqual(self.proc("UpdateVmAttributes", VMID=vmid, PowerState="On", VmStatus="Available")[0]["Outcome"], "Conflict")
        self.assertEqual(self.proc("DeleteVm", VMID=vmid)[0]["Outcome"], "Conflict")
        self.assertEqual(self.checkout()["Outcome"], "Conflict")
        self.assertTrue(self.proc("ReturnReleasedVms"))
        retried = self.cleanup(reserved)
        self.assertEqual(retried["Outcome"], "Ok")
        self.assertEqual(self.complete(reserved, "cleaned")["Outcome"], "Conflict")
        self.assertEqual(self.complete(retried, "cleaned")["Outcome"], "Ok")
        self.assertEqual(self.complete(retried, "cleaned")["Outcome"], "Ok")
        next_lease = self.checkout(str(uuid.uuid4()))
        self.assertEqual(next_lease["Outcome"], "Ok")
        self.assertGreater(next_lease["LeaseGeneration"], retried["LeaseGeneration"])
        self.assertEqual(self.complete(retried, "cleaned")["Outcome"], "Conflict")

    def test_power_scaling_reserves_only_unowned_hosts_and_never_clears_leases(self):
        vmid = self.host(1)
        second = self.host(2)
        lease = self.checkout()
        self.complete(lease)
        self.proc("UpdateScalingRule", RuleID=1, MinVMs=1, MaxVMs=4, ScaleUpRatio=100, ScaleUpIncrement=1,
                  ScaleDownRatio=90, ScaleDownIncrement=1)
        actions = self.proc("TriggerScalingLogic", ActorTenantId=TENANT, ActorObjectId=ACTOR)
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions[0]["VMID"], second)
        self.assertEqual(actions[0]["ActionType"], "PowerOff")
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 0)
        self.complete(actions[0], "Off")
        state = self.proc("GetVmDetails", VMID=vmid)[0]
        self.assertEqual(str(state["LeaseId"]), str(lease["LeaseId"]))
        self.assertEqual(state["VmStatus"], "CheckedOut")
        self.execute("UPDATE dbo.VirtualMachines SET PowerState='Off' WHERE VMID=%s", (vmid,))
        starts = self.proc("TriggerScalingLogic", ActorTenantId=TENANT, ActorObjectId=ACTOR)
        self.assertEqual(len(starts), 1)
        self.assertEqual(starts[0]["VMID"], second)
        self.assertEqual(starts[0]["ActionType"], "PowerOn")
        self.complete(starts[0], "On")
        state = self.proc("GetVmDetails", VMID=vmid)[0]
        self.assertEqual(str(state["LeaseId"]), str(lease["LeaseId"]))
        self.assertEqual(state["VmStatus"], "CheckedOut")
        self.assertEqual(self.proc("GetVmDetails", VMID=second)[0]["NetworkStatus"], "Unreachable")

    def test_abandoned_operation_boundaries_and_cleanup_cancellation(self):
        self.host()
        initial = self.checkout()
        self.execute("UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-295,SYSUTCDATETIME()) WHERE OperationId=%s",
                     (initial["OperationId"],))
        self.assertEqual(self.checkout()["Outcome"], "Conflict")
        self.execute("UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-300,SYSUTCDATETIME()) WHERE OperationId=%s",
                     (initial["OperationId"],))
        retry = self.checkout()
        self.assertEqual(retry["Outcome"], "Ok")
        self.assertGreater(retry["LeaseGeneration"], initial["LeaseGeneration"])
        self.assertEqual(self.complete(initial)["Outcome"], "Conflict")
        self.complete(retry)
        cleanup = self.cleanup(retry)
        self.execute("UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-295,SYSUTCDATETIME()) WHERE OperationId=%s",
                     (cleanup["OperationId"],))
        self.assertEqual(self.proc("ReturnReleasedVms"), [])
        self.execute("UPDATE dbo.BrokerLeaseOperations SET StartedAt=DATEADD(SECOND,-300,SYSUTCDATETIME()) WHERE OperationId=%s",
                     (cleanup["OperationId"],))
        self.assertEqual(len(self.proc("ReturnReleasedVms")), 1)
        recovered = self.cleanup(cleanup)
        self.assertEqual(self.complete(cleanup, "cleaned")["Outcome"], "Conflict")
        self.assertEqual(self.complete(recovered, "active")["Outcome"], "Ok")
        state = self.proc("GetVmDetails", VMID=initial["VMID"])[0]
        self.assertEqual(state["VmStatus"], "CheckedOut")
        self.assertEqual(str(state["LeaseId"]), str(initial["LeaseId"]))
        self.assertIsNone(state["DisconnectedAt"])
        self.observe(recovered, "logged_off")
        logoff = self.cleanup(recovered, "logged_off")
        self.assertEqual(self.complete(logoff, "disconnected")["Outcome"], "Ok")
        state = self.proc("GetVmDetails", VMID=initial["VMID"])[0]
        self.assertEqual(state["VmStatus"], "Released")
        self.assertEqual(state["SessionState"], "disconnected")
        self.assertEqual(self.proc("ReturnReleasedVms"), [])

    def test_deleted_inventory_does_not_recycle_host_generation(self):
        vmid = self.host()
        binding = self.execute("SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Hostname='linux-01' AND Active=1")[0]
        lease = self.checkout()
        self.complete(lease)
        cleanup = self.cleanup(lease)
        self.complete(cleanup, "cleaned")
        self.proc("DeleteVm", VMID=vmid)
        self.proc("RegisterLinuxHostVm", Hostname="linux-01", IPAddress="192.0.2.1")
        self.assertEqual(self.checkout()["Outcome"], "Unavailable")
        self.proc("RegisterBrokerHost", **binding)
        next_lease = self.checkout()
        self.assertEqual(next_lease["Outcome"], "Ok")
        self.assertGreater(next_lease["LeaseGeneration"], cleanup["LeaseGeneration"])

    def test_manual_recreated_or_changed_endpoint_requires_trusted_reenrollment(self):
        vmid = self.host()
        binding = self.execute("SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Hostname='linux-01' AND Active=1")[0]
        lease = self.checkout()
        self.complete(lease)
        cleanup = self.cleanup(lease)
        self.complete(cleanup, "cleaned")
        self.execute("CREATE USER BrokerManagementTest WITHOUT LOGIN; ALTER ROLE BrokerApiRuntime ADD MEMBER BrokerManagementTest;")
        self.execute("EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.DeleteVm @VMID=%s; REVERT;", (vmid,))
        manual = self.execute(
            "EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.AddVm @Hostname='LiNuX-01',@IPAddress='203.0.113.77',"
            "@PowerState='On',@NetworkStatus='Reachable',@VmStatus='Available'; REVERT;",
        )[0]
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 0)
        self.assertEqual(self.checkout(), {"Outcome": "Unavailable"})
        self.assertEqual(self.proc("GetBrokerHost", TenantId=binding["TenantId"], ObjectId=binding["ObjectId"]), [])
        with self.assertRaises(pymssql.Error):
            self.proc("RegisterBrokerHost", **binding)
        with self.assertRaises(pymssql.Error):
            self.execute("EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.RegisterLinuxHostVm @Hostname='linux-01',@IPAddress='203.0.113.77'; REVERT;")
        with self.assertRaises(pymssql.Error):
            self.execute(
                "EXECUTE AS USER='BrokerManagementTest'; EXEC dbo.RegisterBrokerHost @TenantId=%s,@ObjectId=%s,@Hostname=%s,@ResourceId=%s; REVERT;",
                (binding["TenantId"], binding["ObjectId"], binding["Hostname"], binding["ResourceId"]),
            )
        with self.assertRaises(pymssql.Error):
            self.execute("EXECUTE AS USER='BrokerManagementTest'; UPDATE dbo.BrokerHosts SET Active=1 WHERE Hostname='linux-01'; REVERT;")
        with self.assertRaises(pymssql.Error):
            self.execute(
                "EXECUTE AS USER='BrokerManagementTest'; "
                "INSERT dbo.BrokerHostInventory(Hostname,VMID,IPAddress,ImportedAt) VALUES('linux-01',%s,'203.0.113.77',SYSUTCDATETIME()); REVERT;",
                (manual["NewVMID"],),
            )
        self.proc("RegisterLinuxHostVm", Hostname="linux-01", IPAddress="192.0.2.1")
        self.assertEqual(self.checkout()["Outcome"], "Unavailable")
        self.proc("RegisterBrokerHost", **binding)
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 1)
        reenrolled = self.checkout()
        self.assertEqual(reenrolled["Outcome"], "Ok")
        self.assertEqual(reenrolled["VMID"], manual["NewVMID"])
        self.assertEqual(reenrolled["IPAddress"], "192.0.2.1")
        self.assertGreater(reenrolled["LeaseGeneration"], cleanup["LeaseGeneration"])
        with self.assertRaises(pymssql.Error):
            self.proc("RegisterLinuxHostVm", Hostname="linux-01", IPAddress="192.0.2.2")
        self.assertEqual(len(self.proc("GetBrokerHost", TenantId=binding["TenantId"], ObjectId=binding["ObjectId"])), 1)
        self.complete(reenrolled)
        returned = self.cleanup(reenrolled)
        self.complete(returned, "cleaned")
        self.execute("UPDATE dbo.VirtualMachines SET IPAddress='203.0.113.88' WHERE VMID=%s", (reenrolled["VMID"],))
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 0)
        self.assertEqual(self.checkout()["Outcome"], "Unavailable")
        self.execute("UPDATE dbo.VirtualMachines SET IPAddress='192.0.2.1' WHERE VMID=%s", (reenrolled["VMID"],))
        with self.assertRaises(pymssql.Error):
            self.proc("RegisterBrokerHost", **binding)
        self.proc("RegisterLinuxHostVm", Hostname="linux-01", IPAddress="192.0.2.2")
        self.proc("RegisterBrokerHost", **binding)
        updated = self.checkout()
        self.assertEqual(updated["IPAddress"], "192.0.2.2")
        self.assertGreater(updated["LeaseGeneration"], returned["LeaseGeneration"])
        self.complete(updated)
        final_cleanup = self.cleanup(updated)
        self.complete(final_cleanup, "cleaned")
        racing = self.race([lambda: self.proc("DeleteVm", VMID=updated["VMID"])[0], self.checkout])
        self.assertEqual(sum(row["Outcome"] == "Ok" for row in racing), 1)

    def test_existing_enrollment_upgrade_preserves_lease_but_requires_endpoint_import(self):
        self.execute(f"DROP DATABASE [{self.database}]", master=True)
        self.execute(f"CREATE DATABASE [{self.database}]", master=True)
        self.apply(last=45)
        self.host()
        binding = self.execute("SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Active=1")[0]
        lease = self.checkout()
        self.complete(lease)
        self.apply(first=46)
        self.assertEqual(self.checkout()["Outcome"], "Unavailable")
        state = self.proc("GetBrokerLeaseMigrationState", Hostname="linux-01")[0]
        self.assertEqual(str(state["LeaseId"]), str(lease["LeaseId"]))
        self.assertEqual(state["LeaseGeneration"], lease["LeaseGeneration"])
        self.assertEqual(state["Username"], lease["Username"])
        with self.assertRaises(pymssql.Error):
            self.proc("RegisterBrokerHost", **binding)
        self.proc("RegisterLinuxHostVm", Hostname="linux-01", IPAddress="192.0.2.1")
        self.proc("RegisterBrokerHost", **binding)
        self.proc("RegisterBrokerHost", **binding)
        reconnect = self.checkout()
        self.assertEqual(reconnect["Outcome"], "Ok")
        self.assertEqual(str(reconnect["LeaseId"]), str(lease["LeaseId"]))
        self.assertGreater(reconnect["LeaseGeneration"], lease["LeaseGeneration"])

    def test_runtime_role_can_execute_broker_operations_but_not_bind_or_mutate_tables(self):
        self.host()
        self.execute("CREATE USER BrokerRuntimeTest WITHOUT LOGIN; ALTER ROLE BrokerApiRuntime ADD MEMBER BrokerRuntimeTest;")
        rows = self.execute("EXECUTE AS USER = 'BrokerRuntimeTest'; EXEC dbo.GetVms; REVERT;")
        self.assertEqual(len(rows), 1)
        checked = self.execute(
            "EXECUTE AS USER = 'BrokerRuntimeTest'; "
            "EXEC dbo.BeginBrokerCheckout @TenantId=%s, @ObjectId=%s, @AvdHost='avd-test'; REVERT;",
            (TENANT, ACTOR),
        )[0]
        self.assertEqual(checked["Outcome"], "Ok")
        self.complete(checked)
        host = self.execute("SELECT TenantId,ObjectId,Hostname,ResourceId FROM dbo.BrokerHosts WHERE Active=1")[0]
        for statement, parameters in (
            ("UPDATE dbo.VirtualMachines SET NetworkStatus = 'Reachable'", ()),
            ("EXEC dbo.GetBrokerLeaseMigrationState @Hostname='linux-01'", ()),
            ("EXEC dbo.BindBrokerUser @TenantId=%s, @ObjectId=%s, @Username=%s, @Uid=%s",
             (TENANT, ACTOR, checked["Username"], checked["Uid"])),
            ("EXEC dbo.RegisterBrokerHost @TenantId=%s, @ObjectId=%s, @Hostname=%s, @ResourceId=%s",
             (host["TenantId"], host["ObjectId"], host["Hostname"], host["ResourceId"])),
        ):
            with self.assertRaises(pymssql.Error):
                self.execute("EXECUTE AS USER = 'BrokerRuntimeTest'; " + statement + "; REVERT;", parameters)

    def test_generation_bound_is_json_safe_and_exhaustion_never_wraps(self):
        vmid = self.host()
        maximum = 9007199254740991
        for invalid in (maximum + 1, 9223372036854775807):
            with self.assertRaises(pymssql.Error):
                self.execute("UPDATE dbo.VirtualMachines SET LeaseGeneration=%s WHERE VMID=%s", (invalid, vmid))
        self.execute("INSERT dbo.BrokerHostGenerations(Hostname,Generation) VALUES('linux-01',%s)", (maximum - 1,))
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 1)
        advance = "SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC dbo.LockBrokerState; EXEC dbo.AdvanceBrokerGeneration @VMID=%s; COMMIT;"
        self.execute(advance, (vmid,))
        self.assertEqual(self.proc("GetVmDetails", VMID=vmid)[0]["LeaseGeneration"], maximum)
        self.assertEqual(self.proc("GetVmSummary")[0]["Ready"], 0)
        self.assertEqual(self.checkout()["Outcome"], "Unavailable")
        with self.assertRaises(pymssql.Error):
            self.execute(advance, (vmid,))
        self.assertEqual(self.proc("GetVmDetails", VMID=vmid)[0]["LeaseGeneration"], maximum)
        for invalid in (maximum + 1, 9223372036854775807):
            with self.assertRaises(pymssql.Error):
                self.execute("UPDATE dbo.BrokerHostGenerations SET Generation=%s WHERE Hostname='linux-01'", (invalid,))
            with self.assertRaises(pymssql.Error):
                self.execute(
                    "INSERT dbo.BrokerLeaseOperations(OperationId,VMID,LeaseGeneration,Kind,State,ActorTenantId,ActorObjectId) "
                    "VALUES(NEWID(),%s,%s,'PowerOn','Running',%s,%s)", (vmid, invalid, TENANT, ACTOR),
                )
        self.proc("UpdateVmAttributes", VMID=vmid, PowerState="Off")
        self.assertEqual(self.proc("TriggerScalingLogic", ActorTenantId=TENANT, ActorObjectId=ACTOR), [])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker", action="store_true", required=True, help="Start an owned, loopback-only SQL container.")
    parser.parse_args()
    try:
        with disposable_server() as server:
            SqlIntegration.server = server
            result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SqlIntegration))
            return 0 if result.wasSuccessful() else 1
    except (RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print(f"SQL runtime unavailable or interrupted: {exc}", file=sys.stderr)
        print("No SQL transaction/concurrency success is claimed.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
