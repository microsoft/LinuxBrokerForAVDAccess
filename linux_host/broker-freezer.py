"""Legacy XRDP gate: a separately mounted cgroup-v1 freezer, not SIGSTOP/PID-tree guesses."""

import os
from pathlib import Path
import re
import signal
import stat
import time


UNITS = ("xrdp.service", "xrdp-sesman.service")
SERVICE_PATH = "/linuxbroker-xrdp/services"
MAX_GROUPS = 256
MAX_PROCESSES = 4096
PF_FROZEN = 0x00010000


class LegacyFreezer:
    def __init__(self, manager, mounts, error, timeout=20):
        self.manager = manager
        self.error = error
        self.timeout = timeout
        self._signal = os.kill
        self.proc = manager.paths.proc
        self.controller = self._mount(mounts, "freezer")
        self.systemd = self._mount(mounts, "name=systemd")
        self.base = self.controller / "linuxbroker-xrdp"
        self.services = self.base / "services"
        self.quarantine = self.base / "cleanup"
        self.device = self.controller.stat().st_dev

    def _mount(self, mounts, controller):
        matches = [mount for mount in mounts if mount["fstype"] == "cgroup" and controller in mount["super_options"]]
        if len(matches) != 1 or matches[0]["fsroot"] != "/" or matches[0]["target"] == "/":
            raise self.error("A unique complete cgroup-v1 hierarchy is required.")
        if controller == "freezer":
            allowed = {"rw", "ro", "relatime", "seclabel", "xattr", "noprefix", "clone_children", "freezer"}
            if ("rw" not in matches[0]["super_options"] or "ro" in matches[0]["super_options"]
                    or any(option not in allowed for option in matches[0]["super_options"])):
                raise self.error("The legacy freezer must be writable and separate from resource controllers.")
        path = Path(matches[0]["target"])
        if self.manager.mount_info(path) is None:
            raise self.error("The cgroup-v1 mount is not visible.")
        self._protected(path, directory=True)
        return path

    def _protected(self, path, directory=False):
        info = path.lstat()
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if not expected(info.st_mode) or info.st_uid != self.manager.owner_uid or info.st_mode & 0o022:
            raise self.error("The XRDP freezer hierarchy is not root-controlled.")
        if hasattr(self, "device") and path.is_relative_to(self.controller) and info.st_dev != self.device:
            raise self.error("The freezer control path crosses another filesystem.")

    def _read(self, path):
        self._protected(path)
        return path.read_text(encoding="ascii").strip()

    def _write(self, path, value):
        self._protected(path)
        descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            info = os.fstat(descriptor)
            if info.st_uid != self.manager.owner_uid or info.st_dev != self.device:
                raise self.error("The freezer control file changed.")
            data = (value + "\n").encode("ascii")
            if os.write(descriptor, data) != len(data):
                raise self.error("The freezer control write was incomplete.")
        finally:
            os.close(descriptor)

    def _groups(self, root):
        groups, pending = [], [root]
        while pending:
            path = pending.pop()
            self._protected(path, directory=True)
            groups.append(path)
            if len(groups) > MAX_GROUPS:
                raise self.error("The XRDP freezer hierarchy exceeds the bounded inspection limit.")
            for entry in path.iterdir():
                if entry.is_symlink():
                    raise self.error("A freezer hierarchy must not contain symlinks.")
                if entry.is_dir():
                    pending.append(entry)
        return groups

    def _members(self, root):
        members = set()
        for group in self._groups(root):
            for value in self._read(group / "cgroup.procs").split():
                if not re.fullmatch(r"[1-9][0-9]*", value):
                    raise self.error("The freezer process list is malformed.")
                members.add(int(value))
                if len(members) > MAX_PROCESSES:
                    raise self.error("The freezer process list exceeds its inspection limit.")
        return members

    def _process_group(self, pid, controller):
        matches = []
        for line in (self.proc / str(pid) / "cgroup").read_text(encoding="ascii").splitlines():
            fields = line.split(":", 2)
            if len(fields) != 3 or not fields[0].isdigit():
                raise self.error("Process cgroup membership is malformed.")
            if controller in fields[1].split(","):
                path = fields[2]
                if not path.startswith("/") or any(part in (".", "..") for part in path.split("/")):
                    raise self.error("Process cgroup membership is invalid.")
                matches.append(path)
        if len(matches) != 1:
            raise self.error("Process membership in the expected hierarchy is unknown.")
        return matches[0]

    def _protected_systemd_path(self, value):
        path = self.systemd
        for part in value.lstrip("/").split("/"):
            path = path / part
            self._protected(path, directory=True)
        return path

    def _properties(self, unit, allow_inactive=False):
        result = self.manager.command(
            "systemctl", "show", unit, "--property=LoadState", "--property=ActiveState",
            "--property=ControlGroup", "--property=MainPID", "--property=ExecStart", "--no-pager",
        )
        properties = {}
        for line in result.stdout.splitlines():
            name, separator, value = line.partition("=")
            if separator and name in ("LoadState", "ActiveState", "ControlGroup", "MainPID", "ExecStart"):
                if name in properties:
                    raise self.error("XRDP service properties are ambiguous.")
                properties[name] = value
        if set(properties) != {"LoadState", "ActiveState", "ControlGroup", "MainPID", "ExecStart"}:
            raise self.error("XRDP service properties are incomplete.")
        path = properties["ControlGroup"]
        if allow_inactive and properties["ActiveState"] in ("inactive", "activating", "deactivating", "failed") and not path:
            path = "/system.slice/" + unit
        if (properties["LoadState"] != "loaded" or not path.startswith("/") or path == "/"
                or any(part in (".", "..") for part in path.split("/"))):
            raise self.error("XRDP must have its own loaded systemd control group.")
        expected = f"argv[]=/usr/local/bin/manage-lease.sh run-xrdp {unit} "
        if expected not in properties["ExecStart"] or "path=/usr/local/bin/manage-lease.sh" not in properties["ExecStart"]:
            raise self.error("XRDP must start through the broker freezer wrapper.")
        return properties

    def _uids(self, pid):
        rows = [
            line.split()[1:] for line in (self.proc / str(pid) / "status").read_text(encoding="ascii").splitlines()
            if line.startswith("Uid:")
        ]
        if len(rows) != 1 or len(rows[0]) != 4 or any(not value.isdigit() for value in rows[0]):
            raise self.error("Process UID ownership is uncertain.")
        return tuple(int(value) for value in rows[0])

    def check(self, require_thawed=False, cleanup_uid=None):
        self._protected(self.base, directory=True)
        control = self.services / "freezer.state"
        self._protected(control)
        descriptor = os.open(control, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        os.close(descriptor)
        for path in (self.base, self.quarantine):
            if self._read(path / "freezer.state") != "THAWED":
                raise self.error("An unrelated freezer state prevents safe XRDP gating.")
        for pid in self._members(self.quarantine):
            if cleanup_uid is None or self._uids(pid) not in ((0,) * 4, (cleanup_uid,) * 4):
                raise self.error("The cleanup quarantine contains an unverified process.")
        self_group = self._process_group("self", "freezer")
        if self_group == SERVICE_PATH or self_group.startswith(SERVICE_PATH + "/"):
            raise self.error("The cleanup worker cannot freeze its own cgroup.")
        for group in self._groups(self.services):
            if group != self.services and self._read(group / "freezer.self_freezing") != "0":
                raise self.error("An independently frozen descendant requires explicit recovery.")
            if require_thawed and self._read(group / "freezer.state") != "THAWED":
                raise self.error("A prior freezer operation requires guarded recovery.")
        for unit in UNITS:
            properties = self._properties(unit)
            if properties["ActiveState"] != "active" or not re.fullmatch(r"[1-9][0-9]*", properties["MainPID"]):
                raise self.error("Both enrolled XRDP services must be active.")
            self._check_service_members(unit, properties, cleanup_uid)

    def _verify_main_identity(self, pid, systemd_group):
        if self._uids(pid) != (0,) * 4:
            raise self.error("The XRDP main process has an unexpected process-owner mismatch.")
        if self._process_group(pid, "name=systemd") != systemd_group:
            raise self.error("The XRDP main process has an unexpected systemd-group mismatch.")

    def _check_service_members(self, unit, properties, cleanup_uid=None):
        main_pid = int(properties["MainPID"])
        self._verify_main_identity(main_pid, properties["ControlGroup"])
        expected = SERVICE_PATH + "/" + unit
        if self._process_group(main_pid, "freezer") != expected:
            raise self.error("A running XRDP daemon is not enrolled; drain before its controlled restart.")
        members = self._members(self._protected_systemd_path(properties["ControlGroup"]))
        if main_pid not in members:
            raise self.error("The XRDP main process does not match its systemd group.")
        for pid in members:
            group = self._process_group(pid, "freezer")
            if group == expected or group.startswith(expected + "/"):
                continue
            if cleanup_uid is not None and group == "/linuxbroker-xrdp/cleanup" and self._uids(pid) == (cleanup_uid,) * 4:
                continue
            raise self.error("An XRDP descendant escaped the verified freezer hierarchy.")

    def _wait(self, state):
        deadline = time.monotonic() + self.timeout
        while True:
            states = [self._read(group / "freezer.state") for group in self._groups(self.services)]
            if any(value not in ("THAWED", "FREEZING", "FROZEN") for value in states):
                raise self.error("The freezer returned an unknown state.")
            if all(value == state for value in states):
                return
            if time.monotonic() >= deadline:
                raise self.error("The XRDP freezer did not reach the required state.")
            time.sleep(0.02)

    def freeze(self, cleanup_uid):
        self.check(cleanup_uid=cleanup_uid)
        self._write(self.services / "freezer.state", "FROZEN")
        self._wait("FROZEN")
        self.check(cleanup_uid=cleanup_uid)
        self._wait("FROZEN")

    def thaw(self):
        self._write(self.services / "freezer.state", "THAWED")
        self._wait("THAWED")

    def termination_targets(self, uid):
        """Verify the complete frozen set before committing to discard accepted logins."""
        self._wait("FROZEN")
        targets = []
        for pid in self._members(self.services):
            uids = self._uids(pid)
            if uids not in ((uid,) * 4, (0,) * 4):
                raise self.error("Cleanup cannot terminate another user's or mixed-privilege XRDP process.")
            self._verify_frozen_threads(pid)
            targets.append(pid)
        self._wait("FROZEN")
        return targets

    def _verify_frozen_threads(self, pid):
        tasks = list((self.proc / str(pid) / "task").iterdir())
        if not tasks or len(tasks) > MAX_PROCESSES:
            raise self.error("The frozen thread set is invalid.")
        for task in tasks:
            if not task.name.isdigit():
                raise self.error("The frozen thread set is invalid.")
            text = (task / "stat").read_text(encoding="ascii")
            _prefix, separator, state = text.rpartition(") ")
            fields = state.split()
            if (not separator or len(fields) < 20 or fields[0] != "D"
                    or not fields[6].isdigit() or not int(fields[6]) & PF_FROZEN):
                # v1 counts stopped/vfork tasks without PF_FROZEN. Do not transfer
                # or signal those numeric PIDs based on the aggregate state alone.
                raise self.error("Every XRDP thread must be actually frozen before signalling.")

    def disconnect_connection(self, pid):
        self._wait("FROZEN")
        properties = self._properties("xrdp.service")
        if pid == int(properties["MainPID"]):
            raise self.error("Idle disconnect must not terminate the XRDP listener.")
        group = self._process_group(pid, "freezer")
        expected = SERVICE_PATH + "/xrdp.service"
        if group != expected and not group.startswith(expected + "/"):
            raise self.error("The idle connection is outside the enrolled XRDP service.")
        if self.manager.command("ps", "-p", str(pid), "-o", "comm=").stdout.strip() != "xrdp":
            raise self.error("The idle connection is not an XRDP process.")
        self._verify_frozen_threads(pid)
        self._signal(pid, signal.SIGTERM)

    def terminate(self, targets):
        # v1 tasks carrying PF_FROZEN cannot act on even SIGKILL until thawed. Queue
        # SIGKILL first, then move the prevalidated groups to a THAWED sibling so they
        # exit without executing cached, previously authenticated XRDP requests.
        self.manager.command("systemctl", "stop", "--no-block", *UNITS)
        for pid in targets:
            self._signal(pid, signal.SIGKILL)
        for pid in targets:
            self._write(self.quarantine / "cgroup.procs", str(pid))
        self._wait("FROZEN")
        deadline = time.monotonic() + self.timeout
        while self._members(self.quarantine):
            if time.monotonic() >= deadline:
                raise self.error("The terminated XRDP processes have not left quarantine.")
            time.sleep(0.02)

    def recover_termination(self, uid):
        self._protected(self.base, directory=True)
        if self._read(self.base / "freezer.state") != "THAWED":
            raise self.error("An unrelated parent freezer prevents recovery.")
        for unit in UNITS:
            self._properties(unit, allow_inactive=True)
        if self._read(self.services / "freezer.self_freezing") != "1":
            raise self.error("The interrupted termination lost its freezer fence.")
        if self._read(self.quarantine / "freezer.state") != "THAWED":
            raise self.error("The interrupted termination quarantine is not thawed.")
        self_group = self._process_group("self", "freezer")
        if self_group == SERVICE_PATH or self_group.startswith(SERVICE_PATH + "/"):
            raise self.error("A frozen worker cannot recover its own hierarchy.")
        for group in self._groups(self.services):
            if group != self.services and self._read(group / "freezer.self_freezing") != "0":
                raise self.error("An independently frozen descendant prevents termination recovery.")
        for pid in self._members(self.quarantine):
            if self._uids(pid) not in ((0,) * 4, (uid,) * 4):
                raise self.error("The interrupted quarantine contains another identity.")
        self.terminate(self.termination_targets(uid))

    def restart(self):
        self.thaw()
        # Finish an interrupted stop, then launch only clean daemons through their
        # verified enrollment wrappers. Availability is not acknowledged before this.
        self.manager.command("systemctl", "stop", *UNITS)
        self.manager.command("systemctl", "start", *reversed(UNITS))
        self.wait_ready()

    def wait_ready(self):
        # Type=simple/exec can report start success while the wrapper has not yet
        # reached cgroup.procs. Only that bounded startup interval is retried.
        deadline = time.monotonic() + self.timeout
        while True:
            starting = not self._startup_hierarchy_ready()
            for unit in UNITS:
                properties = self._properties(unit, allow_inactive=True)
                state, raw_pid = properties["ActiveState"], properties["MainPID"]
                if state == "failed":
                    raise self.error("An enrolled XRDP service failed during startup.")
                if state not in ("active", "activating", "inactive"):
                    raise self.error("XRDP startup entered an unexpected service state.")
                if not re.fullmatch(r"0|[1-9][0-9]*", raw_pid):
                    raise self.error("XRDP startup returned an invalid main process.")
                if state != "active" or raw_pid == "0":
                    starting = True
                    continue
                try:
                    self._verify_main_identity(int(raw_pid), properties["ControlGroup"])
                    membership = self._process_group(int(raw_pid), "freezer")
                    if membership != SERVICE_PATH + "/" + unit:
                        enrolled = self._verify_starting_wrapper(
                            int(raw_pid), unit, membership, properties["ControlGroup"],
                        )
                        starting = starting or not enrolled
                        if enrolled:
                            self._check_service_members(unit, properties)
                    else:
                        self._check_service_members(unit, properties)
                except FileNotFoundError as error:
                    process = self.proc / raw_pid
                    expected_files = {process / name for name in ("cgroup", "status", "cmdline", "stat", "exe")}
                    if error.filename is None or Path(error.filename) not in expected_files:
                        raise
                    self._protected(self.proc, directory=True)
                    try:
                        process.lstat()
                    except FileNotFoundError:
                        pass
                    else:
                        # A missing metadata file in a still-existing process is
                        # not evidence of a just-exited startup process.
                        raise error
                    starting = True
                    continue
            if time.monotonic() >= deadline:
                raise self.error("XRDP did not complete verified freezer enrollment before the startup deadline.")
            if not starting:
                # Permission, wrapper, descendant, and freezer failures remain
                # explicit failures, not success-shaped startup retries.
                self.check(require_thawed=True)
                return
            time.sleep(0.02)

    def _startup_hierarchy_ready(self):
        self._protected(self.controller, directory=True)
        self._protected(self.systemd, directory=True)
        ready = True
        roots = (self.base, self.services, self.quarantine, *(self.services / unit for unit in UNITS))
        for root in roots:
            try:
                self._protected(root, directory=True)
            except FileNotFoundError:
                ready = False
                continue
            for name in ("freezer.state", "freezer.self_freezing", "cgroup.procs"):
                try:
                    self._protected(root / name)
                except FileNotFoundError:
                    ready = False
        return ready

    def _verify_starting_wrapper(self, pid, unit, membership, systemd_group):
        expected_group = SERVICE_PATH + "/" + unit
        if membership != "/" or self._process_group(pid, "name=systemd") != systemd_group:
            raise self.error("XRDP startup has an unexpected control-group or process-owner mismatch.")
        current_group = self._process_group(pid, "freezer")
        if current_group == expected_group:
            return True
        if current_group != "/":
            raise self.error("XRDP startup has an unexpected control-group mismatch.")
        if self._uids(pid) != (0,) * 4:
            if self._process_group(pid, "freezer") == expected_group:
                return True
            raise self.error("XRDP startup has an unexpected process-owner mismatch.")
        with (self.proc / str(pid) / "cmdline").open("rb") as stream:
            command = stream.read(8193)
        if not command or len(command) > 8192 or not command.endswith(b"\0"):
            if self._process_group(pid, "freezer") == expected_group:
                return True
            raise self.error("The pending XRDP startup command cannot be verified.")
        arguments = command[:-1].split(b"\0")
        prefixes = (
            [b"/bin/bash", b"/usr/local/bin/manage-lease.sh", b"run-xrdp", unit.encode("ascii")],
            [b"/usr/bin/bash", b"/usr/local/bin/manage-lease.sh", b"run-xrdp", unit.encode("ascii")],
            [b"/usr/local/libexec/linuxbroker/python3", b"-I", b"/usr/local/bin/broker-lease.py",
             b"run-xrdp", unit.encode("ascii")],
        )
        daemon = unit.removesuffix(".service")
        for prefix in prefixes:
            if (arguments[:len(prefix)] == prefix and len(arguments) > len(prefix)
                    and arguments[len(prefix)] in (
                        f"/usr/sbin/{daemon}".encode("ascii"), f"/usr/local/sbin/{daemon}".encode("ascii"),
                    )):
                return False
        # Type=simple may return while PID 1's child has not yet executed the
        # wrapper. Verify that specific pre-exec stage, not an arbitrary daemon.
        stat_text = (self.proc / str(pid) / "stat").read_text(encoding="ascii")
        _prefix, separator, tail = stat_text.rpartition(") ")
        fields = tail.split()
        executable = os.readlink(self.proc / str(pid) / "exe")
        if (separator and len(fields) >= 20 and fields[1] == "1" and fields[6].isdigit()
                and int(fields[6]) & 0x00000040
                and executable in ("/usr/lib/systemd/systemd", "/lib/systemd/systemd")):
            return False
        # The wrapper may have enrolled and exec'd between the initial cgroup
        # read and cmdline/stat inspection. Re-read, then let check() verify all
        # ownership and descendant invariants before acknowledging readiness.
        if self._process_group(pid, "freezer") == expected_group:
            return True
        raise self.error("An unenrolled XRDP process is not a verified pre-exec startup wrapper.")

    def run(self, unit, command):
        if unit not in UNITS or not command:
            raise self.error("A supported XRDP service and executable are required.")
        program = Path(command[0])
        daemon = unit.removesuffix(".service")
        if str(program) not in (f"/usr/sbin/{daemon}", f"/usr/local/sbin/{daemon}"):
            raise self.error("Only the selected XRDP daemon may use the startup wrapper.")
        info = program.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != self.manager.owner_uid or info.st_mode & 0o022:
            raise self.error("The XRDP executable is not protected.")
        properties = self._properties(unit)
        if self._process_group("self", "name=systemd") != properties["ControlGroup"]:
            raise self.error("The startup wrapper must run inside its own systemd service.")
        for group in (self.base, self.services, self.quarantine, self.services / unit):
            group.mkdir(mode=0o755, exist_ok=True)
            self._protected(group, directory=True)
        # The kernel moves this process and all its threads atomically. If cleanup
        # already froze the parent, this call cannot return to exec until thawed.
        self._enroll_current(unit)
        os.execv(str(program), command)

    def _enroll_current(self, unit):
        self._write(self.services / unit / "cgroup.procs", "0")
        if self._process_group("self", "freezer") != SERVICE_PATH + "/" + unit:
            raise self.error("The XRDP startup process did not join its freezer group.")
