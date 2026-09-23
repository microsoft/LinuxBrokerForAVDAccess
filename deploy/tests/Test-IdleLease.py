"""Cleaned tombstones are immutable fencing evidence, not disposable migration residue."""

from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest
from unittest import mock


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("broker_idle_lease", REPO / "deploy" / "Test-BrokerIdleLease.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


def tombstone():
    return {
        "username": "ExistingProfile", "uid": 10001,
        "leaseId": "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
        "leaseGeneration": 7, "operationId": "aaaaaaaa-aaaa-4aaa-8aaa-000000000002",
        "phase": "cleaned", "hadSession": True, "gateClosed": False,
    }


class FakeManager:
    def __init__(self, state, marker, account=None, uid_account=False, mount=None):
        self.paths = types.SimpleNamespace(state=state, homes=state / "home")
        self.owner_uid = 0
        self.marker = state / "lease.json"
        self.data = marker
        self.residual_account = account
        self.uid_account = uid_account
        self.mount = mount
        self.lock_count = 0
        if marker is not None:
            self.marker.write_bytes(json.dumps(marker, sort_keys=True).encode())

    @contextmanager
    def locked(self):
        self.lock_count += 1
        yield

    def read(self):
        return self.data

    def account(self, username):
        return self.residual_account

    def command(self, *arguments, allowed):
        if arguments != ("getent", "passwd", str(self.data["uid"])) or allowed != (0, 2):
            raise AssertionError("Unexpected host command.")
        return types.SimpleNamespace(returncode=0 if self.uid_account else 2)

    def mount_info(self, path, require_leaf):
        if path != self.paths.homes / self.data["username"] or require_leaf is not True:
            raise AssertionError("The corresponding bind home must be checked as a leaf.")
        return self.mount


class IdleLeaseTests(unittest.TestCase):
    def setUp(self):
        parent = REPO / "deploy" / ".artifacts"
        parent.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="idle-lease-test-", dir=str(parent))
        self.state = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def evidence(self, manager, fence=10):
        return {
            "kind": "cleaned", "username": manager.data["username"], "uid": manager.data["uid"],
            "fence": fence, "sha256": hashlib.sha256(manager.marker.read_bytes()).hexdigest(),
        }

    def verify(self, expected, manager):
        # Filesystem ownership is independently covered below; no root operations occur in this fixture.
        original_lstat = Path.lstat

        def marker_lstat(path):
            if path == manager.marker:
                return types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
            return original_lstat(path)

        with mock.patch.object(idle, "protected_state"), mock.patch.object(Path, "lstat", marker_lstat):
            return idle.verify_idle(expected, manager)

    def test_cleaned_tombstone_is_preserved_and_rerunnable(self):
        marker = tombstone()
        marker.update({
            "gateBackend": "freezer-v1", "gateRestartRequired": False, "gateTerminated": False,
            "gateBootId": "aaaaaaaa-aaaa-4aaa-8aaa-000000000003",
        })
        manager = FakeManager(self.state, marker)
        original = manager.marker.read_bytes()
        evidence = self.evidence(manager)
        self.verify(evidence, manager)
        self.verify(evidence, manager)
        self.assertEqual(manager.lock_count, 2)
        self.assertEqual(manager.marker.read_bytes(), original)

    def test_sql_fence_may_exceed_tombstone_after_power_operations(self):
        manager = FakeManager(self.state, tombstone())
        self.verify(self.evidence(manager, fence=100), manager)
        with self.assertRaises(idle.IdleLeaseError):
            self.verify(self.evidence(manager, fence=6), manager)

    def test_identity_must_match_retained_sql_exactly(self):
        manager = FakeManager(self.state, tombstone())
        for key, value in (("username", "existingprofile"), ("uid", 10002)):
            with self.subTest(key=key):
                evidence = self.evidence(manager)
                evidence[key] = value
                with self.assertRaises(idle.IdleLeaseError):
                    self.verify(evidence, manager)

    def test_changed_marker_is_rejected_under_host_lock(self):
        manager = FakeManager(self.state, tombstone())
        evidence = self.evidence(manager)
        manager.marker.write_bytes(manager.marker.read_bytes() + b"\n")
        with self.assertRaisesRegex(idle.IdleLeaseError, "changed"):
            self.verify(evidence, manager)
        self.assertEqual(manager.lock_count, 1)

    def test_nonterminal_or_unresolved_gate_markers_are_not_idle(self):
        for field, value in (("phase", "ready"), ("phase", "provisioning"), ("phase", "cleanup"),
                             ("gateClosed", True), ("operationId", None),
                             ("gateRestartRequired", True), ("gateTerminated", True),
                             ("gateBackend", "unverified-fallback"),
                             ("gateBootId", "invalid-boot-identity"),
                             ("operationId", "00000000-0000-0000-0000-000000000000")):
            with self.subTest(field=field, value=value):
                marker = tombstone()
                marker[field] = value
                with self.assertRaises(idle.IdleLeaseError):
                    idle.validate_tombstone(marker)

    def test_remaining_account_uid_or_mount_blocks_reuse(self):
        for options in ({"account": {"uid": 10001}}, {"uid_account": True}, {"mount": {"target": "home"}}):
            with self.subTest(options=options):
                manager = FakeManager(self.state, tombstone(), **options)
                before = manager.marker.read_bytes()
                with self.assertRaises(idle.IdleLeaseError):
                    self.verify(self.evidence(manager), manager)
                self.assertEqual(manager.marker.read_bytes(), before)

    def test_absence_does_not_accept_a_new_marker(self):
        absent = FakeManager(self.state, None)
        self.verify({"kind": "absent"}, absent)
        changed = FakeManager(self.state, tombstone())
        with self.assertRaises(idle.IdleLeaseError):
            self.verify({"kind": "absent"}, changed)

    def test_legacy_markers_block_idle_but_state_lock_files_do_not(self):
        legacy = self.state / "leases"
        legacy.mkdir()
        (self.state / "lease.lock").write_text("lock")
        (self.state / "reconcile.lock").write_text("lock")
        original_lstat = Path.lstat

        def protected_lstat(path):
            result = original_lstat(path)
            if path.is_dir():
                return types.SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=0)
            return result

        with mock.patch.object(Path, "lstat", protected_lstat):
            idle.protected_state(self.state, 0)
            (legacy / "other.lease").write_text("legacy")
            with self.assertRaisesRegex(idle.IdleLeaseError, "legacy lease"):
                idle.protected_state(self.state, 0)
        self.assertTrue((self.state / "lease.lock").exists())
        self.assertTrue((self.state / "reconcile.lock").exists())

    def test_inspection_returns_only_minimal_metadata_not_full_marker(self):
        manager = FakeManager(self.state, tombstone())
        metadata = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0)
        with mock.patch.object(idle, "protected_state"), mock.patch.object(idle.os, "fstat", return_value=metadata), \
                mock.patch.object(Path, "lstat", return_value=metadata):
            observed = idle.inspect_marker(self.state)
        self.assertEqual(set(observed), {"kind", "username", "uid", "generation", "sha256"})
        self.assertNotIn("leaseId", observed)
        self.assertNotIn("operationId", observed)
        self.assertEqual(observed["sha256"], hashlib.sha256(manager.marker.read_bytes()).hexdigest())

    def test_unprotected_marker_is_rejected(self):
        FakeManager(self.state, tombstone())
        for mode, owner in ((stat.S_IFREG | 0o644, 0), (stat.S_IFREG | 0o600, 1000),
                            (stat.S_IFLNK | 0o600, 0)):
            with self.subTest(mode=mode, owner=owner), mock.patch.object(idle, "protected_state"), \
                    mock.patch.object(idle.os, "fstat", return_value=types.SimpleNamespace(st_mode=mode, st_uid=owner)), \
                    mock.patch.object(Path, "lstat", return_value=types.SimpleNamespace(st_mode=mode, st_uid=owner)):
                with self.assertRaises(idle.IdleLeaseError):
                    idle.inspect_marker(self.state)

    def test_malformed_generation_and_fields_fail_closed(self):
        for key, value in (("uid", "10001"), ("uid", 65534), ("uid", 65535),
                           ("leaseGeneration", 0), ("leaseGeneration", 1.5),
                           ("leaseGeneration", idle.MAX_GENERATION + 1), ("hadSession", "false"),
                           ("username", "../someone"), ("gateClosed", "false")):
            with self.subTest(key=key):
                marker = tombstone()
                marker[key] = value
                with self.assertRaises(idle.IdleLeaseError):
                    idle.validate_tombstone(marker)

    def test_json_generation_maximum_stays_exact_and_unsafe_values_are_rejected(self):
        marker = tombstone()
        marker["leaseGeneration"] = idle.MAX_GENERATION
        parsed = json.loads(json.dumps(marker))
        self.assertEqual(idle.validate_tombstone(parsed)["leaseGeneration"], 9007199254740991)
        for value in (9007199254740992, 9007199254740993, 9223372036854775807,
                      9.007199254740991e15, "9007199254740991"):
            with self.subTest(value=value):
                marker["leaseGeneration"] = value
                with self.assertRaises(idle.IdleLeaseError):
                    idle.validate_tombstone(json.loads(json.dumps(marker)))


if __name__ == "__main__":
    unittest.main()
