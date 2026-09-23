"""Legacy freezer model: temporary cgroup/proc files, never live controller writes."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


if sys.platform == "linux":
    lease = load("legacy_gate_lease_tests", ROOT / "broker-lease.py")
    freezer_module = load("legacy_gate_freezer_tests", ROOT / "broker-freezer.py")


@unittest.skipUnless(sys.platform == "linux", "Legacy gate fixtures need Linux filesystem semantics.")
class LegacyGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="linuxbroker-freezer-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.proc = self.root / "proc"
        self.controller = self.root / "freezer"
        self.systemd = self.root / "systemd"
        self.state = self.root / "state"
        for path in (self.proc, self.controller, self.systemd, self.state):
            path.mkdir(mode=0o700)
        self.boot_id = self.proc / "sys/kernel/random/boot_id"
        self.boot_id.parent.mkdir(parents=True)
        self.boot_id.write_text("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n")
        self.uid = 2042
        self.writes = []
        self.fail_freeze = False
        self.fail_thaw = False
        self.fail_unmount = False
        self.account_present = True
        self.on_freeze = None
        self.signals = []
        self.commands = []
        self.properties = {}
        self.startup_pending = 0
        self.startup_activating = False
        self.service_shows = 0
        self.new_group(self.controller / "linuxbroker-xrdp")
        self.services = self.controller / "linuxbroker-xrdp" / "services"
        self.quarantine = self.controller / "linuxbroker-xrdp" / "cleanup"
        self.new_group(self.services)
        self.new_group(self.quarantine)
        for index, unit in enumerate(freezer_module.UNITS, 100):
            group = self.services / unit
            self.new_group(group)
            system_group = self.systemd / "system.slice" / unit
            self.new_group(system_group)
            self.add_process(index, 0, unit)
            self.properties[unit] = {
                "LoadState": "loaded", "ActiveState": "active",
                "ControlGroup": "/system.slice/" + unit, "MainPID": str(index),
                "ExecStart": "{ path=/usr/local/bin/manage-lease.sh ; argv[]=/usr/local/bin/manage-lease.sh run-xrdp "
                             + unit + " /usr/sbin/" + unit.removesuffix(".service") + " ; }",
            }
        (self.proc / "self").mkdir()
        (self.proc / "self" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/sshd.service\n")
        mountinfo = self.root / "mountinfo"
        device = self.root.stat().st_dev
        mounts = []
        for identifier, path, options in ((30, self.controller, "rw,freezer"), (31, self.systemd, "rw,name=systemd")):
            mounts.append(
                f"{identifier} 1 {os.major(device)}:{os.minor(device)} / {path} rw - cgroup cgroup {options}\n"
            )
        mountinfo.write_text("".join(mounts))
        paths = lease.Paths(state=self.state, homes=self.root / "home", profiles=self.root / "profiles",
                            mountinfo=mountinfo, proc=self.proc)
        self.manager = lease.LeaseManager(paths=paths, runner=self.command, owner_uid=os.getuid())
        self.gate = freezer_module.LegacyFreezer(
            self.manager, lease.parse_mountinfo(mountinfo.read_bytes()), lease.LeaseError, timeout=0.03,
        )
        self.gate._write = self.write_control
        self.gate._signal = lambda pid, action: self.signals.append((pid, action))

    def new_group(self, path):
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        for name, content in (("cgroup.procs", ""), ("freezer.state", "THAWED"),
                              ("freezer.self_freezing", "0"), ("freezer.parent_freezing", "0")):
            (path / name).write_text(content)
            (path / name).chmod(0o600)

    def add_process(self, pid, uid, unit, subgroup=""):
        relative = freezer_module.SERVICE_PATH + "/" + unit + subgroup
        group = self.controller / relative.lstrip("/")
        if not group.exists():
            self.new_group(group)
        with (group / "cgroup.procs").open("a") as stream:
            stream.write(f"{pid}\n")
        system = self.systemd / "system.slice" / unit
        with (system / "cgroup.procs").open("a") as stream:
            stream.write(f"{pid}\n")
        process = self.proc / str(pid)
        process.mkdir(exist_ok=True)
        (process / "cgroup").write_text(f"2:freezer:{relative}\n1:name=systemd:/system.slice/{unit}\n")
        (process / "status").write_text(f"Name:\tfixture\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n")
        (process / "cmdline").write_bytes(f"/usr/sbin/{unit.removesuffix('.service')}".encode() + b"\0")
        (process / "exe").symlink_to("/usr/sbin/" + unit.removesuffix(".service"))
        task = process / "task" / str(pid)
        task.mkdir(parents=True, exist_ok=True)
        self.thread_state(pid, "S", 0)

    def thread_state(self, pid, state, flags):
        fields = [state] + ["0"] * 19
        fields[6] = str(flags)
        fields[19] = "123456"
        (self.proc / str(pid) / "task" / str(pid) / "stat").write_text(f"{pid} (fixture thread) " + " ".join(fields))
        (self.proc / str(pid) / "stat").write_text(f"{pid} (fixture process) " + " ".join(fields))

    def pending_wrapper(self, pid=100, unit="xrdp.service"):
        (self.proc / str(pid) / "cgroup").write_text(f"2:freezer:/\n1:name=systemd:/system.slice/{unit}\n")
        (self.proc / str(pid) / "cmdline").write_bytes(b"\0".join([
            b"/usr/local/libexec/linuxbroker/python3", b"-I", b"/usr/local/bin/broker-lease.py",
            b"run-xrdp", unit.encode(), ("/usr/sbin/" + unit.removesuffix(".service")).encode(), b"",
        ]))

    def command(self, args, **_kwargs):
        self.commands.append(args)
        if args[0] == "usermod":
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[0] == "userdel":
            self.account_present = False
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[0] == "umount":
            if self.fail_unmount:
                raise lease.LeaseError("simulated busy mount")
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[:2] == ["loginctl", "list-sessions"] or args[0] == "pkill":
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[0] == "pgrep":
            return SimpleNamespace(returncode=1, stdout="", stderr="")
        if args[0] == "ps":
            return SimpleNamespace(returncode=0, stdout="xrdp\n", stderr="")
        if args[:2] in (["systemctl", "stop"], ["systemctl", "start"]):
            if args[1] == "start":
                for index, unit in enumerate(freezer_module.UNITS, 100):
                    if not (self.proc / str(index)).exists():
                        self.add_process(index, 0, unit)
                if self.startup_pending:
                    self.pending_wrapper()
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        if args[:2] != ["systemctl", "show"]:
            raise AssertionError("No real service/process command is permitted in freezer fixtures.")
        self.service_shows += 1
        if args[2] == "xrdp.service" and self.startup_pending:
            self.startup_pending -= 1
            if not self.startup_pending:
                (self.proc / "100" / "cgroup").write_text(
                    "2:freezer:/linuxbroker-xrdp/services/xrdp.service\n1:name=systemd:/system.slice/xrdp.service\n",
                )
        properties = dict(self.properties[args[2]])
        if args[2] == "xrdp.service" and self.startup_pending and self.startup_activating:
            properties.update({"ActiveState": "activating", "MainPID": "0", "ControlGroup": ""})
        return SimpleNamespace(returncode=0, stdout="".join(f"{name}={value}\n" for name, value in properties.items()), stderr="")

    def write_control(self, path, value):
        self.writes.append((path, value))
        if path == self.services / "freezer.state":
            if value == "FROZEN" and self.on_freeze:
                self.on_freeze()
            if value == "THAWED" and self.fail_thaw:
                raise lease.LeaseError("simulated thaw failure")
            for group in self.gate._groups(self.services):
                (group / "freezer.state").write_text(
                    "FREEZING" if value == "FROZEN" and self.fail_freeze else value
                )
            (path.parent / "freezer.self_freezing").write_text("1" if value == "FROZEN" else "0")
            for pid in self.gate._members(self.services):
                self.thread_state(pid, "D" if value == "FROZEN" else "S",
                                  freezer_module.PF_FROZEN if value == "FROZEN" else 0)
            return
        if path.name == "cgroup.procs":
            if value == "0":
                relative = "/" + str(path.parent.relative_to(self.controller))
                (self.proc / "self" / "cgroup").write_text(f"2:freezer:{relative}\n1:name=systemd:/system.slice/xrdp.service\n")
                return
            pid = int(value)
            for group in self.gate._groups(self.services):
                remaining = [line for line in (group / "cgroup.procs").read_text().splitlines() if line != value]
                (group / "cgroup.procs").write_text("\n".join(remaining))
            with path.open("a") as stream:
                stream.write(value + "\n")
            cgroup = self.proc / value / "cgroup"
            text = cgroup.read_text()
            cgroup.write_text("\n".join(
                "2:freezer:/linuxbroker-xrdp/cleanup" if ":freezer:" in line else line
                for line in text.splitlines()
            ) + "\n")
            self.thread_state(pid, "S", 0)
            if any(signalled == pid for signalled, _ in self.signals):
                path.write_text("")
                # Simulate process exit without using any host process operation.
                for members in self.systemd.rglob("cgroup.procs"):
                    members.write_text("\n".join(line for line in members.read_text().splitlines() if line != value))
                import shutil
                shutil.rmtree(self.proc / value)
            return
        raise AssertionError(f"Unexpected control write: {path}")

    def marker(self):
        return {
            "username": "broker_2042", "uid": self.uid, "leaseId": "11111111-1111-4111-8111-111111111111",
            "leaseGeneration": 2, "operationId": "22222222-2222-4222-8222-222222222222",
            "phase": "cleanup", "hadSession": True, "gateClosed": False,
        }

    def test_enrolled_daemons_and_descendants_freeze_as_one_hierarchy(self):
        self.add_process(200, self.uid, "xrdp-sesman.service", "/session-a")
        self.gate.check(require_thawed=True)
        self.gate.freeze(self.uid)
        self.assertTrue(all(self.gate._read(group / "freezer.state") == "FROZEN"
                            for group in self.gate._groups(self.services)))
        self.gate.thaw()
        self.gate.check(require_thawed=True)

    def test_production_backend_selection_and_readonly_status_work_on_v1(self):
        self.assertEqual(self.manager.gate_status(), {"backend": "freezer-v1", "ready": True})
        self.assertEqual(self.writes, [])
        self.assertFalse(any(command[:2] in (["systemctl", "stop"], ["systemctl", "start"])
                             for command in self.commands))

    def test_unenrolled_gate_blocks_provisioning_before_account_or_mount_mutation(self):
        (self.proc / "100" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        data = lease.identity("broker_2042", self.uid, "11111111-1111-4111-8111-111111111111", 1)
        with self.assertRaises(lease.LeaseError):
            self.manager.provision(
                data, "22222222-2222-4222-8222-222222222222", "nfs.invalid:/profiles", "test-only-password-123",
            )
        self.assertFalse(self.manager.marker.exists())
        self.assertTrue(all(command[:2] == ["systemctl", "show"] for command in self.commands))

    def test_child_created_during_freeze_is_included_before_acknowledgement(self):
        self.on_freeze = lambda: self.add_process(201, self.uid, "xrdp-sesman.service", "/new-child")
        self.gate.freeze(self.uid)
        self.assertIn(201, self.gate._members(self.services))
        self.assertEqual(self.gate._read(self.services / "xrdp-sesman.service" / "new-child" / "freezer.state"), "FROZEN")

    def test_unenrolled_running_service_cannot_be_adopted_by_pid_scan(self):
        membership = self.proc / "100" / "cgroup"
        membership.write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        with self.assertRaises(lease.LeaseError):
            self.gate.freeze(self.uid)
        self.assertEqual(self.writes, [])

    def test_escaped_descendant_or_unwrapped_restart_is_rejected(self):
        self.add_process(200, self.uid, "xrdp-sesman.service")
        (self.proc / "200" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp-sesman.service\n")
        with self.assertRaises(lease.LeaseError):
            self.gate.check()
        self.properties["xrdp.service"]["ExecStart"] = "{ path=/usr/sbin/xrdp ; argv[]=/usr/sbin/xrdp ; }"
        with self.assertRaises(lease.LeaseError):
            self.gate.check()

    def test_freezing_not_frozen_is_bounded_failure(self):
        self.fail_freeze = True
        with self.assertRaises(lease.LeaseError):
            self.gate.freeze(self.uid)
        self.gate.thaw()
        self.gate.check(require_thawed=True)

    def test_external_frozen_parent_and_descendant_are_not_silently_thawed(self):
        (self.controller / "linuxbroker-xrdp" / "freezer.state").write_text("FROZEN")
        with self.assertRaises(lease.LeaseError):
            self.gate.check()
        (self.controller / "linuxbroker-xrdp" / "freezer.state").write_text("THAWED")
        (self.services / "xrdp.service" / "freezer.self_freezing").write_text("1")
        with self.assertRaises(lease.LeaseError):
            self.gate.check()
        self.assertEqual(self.writes, [])

    def test_cleanup_worker_never_freezes_itself(self):
        (self.proc / "self" / "cgroup").write_text("2:freezer:/linuxbroker-xrdp/services/xrdp.service\n")
        with self.assertRaises(lease.LeaseError):
            self.gate.check()

    def test_cleanup_discards_matching_session_and_cached_root_auth_workers(self):
        self.add_process(200, self.uid, "xrdp-sesman.service")
        self.add_process(201, 0, "xrdp-sesman.service")
        self.gate.freeze(self.uid)
        targets = self.gate.termination_targets(self.uid)
        self.gate.terminate(targets)
        self.assertEqual({pid for pid, _ in self.signals}, {100, 101, 200, 201})
        self.assertEqual(self.gate._members(self.quarantine), set())
        self.assertEqual(self.gate._members(self.services), set())
        self.assertEqual(self.gate._read(self.services / "freezer.state"), "FROZEN")
        self.gate.restart()
        self.gate.check(require_thawed=True)

    def test_another_user_blocks_legacy_daemon_reset_before_any_signal(self):
        self.add_process(200, self.uid, "xrdp-sesman.service")
        self.add_process(201, 3000, "xrdp-sesman.service")
        self.gate.freeze(self.uid)
        with self.assertRaises(lease.LeaseError):
            self.gate.termination_targets(self.uid)
        self.assertEqual(self.signals, [])

    def test_vfork_stopped_or_mixed_privilege_tasks_are_not_moved(self):
        self.add_process(200, self.uid, "xrdp-sesman.service")
        self.gate.freeze(self.uid)
        for state, flags in (("D", 0), ("T", 0)):
            self.thread_state(200, state, flags)
            with self.assertRaises(lease.LeaseError):
                self.gate.termination_targets(self.uid)
            self.assertEqual(self.gate._members(self.quarantine), set())
        self.thread_state(200, "D", freezer_module.PF_FROZEN)
        (self.proc / "200" / "status").write_text(f"Uid:\t{self.uid}\t0\t0\t{self.uid}\n")
        with self.assertRaises(lease.LeaseError):
            self.gate.termination_targets(self.uid)
        self.assertEqual(self.gate._members(self.quarantine), set())

    def test_startup_enrollment_writes_self_not_a_discovered_pid(self):
        self.gate._enroll_current("xrdp.service")
        self.assertEqual(self.writes[-1], (self.services / "xrdp.service" / "cgroup.procs", "0"))

    def prepare_cleanup(self, session_state):
        self.manager.legacy_freezer = lambda: self.gate
        self.manager.verify_account = lambda _data, required=False: {"uid": self.uid} if self.account_present else None
        self.manager.account = lambda _name: {"uid": self.uid} if self.account_present else None
        self.manager.verify_home_mount = lambda _data: {"target": str(self.root / "home" / "broker_2042")}
        self.manager.sessions = lambda _data: [{"state": session_state}] if session_state else []
        home = self.root / "home" / "broker_2042"
        home.mkdir(parents=True)
        return self.marker()

    def test_active_reconnect_cancels_legacy_cleanup_without_reset_or_session_signals(self):
        marker = self.prepare_cleanup("active")
        with self.manager.session_gate(marker):
            self.assertEqual(self.manager.cleanup_locked(marker, marker, "expired"), "active")
        self.assertEqual(self.signals, [])
        self.assertFalse(any(command[0:2] == ["systemctl", "stop"] for command in self.commands))
        self.assertTrue(self.account_present)
        self.assertEqual(marker["phase"], "ready")
        self.gate.check(require_thawed=True)

    def test_legacy_cleanup_completes_only_after_daemon_reset_and_account_removal(self):
        marker = self.prepare_cleanup(None)
        self.add_process(200, self.uid, "xrdp-sesman.service")
        with self.manager.session_gate(marker):
            self.assertEqual(self.manager.cleanup_locked(marker, marker, "admin"), "cleaned")
        self.assertFalse(self.account_present)
        self.assertFalse(marker["gateClosed"])
        self.assertFalse(marker["gateRestartRequired"])
        self.assertEqual(marker["phase"], "cleaned")
        self.assertEqual({pid for pid, _ in self.signals}, {100, 101, 200})
        self.gate.check(require_thawed=True)

    def test_legacy_busy_mount_restores_fresh_daemons_but_cannot_finalize_lease(self):
        marker = self.prepare_cleanup(None)
        self.fail_unmount = True
        with self.assertRaises(lease.LeaseError):
            with self.manager.session_gate(marker):
                self.manager.cleanup_locked(marker, marker, "admin")
        self.assertTrue(self.account_present)
        self.assertEqual(marker["phase"], "cleanup")
        self.assertFalse(marker["gateClosed"])
        self.assertFalse(marker["gateRestartRequired"])
        self.gate.check(require_thawed=True)

    def test_legacy_idle_disconnect_needs_no_pidfd_and_never_signals_listener(self):
        self.add_process(200, 0, "xrdp.service")
        self.gate.freeze(self.uid)
        with self.assertRaises(lease.LeaseError):
            self.gate.disconnect_connection(100)
        self.assertEqual(self.signals, [])
        self.gate.disconnect_connection(200)
        self.assertEqual(self.signals, [(200, freezer_module.signal.SIGTERM)])
        self.gate.thaw()

    def test_manager_marks_gate_before_freezing_and_recovers_interrupted_thaw(self):
        self.manager.legacy_freezer = lambda: self.gate
        marker = self.marker()
        self.fail_thaw = True
        with self.assertRaises(lease.LeaseError):
            with self.manager.session_gate(marker):
                persisted = json.loads(self.manager.marker.read_text())
                self.assertTrue(persisted["gateClosed"])
                self.assertEqual(persisted["gateBackend"], "freezer-v1")
        self.assertTrue(json.loads(self.manager.marker.read_text())["gateClosed"])
        self.fail_thaw = False
        recovered = json.loads(self.manager.marker.read_text())
        with self.manager.session_gate(recovered):
            pass
        self.assertFalse(json.loads(self.manager.marker.read_text())["gateClosed"])
        self.gate.check(require_thawed=True)

    def test_partial_termination_keeps_gate_frozen_and_retries_before_thaw(self):
        self.manager.legacy_freezer = lambda: self.gate
        marker = self.marker()
        with self.assertRaises(lease.LeaseError):
            with self.manager.session_gate(marker):
                marker["gateRestartRequired"] = True
                self.manager.write(marker)
                raise lease.LeaseError("simulated interrupted termination")
        persisted = json.loads(self.manager.marker.read_text())
        self.assertTrue(persisted["gateClosed"])
        self.assertTrue(persisted["gateRestartRequired"])
        self.assertEqual(self.gate._read(self.services / "freezer.state"), "FROZEN")
        with self.manager.session_gate(persisted):
            self.assertTrue(persisted["gateTerminated"])
            self.assertEqual(self.gate._members(self.services), set())
        finished = json.loads(self.manager.marker.read_text())
        self.assertFalse(finished["gateClosed"])
        self.assertFalse(finished["gateRestartRequired"])
        self.gate.check(require_thawed=True)

    def test_completed_termination_recovers_a_failed_restart_without_old_workers(self):
        self.manager.legacy_freezer = lambda: self.gate
        marker = self.marker()
        with self.assertRaises(lease.LeaseError):
            with self.manager.session_gate(marker):
                targets = self.gate.termination_targets(self.uid)
                marker["gateRestartRequired"] = True
                self.manager.write(marker)
                self.gate.terminate(targets)
                marker["gateTerminated"] = True
                self.manager.write(marker)
                self.fail_thaw = True
        persisted = json.loads(self.manager.marker.read_text())
        self.assertTrue(persisted["gateTerminated"])
        self.fail_thaw = False
        with self.manager.session_gate(persisted):
            self.assertFalse(persisted["gateRestartRequired"])
        self.gate.check(require_thawed=True)

    def test_restart_waits_for_asynchronous_simple_unit_enrollment(self):
        self.gate.timeout = 0.5
        self.startup_pending = 2
        self.gate.restart()
        self.assertEqual(self.startup_pending, 0)
        self.assertGreaterEqual(self.service_shows, 4)
        self.gate.check(require_thawed=True)

    def test_restart_waits_for_activating_unit_before_main_pid_is_assigned(self):
        self.gate.timeout = 0.5
        self.startup_pending = 2
        self.startup_activating = True
        self.gate.restart()
        self.assertEqual(self.startup_pending, 0)
        self.gate.check(require_thawed=True)

    def test_startup_wait_is_bounded_and_cannot_accept_an_unenrolled_daemon(self):
        self.pending_wrapper()
        with self.assertRaisesRegex(lease.LeaseError, "startup deadline"):
            self.gate.wait_ready()
        self.assertEqual(self.signals, [])
        self.assertEqual(self.writes, [])

    def test_startup_process_exiting_before_enrollment_cannot_become_ready(self):
        shutil.rmtree(self.proc / "100")
        with self.assertRaisesRegex(lease.LeaseError, "startup deadline"):
            self.gate.wait_ready()
        self.assertEqual(self.signals, [])
        self.assertEqual(self.writes, [])

    def test_missing_metadata_for_existing_process_is_not_retried(self):
        self.pending_wrapper()
        (self.proc / "100" / "cmdline").unlink()
        with self.assertRaises(FileNotFoundError):
            self.gate.wait_ready()
        self.assertEqual(self.service_shows, 1)

    def test_enrollment_and_exec_between_observations_is_rechecked(self):
        self.pending_wrapper()
        original_read = self.gate._process_group
        reads = 0

        def observe(pid, controller):
            nonlocal reads
            if pid == 100 and controller == "freezer":
                reads += 1
                if reads == 3:
                    (self.proc / "100" / "cgroup").write_text(
                        "2:freezer:/linuxbroker-xrdp/services/xrdp.service\n1:name=systemd:/system.slice/xrdp.service\n",
                    )
                elif reads == 2:
                    (self.proc / "100" / "cmdline").write_bytes(b"/usr/sbin/xrdp\0")
            return original_read(pid, controller)

        with patch.object(self.gate, "_process_group", side_effect=observe):
            self.gate.wait_ready()
        self.assertGreaterEqual(reads, 3)
        self.gate.check(require_thawed=True)

    def test_newly_observed_wrong_group_fails_without_another_startup_iteration(self):
        self.pending_wrapper()
        original_read = self.gate._process_group
        reads = 0

        def observe(pid, controller):
            nonlocal reads
            if pid == 100 and controller == "freezer":
                reads += 1
                if reads == 2:
                    (self.proc / "100" / "cgroup").write_text(
                        "2:freezer:/unexpected\n1:name=systemd:/system.slice/xrdp.service\n",
                    )
            return original_read(pid, controller)

        with patch.object(self.gate, "_process_group", side_effect=observe):
            with self.assertRaisesRegex(lease.LeaseError, "control-group mismatch"):
                self.gate.wait_ready()
        self.assertEqual(self.service_shows, 1)

    def test_inactive_exited_service_cannot_be_acknowledged(self):
        self.properties["xrdp.service"].update({"ActiveState": "inactive", "MainPID": "0", "ControlGroup": ""})
        with self.assertRaisesRegex(lease.LeaseError, "startup deadline"):
            self.gate.wait_ready()

    def test_permanent_ownership_failure_is_not_polled_as_slow_startup(self):
        (self.proc / "100" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        (self.services / "xrdp.service").chmod(0o777)
        with self.assertRaisesRegex(lease.LeaseError, "not root-controlled"):
            self.gate.wait_ready()
        self.assertEqual(self.service_shows, 0)
        self.assertEqual(self.signals, [])

    def test_permission_failure_during_startup_is_not_retried(self):
        with patch.object(self.gate, "_process_group", side_effect=PermissionError("fixture denial")) as membership:
            with self.assertRaises(PermissionError):
                self.gate.wait_ready()
        self.assertEqual(membership.call_count, 1)

    def test_restart_timeout_preserves_durable_recovery_state_then_can_retry(self):
        self.manager.legacy_freezer = lambda: self.gate
        marker = self.marker()
        with self.assertRaisesRegex(lease.LeaseError, "startup deadline"):
            with self.manager.session_gate(marker):
                targets = self.gate.termination_targets(self.uid)
                marker["gateRestartRequired"] = True
                self.manager.write(marker)
                self.gate.terminate(targets)
                marker["gateTerminated"] = True
                self.manager.write(marker)
                self.startup_pending = 1000
        persisted = self.manager.read()
        self.assertTrue(persisted["gateClosed"])
        self.assertTrue(persisted["gateRestartRequired"])
        self.assertTrue(persisted["gateTerminated"])
        self.gate.timeout = 0.5
        self.startup_pending = 2
        with self.manager.session_gate(persisted):
            pass
        recovered = self.manager.read()
        self.assertFalse(recovered["gateClosed"])
        self.assertFalse(recovered["gateRestartRequired"])
        self.gate.check(require_thawed=True)

    def test_startup_observed_after_the_deadline_is_not_reported_as_ready(self):
        self.gate.timeout = 1
        with patch.object(freezer_module.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(lease.LeaseError, "startup deadline"):
                self.gate.wait_ready()

    def test_startup_wait_rejects_bad_wrapper_or_failed_service_without_retrying(self):
        self.properties["xrdp.service"]["ActiveState"] = "failed"
        with self.assertRaisesRegex(lease.LeaseError, "failed during startup"):
            self.gate.wait_ready()
        self.assertEqual(self.service_shows, 1)
        self.properties["xrdp.service"]["ActiveState"] = "active"
        self.properties["xrdp.service"]["ExecStart"] = "{ path=/usr/sbin/xrdp ; argv[]=/usr/sbin/xrdp ; }"
        with self.assertRaisesRegex(lease.LeaseError, "freezer wrapper"):
            self.gate.wait_ready()
        self.assertEqual(self.service_shows, 2)

    def test_wrong_freezer_group_is_not_treated_as_slow_self_enrollment(self):
        self.pending_wrapper()
        (self.proc / "100" / "cgroup").write_text("2:freezer:/another-service\n1:name=systemd:/system.slice/xrdp.service\n")
        with patch.object(freezer_module.time, "sleep", side_effect=AssertionError("Permanent mismatch must not sleep")):
            with self.assertRaisesRegex(lease.LeaseError, "control-group"):
                self.gate.wait_ready()
        self.assertEqual(self.service_shows, 1)

    def test_executed_unenrolled_daemon_is_not_retried_as_a_wrapper(self):
        (self.proc / "100" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        with patch.object(freezer_module.time, "sleep", side_effect=AssertionError("Executed daemon must not sleep")):
            with self.assertRaisesRegex(lease.LeaseError, "not a verified pre-exec"):
                self.gate.wait_ready()
        self.assertEqual(self.service_shows, 1)

    def test_wrong_main_uid_fails_before_sleep_even_after_enrollment(self):
        for enrolled in (False, True):
            with self.subTest(enrolled=enrolled):
                self.pending_wrapper()
                if enrolled:
                    (self.proc / "100" / "cgroup").write_text(
                        "2:freezer:/linuxbroker-xrdp/services/xrdp.service\n1:name=systemd:/system.slice/xrdp.service\n",
                    )
                (self.proc / "100" / "status").write_text("Uid:\t3000\t3000\t3000\t3000\n")
                with patch.object(freezer_module.time, "sleep", side_effect=AssertionError("Wrong UID must not sleep")):
                    with self.assertRaisesRegex(lease.LeaseError, "process-owner"):
                        self.gate.wait_ready()

    def test_wrong_systemd_membership_fails_before_sleep_even_after_enrollment(self):
        for membership in ("/", "/linuxbroker-xrdp/services/xrdp.service"):
            with self.subTest(membership=membership):
                self.pending_wrapper()
                (self.proc / "100" / "cgroup").write_text(
                    f"2:freezer:{membership}\n1:name=systemd:/system.slice/other.service\n",
                )
                with patch.object(freezer_module.time, "sleep", side_effect=AssertionError("Wrong unit must not sleep")):
                    with self.assertRaisesRegex(lease.LeaseError, "systemd-group"):
                        self.gate.wait_ready()

    def test_escaped_descendant_fails_even_when_another_service_is_still_starting(self):
        self.properties["xrdp.service"].update({"ActiveState": "activating", "MainPID": "0"})
        self.add_process(200, self.uid, "xrdp-sesman.service")
        (self.proc / "200" / "cgroup").write_text("2:freezer:/escaped\n1:name=systemd:/system.slice/xrdp-sesman.service\n")
        with patch.object(freezer_module.time, "sleep", side_effect=AssertionError("Escaped child must not sleep")):
            with self.assertRaisesRegex(lease.LeaseError, "descendant escaped"):
                self.gate.wait_ready()

    def test_systemd_fork_child_is_identifiable_before_wrapper_exec(self):
        (self.proc / "100" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        (self.proc / "100" / "cmdline").write_bytes(b"/usr/lib/systemd/systemd\0")
        executable = self.proc / "100" / "exe"
        executable.unlink()
        executable.symlink_to("/usr/lib/systemd/systemd")
        self.thread_state(100, "S", 0x00000040)
        fields = (self.proc / "100" / "stat").read_text().rpartition(") ")[2].split()
        fields[1] = "1"
        (self.proc / "100" / "stat").write_text("100 (systemd) " + " ".join(fields))
        self.gate._verify_starting_wrapper(100, "xrdp.service", "/", "/system.slice/xrdp.service")
        fields[6] = "0"
        (self.proc / "100" / "stat").write_text("100 (systemd) " + " ".join(fields))
        with self.assertRaisesRegex(lease.LeaseError, "not a verified pre-exec"):
            self.gate._verify_starting_wrapper(100, "xrdp.service", "/", "/system.slice/xrdp.service")

    def test_startup_wait_checks_descendants_instead_of_only_main_pid(self):
        self.add_process(200, self.uid, "xrdp-sesman.service")
        (self.proc / "200" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp-sesman.service\n")
        with self.assertRaisesRegex(lease.LeaseError, "descendant escaped"):
            self.gate.wait_ready()

    def test_verified_new_boot_reestablishes_gate_without_reusing_old_pid_state(self):
        self.manager.legacy_freezer = lambda: self.gate
        marker = self.marker()
        marker.update({
            "gateClosed": True, "gateRestartRequired": True, "gateTerminated": False,
            "gateBackend": "freezer-v1", "gateBootId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        })
        with self.manager.session_gate(marker):
            self.assertFalse(marker["gateRestartRequired"])
            self.assertEqual(marker["gateBootId"], self.boot_id.read_text().strip())
        self.assertEqual(self.signals, [])
        self.gate.check(require_thawed=True)

    def test_startup_wrapper_enrolls_before_exec_without_changing_daemon_arguments(self):
        (self.proc / "self" / "cgroup").write_text("2:freezer:/\n1:name=systemd:/system.slice/xrdp.service\n")
        executable = self.root / "xrdp"
        executable.write_text("test fixture")
        real_stat = Path.stat

        def file_stat(path, *args, **kwargs):
            return real_stat(executable if path == Path("/usr/sbin/xrdp") else path, *args, **kwargs)

        def execute(path, arguments):
            self.assertEqual(path, "/usr/sbin/xrdp")
            self.assertEqual(arguments, ["/usr/sbin/xrdp", "--nodaemon"])
            self.assertEqual(self.gate._process_group("self", "freezer"), freezer_module.SERVICE_PATH + "/xrdp.service")
            raise SystemExit(0)

        with patch.object(Path, "stat", file_stat), patch.object(os, "execv", execute):
            with self.assertRaises(SystemExit) as result:
                self.gate.run("xrdp.service", ["/usr/sbin/xrdp", "--nodaemon"])
        self.assertEqual(result.exception.code, 0)

    def test_symlinked_or_writable_hierarchy_is_rejected(self):
        (self.services / "xrdp.service").chmod(0o777)
        with self.assertRaises(lease.LeaseError):
            self.gate.check()
        (self.services / "xrdp.service").chmod(0o700)
        (self.services / "unexpected-link").symlink_to(self.quarantine, target_is_directory=True)
        with self.assertRaises(lease.LeaseError):
            self.gate.check()

    def test_combined_readonly_or_duplicate_controller_mounts_are_rejected(self):
        original = lease.parse_mountinfo(self.manager.paths.mountinfo.read_bytes())
        for options in (("ro", "freezer"), ("rw", "freezer", "memory")):
            with self.subTest(options=options):
                mounts = [dict(item) for item in original]
                mounts[0]["super_options"] = options
                with self.assertRaises(lease.LeaseError):
                    freezer_module.LegacyFreezer(self.manager, mounts, lease.LeaseError)
        with self.assertRaises(lease.LeaseError):
            freezer_module.LegacyFreezer(self.manager, original + [original[0]], lease.LeaseError)

    def test_controller_traversal_and_process_counts_are_bounded(self):
        members = self.services / "xrdp.service" / "cgroup.procs"
        members.write_text("\n".join(str(pid) for pid in range(1, freezer_module.MAX_PROCESSES + 2)))
        with self.assertRaises(lease.LeaseError):
            self.gate._members(self.services)
        for index in range(freezer_module.MAX_GROUPS):
            self.new_group(self.services / f"group-{index}")
        with self.assertRaises(lease.LeaseError):
            self.gate._groups(self.services)


if __name__ == "__main__":
    unittest.main()
