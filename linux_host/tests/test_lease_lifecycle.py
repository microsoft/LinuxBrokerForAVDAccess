"""Real host-helper control flow with temporary files and fail-closed command stubs.

Run on Linux: python3 -m unittest discover -s linux_host/tests -v
No useradd/userdel, mount/umount, process signal, IMDS, or broker request reaches the host.
"""

import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shlex
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
if sys.platform == "linux":
    specification = importlib.util.spec_from_file_location("broker_lease", ROOT / "broker-lease.py")
    broker = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = broker
    specification.loader.exec_module(broker)

LEASE = "11111111-1111-4111-8111-111111111111"
NEXT_LEASE = "22222222-2222-4222-8222-222222222222"
OPERATION = "33333333-3333-4333-8333-333333333333"
NEXT_OPERATION = "44444444-4444-4444-8444-444444444444"
THIRD_OPERATION = "55555555-5555-4555-8555-555555555555"
PASSWORD = "sensitive-local-test-password!"
EXPORT = "nfs.example.invalid:/profiles"


class HostCommands:
    def __init__(self, paths):
        self.paths = paths
        self.calls, self.accounts, self.mounts, self.binds = [], {}, {}, {}
        self.groups = {}
        self.sessions = {}
        self.fail = None
        self.on_lock = None
        self.frozen = False
        self.fail_thaw = False
        self.logind = {}
        self.write_mountinfo()

    @staticmethod
    def mount_field(value):
        return (os.fsencode(value).replace(b"\\", br"\134").replace(b" ", br"\040")
                .replace(b"\t", br"\011").replace(b"\n", br"\012"))

    def write_mountinfo(self):
        device = self.paths.state.parent.stat().st_dev
        major_minor = f"{os.major(device)}:{os.minor(device)}".encode("ascii")
        rows = [b"1 0 " + major_minor + b" / / rw,relatime - ext4 /dev/test-root rw\n"]
        for index, mount in enumerate(self.mounts.values(), 100):
            rows.append(b" ".join([
                str(index).encode("ascii"), b"1", major_minor, self.mount_field(mount["fsroot"]),
                self.mount_field(mount["target"]), b"rw,relatime", b"shared:17", b"-",
                mount["fstype"].encode("ascii"), self.mount_field(mount["source"]), b"rw,vers=4.1",
            ]) + b"\n")
        self.paths.mountinfo.write_bytes(b"".join(rows))

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs.get("input")))
        executable = args[0]
        output, status = "", 0
        if executable == self.fail:
            return SimpleNamespace(returncode=32, stdout=PASSWORD, stderr=PASSWORD)
        if executable == "getent":
            if args[1] == "group":
                gid = self.groups.get(args[-1])
                output, status = (f"{args[-1]}:x:{gid}:\n", 0) if gid is not None else ("", 2)
            else:
                account = self.accounts.get(args[-1])
                if account:
                    output = f'{args[-1]}:x:{account["uid"]}:{account["uid"]}::{self.paths.homes / args[-1]}:/bin/bash\n'
                else:
                    status = 2
        elif executable == "mount":
            target = args[-1]
            if "--bind" in args:
                source = args[-2]
                self.binds[target] = Path(source)
                self.mounts[target] = {"target": target, "source": EXPORT, "fstype": "nfs4", "fsroot": "/" + Path(source).name}
            else:
                self.mounts[target] = {"target": target, "source": args[-2], "fstype": "nfs4", "fsroot": "/"}
            self.write_mountinfo()
        elif executable == "umount":
            assert args == ["umount", "--", args[-1]], "Lazy/forced unmount is forbidden."
            self.mounts.pop(args[-1], None)
            self.binds.pop(args[-1], None)
            self.write_mountinfo()
        elif executable == "useradd":
            self.accounts[args[-1]] = {"uid": int(args[args.index("-u") + 1])}
            self.groups[args[-1]] = int(args[args.index("-u") + 1])
        elif executable == "userdel":
            assert args == ["userdel", "--", args[-1]], "Recursive deletion is forbidden."
            self.accounts.pop(args[-1], None)
        elif executable == "groupadd":
            assert args[1] == "--force"
        elif executable == "usermod":
            if "--lock" in args and self.on_lock:
                self.on_lock()
        elif executable == "chpasswd":
            assert kwargs["input"].endswith("\n")
            assert len(args) == 1
        elif executable == "ps":
            if "-p" in args:
                output = "xrdp\n"
            else:
                output = "".join(
                    f"101 {uid} Xorg /usr/lib/xorg/Xorg :10 -config xrdp/xorg.conf\n"
                    for uid, state in self.sessions.items() if state is not None
                )
        elif executable == "ss":
            if "active" in self.sessions.values():
                output = 'u_str ESTAB /run/xrdp/xrdp_display_10 users:(("Xorg",pid=101,fd=1),("xrdp",pid=102,fd=2))\n'
        elif executable == "loginctl":
            if args[1] == "list-sessions":
                output = "".join(f"{session_id} {uid} {username} seat0 tty1\n"
                                 for session_id, (uid, username) in self.logind.items())
            elif args[1] == "show-session":
                assert "--value" not in args
                output = f"User={self.logind[args[2]][0]}\n"
            elif args[1] == "terminate-session":
                self.logind.pop(args[2])
            else:
                raise AssertionError(f"Unexpected logind command: {args}")
        elif executable == "pkill":
            assert args[1] in ("-TERM", "-KILL") and args[2] == "-u"
            self.sessions.pop(int(args[3]), None)
        elif executable == "pgrep":
            status = 1
        elif executable == "systemctl":
            if args[1] == "freeze":
                self.frozen = True
            elif args[1] == "thaw":
                if self.fail_thaw:
                    return SimpleNamespace(returncode=1, stdout="", stderr="thaw uncertain")
                self.frozen = False
            elif args[1] == "show":
                output = "frozen\n" if self.frozen else "running\n"
            else:
                raise AssertionError(f"Unexpected systemd operation: {args}")
        else:
            raise AssertionError(f"Unexpected command; refusing to execute it: {args}")
        return SimpleNamespace(returncode=status, stdout=output, stderr="")


@unittest.skipUnless(sys.platform == "linux", "Linux flock is required; use WSL or a Linux CI runner.")
class LeaseLifecycle(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="linuxbroker-lease-test-")
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.paths = broker.Paths(root / "state", root / "home", root / "profiles", root / "skel", root / "mountinfo")
        self.paths.skel.mkdir()
        (self.paths.skel / ".profile").write_text("preserve this profile\n")
        self.paths.homes.mkdir()
        self.commands = HostCommands(self.paths)
        self.manager = broker.LeaseManager(self.paths, self.commands, owner_uid=os.getuid())
        self.data = broker.identity("preserved_profile", 2042, LEASE, 1)
        self.ownership = {}
        original_stat = Path.stat

        def file_stat(path, *args, **kwargs):
            target = self.commands.binds.get(str(path), path) if kwargs.get("follow_symlinks", True) else path
            actual = original_stat(target, *args, **kwargs)
            values = list(actual)
            if actual.st_ino in self.ownership:
                values[4], values[5] = self.ownership[actual.st_ino]
            return os.stat_result(values)

        def chown(path, uid, gid, **_kwargs):
            # Ownership changes are represented in memory, never applied to a real account.
            self.ownership[original_stat(path, follow_symlinks=False).st_ino] = (uid, gid)

        self.addCleanup(patch.stopall)
        patch.object(Path, "stat", file_stat).start()
        patch.object(os, "chown", chown).start()

    def provision(self, data=None, operation=OPERATION):
        return self.manager.provision(data or self.data, operation, EXPORT, PASSWORD)

    def next_data(self, generation=2):
        return {**self.data, "leaseGeneration": generation}

    def mutations(self):
        return [args for args, _ in self.commands.calls if args[0] in {"useradd", "userdel", "mount", "umount", "pkill", "chpasswd", "usermod", "groupadd"}]

    def test_provision_credentials_groups_profile_and_marker_share_one_operation(self):
        result = self.provision()
        self.assertEqual(result["outcome"], "ready")
        marker = self.manager.read()
        self.assertEqual(marker["uid"], 2042)
        self.assertEqual(marker["phase"], "ready")
        self.assertNotIn(PASSWORD, self.manager.marker.read_text())
        self.assertEqual(self.commands.calls[-1], (["chpasswd"], f"preserved_profile:{PASSWORD}\n"))
        self.assertEqual((self.paths.profiles / "preserved_profile" / ".profile").read_text(), "preserve this profile\n")
        self.assertEqual((self.paths.profiles / "preserved_profile").stat().st_uid, 2042)
        self.assertEqual(self.manager.marker.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(broker.LeaseError):
            self.provision()

    def test_reconnect_preserves_uid_lease_profile_and_desktop(self):
        self.provision()
        sentinel = self.paths.profiles / "preserved_profile" / "working-document"
        sentinel.write_text("user contents")
        self.commands.sessions[2042] = "disconnected"
        self.commands.calls.clear()
        self.provision(self.next_data(), NEXT_OPERATION)
        self.assertEqual(sentinel.read_text(), "user contents")
        self.assertEqual(self.commands.sessions[2042], "disconnected")
        self.assertFalse(any(args[0] in ("useradd", "userdel", "pkill", "umount") for args in self.mutations()))
        self.assertEqual(self.manager.read()["leaseId"], LEASE)
        self.assertEqual(self.manager.read()["leaseGeneration"], 2)

    def test_unmarked_or_mismatched_local_uid_cannot_be_claimed(self):
        self.commands.accounts["preserved_profile"] = {"uid": 2042}
        with self.assertRaises(broker.LeaseError):
            self.provision()
        self.assertEqual(self.mutations(), [])
        self.commands.accounts.clear()
        self.provision()
        self.commands.accounts["preserved_profile"]["uid"] = 3000
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.provision(self.next_data(), NEXT_OPERATION)
        self.assertEqual(self.mutations(), [])

    def test_active_disconnected_and_logoff_observations_do_not_terminate_xorg(self):
        self.provision()
        self.commands.calls.clear()
        self.assertEqual(self.manager.observe()["state"], "disconnected")
        self.commands.sessions[2042] = "active"
        self.assertEqual(self.manager.observe()["state"], "active")
        self.commands.sessions[2042] = "disconnected"
        for _ in range(3):
            self.assertEqual(self.manager.observe()["state"], "disconnected")
        self.commands.sessions[2042] = "active"
        self.assertEqual(self.manager.observe()["state"], "active")
        self.commands.sessions.clear()
        self.assertEqual(self.manager.observe()["state"], "logged_off")
        self.assertEqual(self.mutations(), [])

    def test_expiry_rechecks_a_reconnect_after_locking_new_logins(self):
        self.provision()
        self.commands.sessions[2042] = "disconnected"
        self.commands.on_lock = lambda: self.commands.sessions.update({2042: "active"})
        self.commands.calls.clear()
        result = self.manager.cleanup(self.next_data(), NEXT_OPERATION, "expired")
        self.assertEqual(result["outcome"], "active")
        self.assertEqual(self.manager.read()["phase"], "ready")
        self.assertEqual(self.commands.sessions[2042], "active")
        self.assertFalse(any(args[0] in ("pkill", "userdel", "umount") for args in self.mutations()))
        commands = [args[:2] for args, _ in self.commands.calls]
        self.assertLess(commands.index(["systemctl", "freeze"]), commands.index(["ss", "-xnp"]))
        self.assertFalse(self.commands.frozen)
        self.assertFalse(self.manager.read()["gateClosed"])

    def test_unverified_xrdp_gate_cannot_finalize_cleanup(self):
        self.provision()
        self.commands.fail = "systemctl"
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "expired")
        self.assertTrue(self.manager.read()["gateClosed"])
        self.assertIn("preserved_profile", self.commands.accounts)

    def test_interrupted_thaw_is_durable_and_recovered_before_success(self):
        self.provision()
        self.commands.fail_thaw = True
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertTrue(self.manager.read()["gateClosed"])
        self.commands.fail_thaw = False
        self.assertEqual(self.manager.cleanup(self.next_data(3), THIRD_OPERATION, "admin")["outcome"], "cleaned")
        self.assertFalse(self.manager.read()["gateClosed"])
        self.assertFalse(self.commands.frozen)

    def test_logoff_racing_a_disconnected_session_is_deferred(self):
        self.provision()
        self.commands.sessions[2042] = "disconnected"
        result = self.manager.cleanup(self.next_data(), NEXT_OPERATION, "logged_off")
        self.assertEqual(result["outcome"], "disconnected")
        self.assertIn("preserved_profile", self.commands.accounts)

    def test_busy_mount_keeps_account_and_marker_unavailable_until_retry(self):
        self.provision()
        sentinel = self.paths.profiles / "preserved_profile" / "sentinel"
        sentinel.write_text("never remove")
        self.commands.fail = "umount"
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "expired")
        self.assertEqual(self.manager.read()["phase"], "cleanup")
        self.assertIn("preserved_profile", self.commands.accounts)
        self.assertEqual(sentinel.read_text(), "never remove")
        self.commands.fail = None
        result = self.manager.cleanup(self.next_data(3), THIRD_OPERATION, "expired")
        self.assertEqual(result["outcome"], "cleaned")
        self.assertNotIn("preserved_profile", self.commands.accounts)
        self.assertEqual(sentinel.read_text(), "never remove")
        self.assertEqual((self.paths.profiles / "preserved_profile").stat().st_uid, 2042)

    def test_mountinfo_read_failure_keeps_account_and_never_attempts_cleanup(self):
        self.provision()
        self.paths.mountinfo.unlink()
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.mutations(), [])
        self.assertFalse(any(args[0] == "systemctl" for args, _ in self.commands.calls))
        self.assertEqual(self.manager.read()["phase"], "cleanup")
        self.assertIn("preserved_profile", self.commands.accounts)

    def test_nested_mount_blocks_signals_unmount_and_account_removal(self):
        self.provision()
        nested = self.paths.homes / "preserved_profile" / "nested"
        self.commands.mounts[str(nested)] = {"target": str(nested), "source": "unrelated",
                                          "fstype": "tmpfs", "fsroot": "/"}
        self.commands.write_mountinfo()
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.mutations(), [])
        self.assertIn("preserved_profile", self.commands.accounts)

    def test_mountinfo_records_replace_modern_findmnt_during_full_lifecycle(self):
        self.commands.fail = "findmnt"
        self.provision()
        self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertFalse(any(args[0] == "findmnt" for args, _ in self.commands.calls))
        self.assertEqual(self.manager.read()["phase"], "cleaned")

    def test_failed_userdel_is_not_success_and_retry_never_recursively_deletes_home(self):
        self.provision()
        self.commands.fail = "userdel"
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.manager.read()["phase"], "cleanup")
        self.commands.fail = None
        self.manager.cleanup(self.next_data(3), THIRD_OPERATION, "admin")
        self.assertTrue((self.paths.profiles / "preserved_profile" / ".profile").is_file())
        for args in self.mutations():
            if args[0] == "userdel":
                self.assertEqual(args, ["userdel", "--", "preserved_profile"])

    def test_completed_cleanup_can_be_reconciled_after_lost_ssh_response(self):
        self.provision()
        self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.commands.calls.clear()
        result = self.manager.cleanup(self.next_data(3), THIRD_OPERATION, "admin")
        self.assertEqual(result["outcome"], "cleaned")
        self.assertEqual(self.mutations(), [])
        self.assertEqual(self.manager.read()["leaseGeneration"], 3)

    def test_stale_operations_cannot_touch_new_generation_or_new_owner(self):
        self.provision()
        self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        new = broker.identity("broker_2043", 2043, NEXT_LEASE, 3)
        self.provision(new, THIRD_OPERATION)
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        with self.assertRaises(broker.LeaseError):
            self.provision(self.data, OPERATION)
        self.assertEqual(self.mutations(), [])
        self.assertIn("broker_2043", self.commands.accounts)
        self.assertEqual(self.manager.read()["leaseId"], NEXT_LEASE)

    def test_interrupted_provisioning_is_retryable_without_profile_reownership(self):
        self.commands.fail = "chpasswd"
        with self.assertRaises(broker.LeaseError) as error:
            self.provision()
        self.assertNotIn(PASSWORD, str(error.exception))
        self.assertEqual(self.manager.read()["phase"], "provisioning")
        sentinel = self.paths.profiles / "preserved_profile" / ".profile"
        self.commands.fail = None
        self.provision(self.next_data(), NEXT_OPERATION)
        self.assertEqual(sentinel.read_text(), "preserve this profile\n")

    def test_interrupted_private_group_creation_is_reused_only_for_matching_uid(self):
        self.commands.groups["preserved_profile"] = 2042
        self.provision()
        account_add = next(args for args in self.mutations() if args[0] == "useradd")
        self.assertEqual(account_add[account_add.index("-g") + 1], "preserved_profile")

    def test_conflicting_preexisting_group_is_not_claimed(self):
        self.commands.groups["preserved_profile"] = 3000
        with self.assertRaises(broker.LeaseError):
            self.provision()
        self.assertEqual(self.mutations(), [])

    def test_atomic_marker_failure_leaves_previous_marker_readable(self):
        self.provision()
        original = self.manager.marker.read_text()
        with patch.object(os, "replace", side_effect=OSError("simulated interrupted rename")):
            with self.assertRaises(OSError):
                self.provision(self.next_data(), NEXT_OPERATION)
        self.assertEqual(self.manager.marker.read_text(), original)
        self.assertEqual(list(self.paths.state.glob(".lease-*")), [])

    def test_missing_marker_and_uncertain_session_probe_cannot_cleanup(self):
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.mutations(), [])
        self.provision()
        self.commands.fail = "ss"
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "expired")
        self.assertFalse(any(args[0] in ("pkill", "userdel", "umount") for args in self.mutations()))

    def test_matching_legacy_migration_preserves_uid_and_refuses_conflicts(self):
        self.provision()
        self.manager.marker.unlink()
        legacy_dir = self.paths.state / "leases"
        legacy_dir.mkdir()
        legacy = legacy_dir / "preserved_profile.lease"
        legacy.write_text(LEASE + "\n")
        before = (self.paths.profiles / "preserved_profile" / ".profile").read_text()
        self.commands.calls.clear()
        self.assertEqual(self.manager.migrate(self.data)["outcome"], "migrated")
        self.assertFalse(legacy.exists())
        self.assertEqual(self.manager.read()["uid"], 2042)
        self.assertEqual(self.manager.observe()["state"], "disconnected")
        self.assertEqual(self.mutations(), [])
        self.assertEqual((self.paths.profiles / "preserved_profile" / ".profile").read_text(), before)
        self.assertEqual(self.manager.migrate(self.data)["outcome"], "migrated")
        with self.assertRaises(broker.LeaseError):
            self.manager.migrate({**self.data, "leaseId": NEXT_LEASE})
        self.commands.accounts["preserved_profile"]["uid"] = 3000
        with self.assertRaises(broker.LeaseError):
            self.manager.migrate(self.data)

    def test_conflicting_plain_uuid_marker_is_not_overwritten(self):
        self.provision()
        self.manager.marker.unlink()
        legacy_dir = self.paths.state / "leases"
        legacy_dir.mkdir()
        legacy = legacy_dir / "preserved_profile.lease"
        legacy.write_text(NEXT_LEASE + "\n")
        with self.assertRaises(broker.LeaseError):
            self.manager.migrate(self.data)
        self.assertEqual(legacy.read_text(), NEXT_LEASE + "\n")
        self.assertFalse(self.manager.marker.exists())

    def test_real_file_lock_serializes_independent_managers(self):
        other = broker.LeaseManager(self.paths, self.commands, owner_uid=os.getuid())
        started, entered = threading.Event(), threading.Event()

        def contender():
            started.set()
            with other.locked():
                entered.set()

        with self.manager.locked():
            thread = threading.Thread(target=contender)
            thread.start()
            self.assertTrue(started.wait(2))
            self.assertFalse(entered.wait(0.15))
        thread.join(timeout=3)
        self.assertTrue(entered.is_set())

    def test_idle_disconnect_rejects_stale_lease_before_any_signal(self):
        self.provision()
        with patch.object(os, "pidfd_open", side_effect=AssertionError("A stale lease attempted a signal")):
            with self.assertRaises(broker.LeaseError):
                self.manager.disconnect_idle(self.next_data(), 101)

    def test_cleanup_uid_mismatch_precedes_gate_or_account_mutation(self):
        self.provision()
        self.commands.accounts["preserved_profile"]["uid"] = 3000
        self.commands.calls.clear()
        with self.assertRaises(broker.LeaseError):
            self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.mutations(), [])
        self.assertFalse(any(args[0] == "systemctl" for args, _ in self.commands.calls))

    def test_root_owned_xorg_is_uncertainty_not_logoff(self):
        self.provision()
        self.commands.sessions[0] = "active"
        with self.assertRaises(broker.LeaseError):
            self.manager.observe()

    def test_cleanup_never_terminates_another_users_processes(self):
        self.provision()
        self.commands.sessions[2042] = "disconnected"
        self.commands.sessions[3000] = "active"
        self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.commands.sessions[3000], "active")
        self.assertNotIn(2042, self.commands.sessions)
        for args in self.mutations():
            if args[0] == "pkill":
                self.assertEqual(args[-1], "2042")

    def test_logind_uid_verification_uses_legacy_key_value_output(self):
        self.provision()
        self.commands.logind = {"c1": (2042, "preserved_profile"), "c2": (3000, "other_user")}
        self.manager.cleanup(self.next_data(), NEXT_OPERATION, "admin")
        self.assertEqual(self.commands.logind, {"c2": (3000, "other_user")})
        queries = [args for args, _ in self.commands.calls if args[:2] == ["loginctl", "show-session"]]
        self.assertEqual(queries, [["loginctl", "show-session", "c1", "-p", "User", "--no-pager"]])

    def test_root_only_cli_exits_before_instantiating_state(self):
        with patch.object(os, "geteuid", return_value=1000), patch.object(sys, "stderr", io.StringIO()):
            self.assertEqual(broker.main(), 1)
        self.assertFalse(self.paths.state.exists())

    def test_unsupported_interpreter_fails_before_imports_or_host_actions(self):
        stderr = io.StringIO()
        with patch.object(sys, "version_info", (3, 6, 15)), patch.object(sys, "stderr", stderr):
            with self.assertRaises(SystemExit) as stopped:
                runpy.run_path(str(ROOT / "broker-lease.py"), run_name="runtime_version_test")
        self.assertEqual(stopped.exception.code, 1)
        self.assertIn("Python 3.9+", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())
        self.assertFalse(self.paths.state.exists())
        self.assertEqual(self.mutations(), [])

    def test_generation_domain_is_json_safe_without_narrowing_to_int32(self):
        for generation in (2147483648, 9007199254740991):
            self.assertEqual(broker.identity("preserved_profile", 2042, LEASE, generation)["leaseGeneration"], generation)
        for generation in (9007199254740992, 9007199254740993, 9223372036854775807, True, 0):
            with self.subTest(generation=generation), self.assertRaises(broker.LeaseError):
                broker.identity("preserved_profile", 2042, LEASE, generation)
        self.assertEqual(self.mutations(), [])

    def test_legacy_name_policy_preserves_case_and_never_sanitizes(self):
        self.assertEqual(broker.identity("Legacy_Profile-1", 2042, LEASE, 1)["username"], "Legacy_Profile-1")
        for username in ("Legacy.Profile", "../victim", "123profile", "root"):
            with self.subTest(username=username), self.assertRaises(broker.LeaseError):
                broker.identity(username, 2042, LEASE, 1)
        self.assertFalse(self.paths.state.exists())
        self.assertEqual(self.mutations(), [])

    def test_reserved_uids_are_rejected_without_rewriting_identity(self):
        for uid in (65534, 65535):
            with self.subTest(uid=uid), self.assertRaises(broker.LeaseError):
                broker.identity("preserved_profile", uid, LEASE, 1)
        for uid in (65533, 65536):
            self.assertEqual(broker.identity("preserved_profile", uid, LEASE, 1)["uid"], uid)
        self.assertFalse(self.paths.state.exists())
        self.assertEqual(self.mutations(), [])


@unittest.skipUnless(sys.platform == "linux", "Run safe shell fixtures on Linux or WSL.")
class SessionAgentShell(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="linuxbroker-agent-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def invoke(self, state, http_status="200", helper_status=0, extra=None):
        observation = {
            "username": "preserved_profile", "uid": 2042, "leaseId": LEASE, "leaseGeneration": 7,
            "state": state, "xorgPid": 101 if state == "active" else None,
        }
        observation.update(extra or {})
        payload = self.root / "observation.json"
        payload.write_text(json.dumps(observation))
        helper = self.root / "manage-lease.sh"
        helper.write_text(f"#!/bin/bash\n[ \"$1\" = observe ] || exit 99\ncat {shlex.quote(str(payload))}\nexit {helper_status}\n")
        helper.chmod(0o700)
        captured = self.root / "requests"
        script = self.root / "invoke.sh"
        script.write_text(f"""
source {shlex.quote(str(ROOT / 'session_release_buffer' / 'release-session-common.sh'))}
LINUXBROKER_API_BASE_URL="https://broker.example.invalid/api"
LINUXBROKER_API_CLIENT_ID="{LEASE}"
LOG_FILE={shlex.quote(str(self.root / 'log'))}
IDLE_WARNED_USERS_FILE={shlex.quote(str(self.root / 'warnings'))}
MANAGE_LEASE_SCRIPT={shlex.quote(str(helper))}
BROKER_PYTHON={shlex.quote(sys.executable)}
hostname="linux-01"
ensure_state_files() {{ :; }}
load_settings() {{ :; }}
refresh_settings() {{ :; }}
get_access_token() {{ printf '%s' 'never-log-this-token'; }}
request_api() {{
    printf '%s\\n' "$1|$2|$4" >> {shlex.quote(str(captured))}
    printf '%s' '{http_status}'
}}
enforce_idle_session() {{ printf '%s' 'idle-checked' > {shlex.quote(str(self.root / 'idle'))}; }}
main
""")
        result = subprocess.run(["bash", str(script)], text=True, capture_output=True, timeout=10)
        requests = captured.read_text().splitlines() if captured.exists() else []
        return result, requests

    def test_all_session_states_use_new_scoped_endpoint_and_no_credentials_in_logs(self):
        for state in ("active", "disconnected", "logged_off"):
            with self.subTest(state=state):
                result, requests = self.invoke(state)
                self.assertEqual(result.returncode, 0, result.stderr)
                method, url, body = requests[-1].split("|", 2)
                self.assertEqual((method, url), ("POST", "https://broker.example.invalid/api/vms/linux-01/session"))
                self.assertEqual(json.loads(body), {"leaseId": LEASE, "leaseGeneration": 7, "state": state})
                self.assertNotIn("never-log-this-token", result.stdout + result.stderr + (self.root / "log").read_text())

    def test_automatic_reconnect_is_reported_every_reconciliation(self):
        self.invoke("disconnected")
        result, requests = self.invoke("active")
        self.assertEqual(result.returncode, 0)
        self.assertEqual([json.loads(row.split("|", 2)[2])["state"] for row in requests], ["disconnected", "active"])

    def test_missing_or_in_progress_markers_have_no_fallback(self):
        result, requests = self.invoke("disconnected", helper_status=3)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests, [])
        result, requests = self.invoke("disconnected", helper_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, [])

    def test_malformed_observation_and_http_failure_remain_retryable(self):
        result, requests = self.invoke("disconnected", extra={"leaseGeneration": -1})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, [])
        result, requests = self.invoke("active", http_status="409")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)
        self.assertFalse((self.root / "idle").exists())

    def test_jq_cannot_round_an_unsafe_generation_into_an_observation(self):
        for generation in (9007199254740992, 9007199254740993, 9223372036854775807):
            with self.subTest(generation=generation):
                result, requests = self.invoke("active", extra={"leaseGeneration": generation})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(requests, [])

    def test_both_deployed_distro_entrypoints_forward_configuration_to_shared_agent(self):
        stub = self.root / "shared.sh"
        stub.write_text('#!/bin/bash\nprintf "%s|%s|%s" "$LINUXBROKER_API_BASE_URL" "$LINUXBROKER_API_CLIENT_ID" "$1"\n')
        stub.chmod(0o700)
        for distro in ("RHEL", "Ubuntu"):
            with self.subTest(distro=distro):
                wrapper = self.root / f"{distro}.sh"
                text = (ROOT / "session_release_buffer" / distro / "release-session.sh").read_text()
                text = text.replace("/usr/local/bin/release-session-common.sh", str(stub))
                text = text.replace("YOUR_LINUX_BROKER_API_BASE_URL", "https://broker.example.invalid/api")
                text = text.replace("YOUR_LINUX_BROKER_API_CLIENT_ID", LEASE)
                wrapper.write_text(text)
                result = subprocess.run(["bash", str(wrapper), "--systemd-timer"], text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, f"https://broker.example.invalid/api|{LEASE}|--systemd-timer")

    def test_root_wrappers_use_pinned_isolated_interpreter_and_preserve_stdin(self):
        for script_name, action in (("create-user.sh", "provision"), ("manage-lease.sh", "cleanup")):
            with self.subTest(script=script_name):
                arguments = self.root / (script_name + ".args")
                length = self.root / (script_name + ".stdin-length")
                runtime = self.root / (script_name + ".runtime")
                runtime.write_text(
                    "#!/bin/bash\n"
                    f"printf '%s\\n' \"$@\" > {shlex.quote(str(arguments))}\n"
                    f"input=$(cat); printf '%s' \"${{#input}}\" > {shlex.quote(str(length))}\n"
                )
                runtime.chmod(0o700)
                wrapper = self.root / script_name
                text = (ROOT / script_name).read_text()
                # Simulate only the trusted UID boundary in this temporary fixture;
                # the interpreter is a stub and cannot execute host-management code.
                text = text.replace('"$EUID"', '"0"').replace("/usr/local/libexec/linuxbroker/python3", str(runtime))
                wrapper.write_text(text)
                supplied = ["arg-1", "arg-2"] if action == "provision" else ["cleanup", "arg-1", "arg-2"]
                result = subprocess.run(["bash", str(wrapper), *supplied], input=PASSWORD + "\n",
                                        text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(arguments.read_text().splitlines(), ["-I", str(self.root / "broker-lease.py"), action, "arg-1", "arg-2"])
                self.assertEqual(int(length.read_text()), len(PASSWORD))
                self.assertNotIn(PASSWORD, result.stdout + result.stderr + arguments.read_text())

    def test_missing_pinned_interpreter_never_falls_back_to_env_python(self):
        for script_name in ("create-user.sh", "manage-lease.sh"):
            with self.subTest(script=script_name):
                wrapper = self.root / script_name
                text = (ROOT / script_name).read_text()
                text = text.replace('"$EUID"', '"0"').replace("/usr/local/libexec/linuxbroker/python3", str(self.root / "absent-runtime"))
                wrapper.write_text(text)
                result = subprocess.run(["bash", str(wrapper), "unused"], text=True, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("deployment-pinned Python 3.9+", result.stderr)


if __name__ == "__main__":
    unittest.main()
