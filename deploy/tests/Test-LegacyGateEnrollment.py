"""Legacy gate installation tests: all service/process/ownership operations are stubs."""

from contextlib import contextmanager
import errno
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import sys
import shlex
import tempfile
import types
import unittest
from unittest import mock


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "broker_gate_installer", REPO / "custom_script_extensions" / "configure-broker-xrdp-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class FakeFreezer:
    def __init__(self, root):
        self.controller = root / "controller"
        self.controller.mkdir()
        self.base = self.controller / "linuxbroker-xrdp"
        self.services = self.base / "services"
        self.quarantine = self.base / "cleanup"
        self.checks = 0
        self.failure = False
        self.members = set()
        self.state = "THAWED"
        self.check_error = None
        self.inspect_initial_path = False
        self.wait_calls = 0
        self.wait_error = None
        self.startup_states = []
        self.startup_attempts = 0
        self.controller_error = None

    def check(self, require_thawed):
        if require_thawed is not True:
            raise AssertionError("Enrollment must confirm a thawed controller.")
        self.checks += 1
        if self.check_error is not None:
            raise self.check_error
        if self.inspect_initial_path:
            self.base.lstat()
        if self.failure:
            raise gate.GateEnrollmentError("Synthetic unresolved kernel gate.")

    def wait_ready(self):
        self.wait_calls += 1
        if self.wait_error is not None:
            raise self.wait_error
        while self.startup_states:
            state = self.startup_states.pop(0)
            self.startup_attempts += 1
            if state not in ("activating", "wrapper-enrolling", "ready"):
                raise AssertionError("Only the core helper may classify transient startup.")
        self.check(require_thawed=True)

    def _members(self, path):
        return self.members

    def _protected(self, path, directory=False):
        if path != self.controller or not directory:
            raise AssertionError("Recovery may validate only the existing root controller.")
        if self.controller_error is not None:
            raise self.controller_error
        path.lstat()

    def _read(self, path):
        return self.state


class FakeManager:
    def __init__(self, root):
        root.mkdir(parents=True, exist_ok=True)
        self.paths = types.SimpleNamespace(state=root, homes=PurePosixPath("/home"), mountinfo=root / "mountinfo")
        self.paths.mountinfo.write_bytes(b"fixture\n")
        self.marker = root / "lease.json"
        self.marker_data = None
        self.freezer = FakeFreezer(root)
        self.modern = False
        self.calls = []
        self.sessions = ""
        self.sockets = ""
        self.accounts = "root:x:0:0:root:/root:/bin/bash\navdadmin:x:1000:1000::/home/avdadmin:/bin/bash\n"
        self.desktop_present = False
        self.wrapped = False
        self.active_state = "active"
        self.unit_states = {}
        self.unit_pids = {}
        self.fail_after_stop = False
        self.stopped = False
        self.started = False
        self.locked_now = False
        self.unit_directory = root / "units"
        self.unit_directory.mkdir()
        self.unit_type = "forking"
        self.loaded_commands = {}
        self.loaded_dropins = {}
        self.interrupt_after_reload = False
        self.override_on_reload = False
        self.ignore_wrappers_on_reload = False

    def unit_text(self, unit):
        daemon = unit.removesuffix(".service")
        output = "# /usr/lib/systemd/system/{}\n[Service]\nEnvironmentFile=-/etc/sysconfig/xrdp\nExecStart=/usr/sbin/{} $OPTIONS\n".format(unit, daemon)
        files = {path.name: (path, path.read_text()) for path in (self.unit_directory / (unit + ".d")).glob("*.conf")}
        if self.wrapped and gate.DROPIN_NAME not in files:
            path = self.unit_directory / (unit + ".d") / gate.DROPIN_NAME
            files[gate.DROPIN_NAME] = (path, gate.desired_dropin(unit, "/usr/sbin/{} $OPTIONS".format(daemon)))
        for name in sorted(files):
            path, content = files[name]
            output += "\n# " + path.as_posix() + "\n" + content
        return output, [files[name][0] for name in sorted(files)]

    def load_unit(self, unit):
        text, dropins = self.unit_text(unit)
        command = ""
        for line in text.splitlines():
            if line.strip().startswith("ExecStart="):
                command = line.strip()[len("ExecStart="):]
        if self.ignore_wrappers_on_reload:
            command = "/usr/sbin/" + unit.removesuffix(".service") + " $OPTIONS"
        self.loaded_commands[unit] = command
        self.loaded_dropins[unit] = dropins

    def legacy_freezer(self):
        return None if self.modern else self.freezer

    def gate_status(self):
        self.calls.append(("gate-status",))
        return {"ready": True, "backend": "systemd-v2"}

    def read(self):
        return self.marker_data

    @contextmanager
    def locked(self):
        self.locked_now = True
        try:
            yield
        finally:
            self.locked_now = False

    def command(self, *args, allowed=(0,)):
        self.calls.append(args)
        output = ""
        returncode = 0
        if args[:2] == ("systemctl", "show"):
            unit = args[2]
            if unit not in self.loaded_commands:
                self.load_unit(unit)
            command = self.loaded_commands[unit]
            path = command.split(" ")[0]
            active_state = self.unit_states.get(unit, self.active_state)
            pid = self.unit_pids.get(unit, "0" if active_state in ("inactive", "failed") else "1234")
            output = ("LoadState=loaded\nUser=\nGroup=\nType={}\nActiveState={}\nMainPID={}\n"
                      "DropInPaths={}\nExecStart={{ path={} ; argv[]={} ; }}\n").format(
                          self.unit_type, active_state, pid,
                          " ".join(shlex.quote(path.as_posix()) for path in self.loaded_dropins[unit]), path, command)
        elif args[:2] == ("systemctl", "cat"):
            output, _paths = self.unit_text(args[2])
        elif args[:2] == ("systemctl", "stop"):
            if not self.locked_now:
                raise AssertionError("Service enrollment must remain serialized with lease operations.")
            self.stopped = True
        elif args[:2] == ("systemctl", "start"):
            if not self.stopped or not self.locked_now:
                raise AssertionError("Only the serialized drained installation can start fresh daemons.")
            self.started = True
            self.wrapped = True
            self.freezer.failure = False
            self.freezer.check_error = None
            self.freezer.base.mkdir(exist_ok=True)
        elif args[:2] == ("systemctl", "daemon-reload"):
            if not self.locked_now:
                raise AssertionError("Drop-in activation must hold the lease lock.")
            if self.override_on_reload:
                path = self.unit_directory / "xrdp.service.d" / "override.conf"
                path.parent.mkdir(exist_ok=True)
                path.write_text("[Service]\nExecStart=\nExecStart=/usr/sbin/xrdp --nodaemon\n")
            for unit in gate.UNITS:
                self.load_unit(unit)
            if self.interrupt_after_reload:
                raise RuntimeError("Synthetic interruption after wrappers/reload, before first service start.")
        elif args[:2] == ("loginctl", "list-sessions"):
            output = "1 10001 alice\n" if self.fail_after_stop and self.stopped else self.sessions
        elif args[:2] == ("pgrep", "-x"):
            returncode = 0 if self.desktop_present else 1
        elif args == ("getent", "passwd"):
            output = self.accounts
        elif args[:2] == ("ss", "-Htn"):
            output = self.sockets
        else:
            raise AssertionError("Unexpected real/unsupported service command: " + repr(args))
        return types.SimpleNamespace(stdout=output, returncode=returncode)


class LegacyEnrollmentTests(unittest.TestCase):
    def setUp(self):
        parent = REPO / "deploy" / ".artifacts"
        parent.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="legacy-enrollment-test-", dir=str(parent))
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manager = FakeManager(self.root)
        self.mounts = []
        self.installer = gate.GateInstaller(self.manager, lambda _: self.mounts, directory=self.manager.unit_directory)
        self.directory_guard = mock.patch.object(gate, "protected_directory")
        self.file_guard = mock.patch.object(gate, "protected_file")
        self.chown = mock.patch.object(gate.os, "chown", create=True)
        self.directory_guard.start()
        self.file_guard.start()
        self.chown.start()
        self.addCleanup(self.directory_guard.stop)
        self.addCleanup(self.file_guard.stop)
        self.addCleanup(self.chown.stop)

    def mutate_calls(self):
        return [call for call in self.manager.calls if call[:2] in (
            ("systemctl", "stop"), ("systemctl", "start"), ("systemctl", "daemon-reload"))]

    def test_requires_explicit_drained_enrollment(self):
        with self.assertRaisesRegex(gate.GateEnrollmentError, "explicitly allow"):
            self.installer.enroll(False, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_fresh_drained_host_gets_startup_wrappers_and_preserved_flags(self):
        self.assertEqual(self.installer.enroll(True, {"kind": "absent"}, "avdadmin"), "freezer-v1")
        for unit in gate.UNITS:
            text = (self.manager.unit_directory / (unit + ".d") / gate.DROPIN_NAME).read_text()
            self.assertIn("ExecStart=\n", text)
            self.assertIn(gate.WRAPPER + " run-xrdp " + unit, text)
            self.assertTrue(text.endswith(" $OPTIONS\n"))
        self.assertEqual(self.mutate_calls(), [
            ("systemctl", "daemon-reload"),
            ("systemctl", "stop", *gate.UNITS),
            ("systemctl", "start", "xrdp-sesman.service", "xrdp.service"),
        ])
        self.assertEqual(self.manager.freezer.checks, 1)
        self.assertEqual(self.manager.freezer.wait_calls, 1)
        before = len(self.mutate_calls())
        self.assertEqual(self.installer.enroll(False, {"kind": "active"}, "avdadmin"), "freezer-v1")
        self.assertEqual(len(self.mutate_calls()), before)

    def test_modern_gate_is_checked_without_unit_changes(self):
        self.manager.modern = True
        self.assertEqual(self.installer.enroll(False, None, "avdadmin"), "systemd-v2")
        self.assertEqual(self.mutate_calls(), [])

    def test_active_sql_state_prevents_service_restart_even_with_flag(self):
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "active"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_local_sessions_desktops_accounts_sockets_and_mounts_block(self):
        mutations = (
            ("sessions", "1 10001 alice\n"), ("desktop_present", True),
            ("accounts", "alice:x:10001:10001::/home/alice:/bin/bash\n"),
            ("accounts", "legacy:x:1001:1001::/home/legacy:/bin/bash\n"),
            ("sockets", "0 0 10.0.0.4:3389 10.0.0.8:44500\n"),
        )
        for name, value in mutations:
            with self.subTest(name=name):
                old = getattr(self.manager, name)
                setattr(self.manager, name, value)
                with self.assertRaises(gate.GateEnrollmentError):
                    self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
                self.assertEqual(self.mutate_calls(), [])
                setattr(self.manager, name, old)
        self.mounts = [{"target": str(self.manager.paths.homes / "alice")}]
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_post_stop_recheck_blocks_newly_uncertain_state(self):
        self.manager.fail_after_stop = True
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertFalse(self.manager.started)
        self.assertTrue(any(self.manager.unit_directory.rglob("*.conf")))
        self.assertEqual(self.mutate_calls(), [
            ("systemctl", "daemon-reload"), ("systemctl", "stop", *gate.UNITS)])

    def test_unknown_lease_or_live_freezer_is_never_reset(self):
        self.manager.marker_data = {"phase": "ready"}
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.manager.marker_data = None
        self.manager.freezer.base.mkdir()
        self.manager.freezer.members = {1234}
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.manager.freezer.members = set()
        self.manager.freezer.state = "FROZEN"
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_cleaned_marker_fingerprint_is_preserved(self):
        marker = {"phase": "cleaned", "operationId": "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
                  "username": "alice", "uid": 10001, "leaseGeneration": 7, "gateClosed": False}
        self.manager.marker_data = marker
        original = json.dumps(marker).encode()
        self.manager.marker.write_bytes(original)
        evidence = {"kind": "cleaned", "username": "alice", "uid": 10001, "fence": 8,
                    "sha256": hashlib.sha256(original).hexdigest()}
        self.installer.enroll(True, evidence, "avdadmin")
        self.assertEqual(self.manager.marker.read_bytes(), original)

    def test_already_wrapped_uncertain_gate_never_uses_enrollment_to_recover(self):
        self.manager.wrapped = True
        self.manager.freezer.failure = True
        with self.assertRaisesRegex(gate.GateEnrollmentError, "guarded recovery"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_conflicting_dropin_is_not_overwritten(self):
        path = self.manager.unit_directory / "xrdp.service.d" / gate.DROPIN_NAME
        path.parent.mkdir()
        path.write_text("[Service]\nExecStart=\nExecStart=/usr/sbin/xrdp --nodaemon\n")
        with self.assertRaisesRegex(gate.GateEnrollmentError, "conflicts"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_cleaned_marker_with_unresolved_restart_flag_cannot_reenroll(self):
        self.manager.marker_data = {
            "phase": "cleaned", "operationId": "aaaaaaaa-aaaa-4aaa-8aaa-000000000001",
            "username": "alice", "uid": 10001, "leaseGeneration": 7, "gateRestartRequired": True,
        }
        self.manager.marker.write_bytes(json.dumps(self.manager.marker_data).encode())
        evidence = {"kind": "cleaned", "username": "alice", "uid": 10001, "fence": 8,
                    "sha256": hashlib.sha256(self.manager.marker.read_bytes()).hexdigest()}
        with self.assertRaises(gate.GateEnrollmentError):
            self.installer.enroll(True, evidence, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_interrupted_first_install_missing_initial_hierarchy_retries_after_reload(self):
        self.manager.active_state = "inactive"
        self.manager.interrupt_after_reload = True
        self.manager.freezer.inspect_initial_path = True
        with self.assertRaisesRegex(RuntimeError, "Synthetic interruption"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertFalse(self.manager.stopped)
        self.assertFalse(self.manager.started)
        self.assertFalse(self.manager.freezer.base.exists())
        for unit in gate.UNITS:
            self.assertTrue((self.manager.unit_directory / (unit + ".d") / gate.DROPIN_NAME).exists())
        self.manager.interrupt_after_reload = False
        with self.assertRaises(FileNotFoundError):
            self.installer.enroll(False, {"kind": "absent"}, "avdadmin")
        self.assertFalse(self.manager.stopped)
        self.assertEqual(self.installer.enroll(True, {"kind": "absent"}, "avdadmin"), "freezer-v1")
        self.assertTrue(self.manager.started)

    def test_later_direct_daemon_override_rejected_before_any_service_change(self):
        path = self.manager.unit_directory / "xrdp.service.d" / "override.conf"
        path.parent.mkdir()
        original = "[Service]\nExecStart=\nExecStart=/usr/sbin/xrdp --nodaemon $XRDP_OPTIONS\n"
        path.write_text(original)
        with self.assertRaisesRegex(gate.GateEnrollmentError, "later-ordered"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])
        self.assertEqual(path.read_text(), original)
        self.assertFalse((path.parent / gate.DROPIN_NAME).exists())

    def test_later_unrelated_override_is_preserved_and_effective_wrapper_verified(self):
        path = self.manager.unit_directory / "xrdp.service.d" / "override.conf"
        path.parent.mkdir()
        original = "[Service]\nEnvironment=UNCHANGED=true\n"
        path.write_text(original)
        self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(path.read_text(), original)
        reload_index = self.manager.calls.index(("systemctl", "daemon-reload"))
        stop_index = self.manager.calls.index(("systemctl", "stop", *gate.UNITS))
        for unit in gate.UNITS:
            self.assertTrue(any(call[:3] == ("systemctl", "show", unit)
                                for call in self.manager.calls[reload_index + 1:stop_index]))

    def test_override_added_at_reload_cannot_start_unenrolled_services(self):
        self.manager.override_on_reload = True
        with self.assertRaisesRegex(gate.GateEnrollmentError, "later-ordered"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertFalse(self.manager.stopped)
        self.assertFalse(self.manager.started)

    def test_reloaded_effective_command_must_be_the_wrapper(self):
        self.manager.ignore_wrappers_on_reload = True
        with self.assertRaisesRegex(gate.GateEnrollmentError, "Reloaded XRDP ExecStart"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertFalse(self.manager.stopped)
        self.assertFalse(self.manager.started)

    def test_simple_and_exec_start_delegate_delayed_enrollment_to_core_wait(self):
        for unit_type in ("simple", "exec"):
            with self.subTest(unit_type=unit_type):
                manager = FakeManager(self.root / unit_type)
                manager.unit_type = unit_type
                manager.freezer.startup_states = ["activating", "wrapper-enrolling", "ready"]
                installer = gate.GateInstaller(manager, lambda _: [], directory=manager.unit_directory)
                self.assertEqual(installer.enroll(True, {"kind": "absent"}, "avdadmin"), "freezer-v1")
                self.assertEqual(manager.freezer.wait_calls, 1)
                self.assertEqual(manager.freezer.startup_attempts, 3)

    def test_startup_timeout_and_ownership_failure_are_not_success_or_restarted(self):
        for message in ("Synthetic bounded startup timeout.", "Synthetic ownership mismatch."):
            with self.subTest(message=message):
                manager = FakeManager(self.root / ("timeout" if "timeout" in message else "ownership"))
                manager.unit_type = "simple"
                manager.freezer.wait_error = gate.GateEnrollmentError(message)
                installer = gate.GateInstaller(manager, lambda _: [], directory=manager.unit_directory)
                with self.assertRaisesRegex(gate.GateEnrollmentError, message):
                    installer.enroll(True, {"kind": "absent"}, "avdadmin")
                self.assertEqual(manager.freezer.wait_calls, 1)
                self.assertEqual(sum(call[:2] == ("systemctl", "start") for call in manager.calls), 1)

    def test_missing_other_file_or_permission_failure_is_not_initial_hierarchy_recovery(self):
        self.manager.wrapped = True
        self.manager.active_state = "inactive"
        for error in (
                FileNotFoundError(errno.ENOENT, "missing services", str(self.manager.freezer.services)),
                FileNotFoundError(errno.ENOENT, "missing proc", str(self.root / "proc" / "status")),
                PermissionError(errno.EACCES, "denied", str(self.manager.freezer.base)),
                gate.GateEnrollmentError("Synthetic ownership mismatch.")):
            with self.subTest(error=type(error).__name__):
                self.manager.freezer.check_error = error
                with self.assertRaises((OSError, gate.GateEnrollmentError)):
                    self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
                self.assertEqual(self.mutate_calls(), [])

    def test_missing_initial_hierarchy_requires_both_services_inactive_and_controller_present(self):
        self.manager.wrapped = True
        self.manager.freezer.inspect_initial_path = True
        with self.assertRaises(FileNotFoundError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.manager.active_state = "inactive"
        self.manager.freezer.controller.rmdir()
        with self.assertRaises(FileNotFoundError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_missing_initial_hierarchy_does_not_hide_controller_ownership_failure(self):
        self.manager.wrapped = True
        self.manager.active_state = "inactive"
        self.manager.freezer.inspect_initial_path = True
        self.manager.freezer.controller_error = gate.GateEnrollmentError("Controller ownership/device mismatch.")
        with self.assertRaisesRegex(gate.GateEnrollmentError, "ownership/device mismatch"):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_missing_initial_hierarchy_with_one_running_unit_or_lingering_mainpid_is_rejected(self):
        self.manager.wrapped = True
        self.manager.active_state = "inactive"
        self.manager.freezer.inspect_initial_path = True
        self.manager.unit_states["xrdp.service"] = "active"
        with self.assertRaises(FileNotFoundError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.manager.unit_states.clear()
        self.manager.unit_pids["xrdp.service"] = "42"
        with self.assertRaises(FileNotFoundError):
            self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_initial_missing_directory_exception_does_not_accept_a_dangling_link(self):
        self.manager.wrapped = True
        self.manager.active_state = "inactive"
        self.manager.freezer.inspect_initial_path = True
        original_lexists = gate.os.path.lexists
        with mock.patch.object(gate.os.path, "lexists",
                               side_effect=lambda value: True if Path(value) == self.manager.freezer.base else original_lexists(value)):
            with self.assertRaises(FileNotFoundError):
                self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertEqual(self.mutate_calls(), [])

    def test_startup_parser_preserves_distro_flags_and_rejects_shells(self):
        for path in ("/usr/sbin/xrdp", "/usr/local/sbin/xrdp"):
            command, executable = gate.startup_command(
                "xrdp.service", "[Service]\nExecStart={} --nodaemon $XRDP_OPTIONS\n".format(path))
            self.assertEqual(executable, path)
            self.assertEqual(command, path + " --nodaemon $XRDP_OPTIONS")
        for command in ("/bin/sh -c xrdp", "-/usr/sbin/xrdp", "/usr/sbin/xrdp ; other", "/usr/sbin/xrdp \\"):
            with self.subTest(command=command), self.assertRaises(gate.GateEnrollmentError):
                gate.startup_command("xrdp.service", "[Service]\nExecStart=" + command + "\n")

    def test_nonroot_service_identity_is_not_silently_elevated(self):
        for value in ("User=xrdp\nGroup=\n", "User=\nGroup=xrdp\n"):
            with self.subTest(value=value), self.assertRaises(gate.GateEnrollmentError):
                gate.unit_properties("LoadState=loaded\nType=forking\n" + value)
        with self.assertRaises(gate.GateEnrollmentError):
            gate.unit_properties("LoadState=loaded\nUser=\nGroup=\nType=oneshot\n")

    def test_parser_respects_execstart_reset_and_rejects_multiple_effective_commands(self):
        command, _ = gate.startup_command("xrdp.service",
            "[Service]\nExecStart=/old/override\nExecStart=\nExecStart=/usr/sbin/xrdp --nodaemon\n")
        self.assertEqual(command, "/usr/sbin/xrdp --nodaemon")
        with self.assertRaises(gate.GateEnrollmentError):
            gate.startup_command("xrdp.service",
                "[Service]\nExecStart=/usr/sbin/xrdp\nExecStart=/usr/sbin/xrdp --another\n")

    def test_installation_never_migrates_pids_or_issues_freeze_commands(self):
        self.installer.enroll(True, {"kind": "absent"}, "avdadmin")
        self.assertFalse(any(call[0] in ("kill", "pkill") or call[:2] in (
            ("systemctl", "freeze"), ("systemctl", "thaw")) for call in self.manager.calls))
        source = (REPO / "custom_script_extensions" / "configure-broker-xrdp-gate.py").read_text()
        self.assertNotIn('cgroup.procs",', source)
        self.assertNotIn("os.kill(", source)


if __name__ == "__main__":
    unittest.main()
