#!/usr/local/libexec/linuxbroker/python3 -I
"""Enroll drained legacy XRDP services at startup; never adopt a live PID tree."""

import argparse
import base64
from collections import namedtuple
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile


UNITS = ("xrdp.service", "xrdp-sesman.service")
UNIT_DIRECTORY = Path("/etc/systemd/system")
DROPIN_NAME = "50-linuxbroker-freezer.conf"
WRAPPER = "/usr/local/bin/manage-lease.sh"
HEADER = "# Managed by Linux Broker verified legacy freezer enrollment.\n"
UnitPlan = namedtuple("UnitPlan", "unit path content wrapped active_state main_pid")


class GateEnrollmentError(Exception):
    pass


def startup_command(unit, content):
    section = ""
    commands = []
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line
            continue
        key, separator, value = line.partition("=")
        if section != "[Service]" or not separator or key.strip() != "ExecStart":
            continue
        value = value.strip()
        if not value:
            commands = []
        else:
            if value.endswith("\\"):
                raise GateEnrollmentError("Multiline/custom XRDP startup commands require explicit operator review.")
            commands.append(value)
    if len(commands) != 1:
        raise GateEnrollmentError("Each XRDP unit must have exactly one verified ExecStart command.")
    command = commands[0]
    prefix = "{} run-xrdp {} ".format(WRAPPER, unit)
    if command.startswith(prefix):
        command = command[len(prefix):]
    daemon = unit.removesuffix(".service")
    pattern = r"^(/usr/(?:local/)?sbin/" + re.escape(daemon) + r")(?:[ \t]+([^\x00-\x1f;]*))?$"
    match = re.fullmatch(pattern, command)
    if not match:
        raise GateEnrollmentError("The XRDP service must start its protected daemon directly; unsupported prefixes/shells are not rewritten.")
    return command, match[1]


def protected_directory(path):
    for parent in [path] + list(path.parents):
        if not parent.exists() and not parent.is_symlink():
            continue
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise GateEnrollmentError("XRDP unit/drop-in directories must be root-controlled and nonlinked.")


def protected_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise GateEnrollmentError("An XRDP daemon or deployment-managed drop-in is not root-controlled.")


def unit_properties(text):
    result = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key in result:
            raise GateEnrollmentError("The XRDP unit properties are ambiguous.")
        result[key] = value
    required = {"LoadState", "User", "Group", "Type", "ExecStart", "ActiveState", "MainPID", "DropInPaths"}
    if (not required.issubset(result) or result.get("LoadState") != "loaded" or result.get("User", "") not in ("", "root")
            or result.get("Group", "") not in ("", "root")
            or result.get("Type") not in ("forking", "simple", "exec", "notify")
            or not re.fullmatch(r"0|[1-9][0-9]*", result["MainPID"])):
        raise GateEnrollmentError("A loaded root-owned XRDP service with supported startup semantics is required.")
    return result


def has_startup_override(content):
    section = ""
    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line
        elif section == "[Service]" and not line.startswith(("#", ";")):
            key, separator, _value = line.partition("=")
            if separator and key.strip() == "ExecStart":
                return True
    return False


def check_dropin_precedence(properties, managed_path):
    for value in shlex.split(properties["DropInPaths"]):
        path = Path(value)
        if not path.is_absolute() or path.suffix != ".conf":
            raise GateEnrollmentError("The effective XRDP drop-in inventory is not a valid absolute path list.")
        if path.name == DROPIN_NAME and path != managed_path:
            raise GateEnrollmentError("Another unit/type-wide drop-in collides with the broker freezer filename.")
        if path.name <= DROPIN_NAME:
            continue
        protected_directory(path.parent)
        protected_file(path)
        if has_startup_override(path.read_text(encoding="utf-8")):
            raise GateEnrollmentError(
                "A later-ordered XRDP drop-in overrides ExecStart. Reconcile that override before enrollment; "
                "the installer will not stop services or overwrite it.")


def desired_dropin(unit, command):
    return HEADER + "[Service]\nExecStart=\nExecStart={} run-xrdp {} {}\n".format(WRAPPER, unit, command)


class GateInstaller:
    def __init__(self, manager, parse_mounts, directory=UNIT_DIRECTORY, core_error=GateEnrollmentError):
        self.manager = manager
        self.parse_mounts = parse_mounts
        self.directory = directory
        self.core_error = core_error

    def plan(self):
        result = []
        for unit in UNITS:
            properties = unit_properties(self.manager.command(
                "systemctl", "show", unit, "--property=LoadState", "--property=User",
                "--property=Group", "--property=Type", "--property=ExecStart", "--property=ActiveState",
                "--property=MainPID", "--property=DropInPaths", "--no-pager",
            ).stdout)
            content = self.manager.command("systemctl", "cat", unit, "--no-pager").stdout
            command, executable = startup_command(unit, content)
            protected_file(Path(executable))
            path = self.directory / (unit + ".d") / DROPIN_NAME
            protected_directory(path.parent)
            check_dropin_precedence(properties, path)
            desired = desired_dropin(unit, command)
            if path.exists() or path.is_symlink():
                protected_file(path)
                if path.read_text(encoding="utf-8") != desired:
                    raise GateEnrollmentError("An existing freezer drop-in conflicts with the reviewed startup command.")
            wrapped = ("path=" + WRAPPER) in properties.get("ExecStart", "") and (
                "argv[]={} run-xrdp {} ".format(WRAPPER, unit)) in properties.get("ExecStart", "")
            result.append(UnitPlan(unit, path, desired, wrapped, properties["ActiveState"], properties["MainPID"]))
        return result

    def verify_effective_wrappers(self, expected):
        current = self.plan()
        if any(not plan.wrapped or plan.content != original.content
               for plan, original in zip(current, expected)):
            raise GateEnrollmentError(
                "Reloaded XRDP ExecStart does not match the reviewed broker wrapper. No service stop/start is permitted.")

    def missing_initial_hierarchy(self, freezer, error, plans, allow_drained):
        if (not allow_drained or any(plan.active_state not in ("inactive", "failed") or plan.main_pid != "0" for plan in plans)
                or error.filename is None or Path(error.filename) != freezer.base
                or os.path.lexists(str(freezer.base))):
            return False
        # A vanished controller or unsafe parent is not the first-start missing-directory case.
        protected_directory(freezer.controller)
        freezer._protected(freezer.controller, directory=True)
        return True

    def verify_idle_evidence(self, evidence):
        if not isinstance(evidence, dict) or evidence.get("kind") not in ("absent", "cleaned"):
            raise GateEnrollmentError("Legacy enrollment requires trusted SQL-idle evidence or a brand-new host.")
        marker = self.manager.read()
        if list((self.manager.paths.state / "leases").glob("*.lease")):
            raise GateEnrollmentError("A legacy lease marker prevents a drained-host service restart.")
        if evidence["kind"] == "absent":
            if marker is not None:
                raise GateEnrollmentError("An unexpected marker appeared before legacy enrollment.")
        else:
            if (not marker or marker.get("phase") != "cleaned" or marker.get("operationId") is None
                    or marker.get("gateClosed", False) or marker.get("gateRestartRequired", False)
                    or marker.get("gateTerminated", False)
                    or marker.get("username") != evidence.get("username") or marker.get("uid") != evidence.get("uid")
                    or type(evidence.get("fence")) is not int or not 1 <= evidence["fence"] <= 9007199254740991
                    or marker.get("leaseGeneration", 0) > evidence["fence"]
                    or hashlib.sha256(self.manager.marker.read_bytes()).hexdigest() != evidence.get("sha256")):
                raise GateEnrollmentError("The cleaned lease/fence changed or requires guarded recovery; no service restart is allowed.")

    def verify_drained(self, admin_username):
        if self.manager.command("loginctl", "list-sessions", "--no-legend", "--no-pager").stdout.strip():
            raise GateEnrollmentError("Legacy first enrollment requires a drained host with no logind sessions.")
        for process in ("Xorg", "Xvnc", "Xwayland"):
            if self.manager.command("pgrep", "-x", process, allowed=(0, 1)).returncode != 1:
                raise GateEnrollmentError("An existing desktop process prevents legacy first enrollment.")
        for line in self.manager.command("getent", "passwd").stdout.splitlines():
            fields = line.split(":")
            if len(fields) != 7 or not fields[2].isdigit():
                raise GateEnrollmentError("Local account inventory cannot be verified before enrollment.")
            uid = int(fields[2])
            if uid >= 1000 and uid not in (65534, 65535) and fields[0] != admin_username:
                raise GateEnrollmentError("A residual workspace account prevents a drained-host service restart.")
        for line in self.manager.command("ss", "-Htn", "state", "established").stdout.splitlines():
            fields = line.split()
            if len(fields) < 4:
                raise GateEnrollmentError("Socket inventory is incomplete before legacy enrollment.")
            if any(value.rsplit(":", 1)[-1] in ("3389", "3350") for value in fields):
                raise GateEnrollmentError("An active XRDP connection prevents legacy first enrollment.")
        mounts = self.manager.paths.mountinfo.read_bytes()
        # Use the core parser, supplied by the module rather than utility-specific output.
        for mount in self.parse_mounts(mounts):
            if mount["target"].startswith(str(self.manager.paths.homes).rstrip("/") + "/"):
                raise GateEnrollmentError("A mounted home prevents legacy first enrollment.")

    def write_dropin(self, path, content):
        protected_directory(path.parent)
        directory_existed = path.parent.exists()
        path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        if not directory_existed:
            path.parent.chmod(0o755)
        if path.exists():
            return
        descriptor, name = tempfile.mkstemp(prefix=".broker-freezer-", dir=str(path.parent))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(name, 0o644)
            os.chown(name, 0, 0)
            os.replace(name, str(path))
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def enroll(self, allow_drained, evidence, admin_username):
        freezer = self.manager.legacy_freezer()
        if freezer is None:
            self.manager.gate_status()
            return "systemd-v2"
        plans = self.plan()
        if all(plan.wrapped for plan in plans):
            try:
                freezer.check(require_thawed=True)
                return "freezer-v1"
            except FileNotFoundError as error:
                if not self.missing_initial_hierarchy(freezer, error, plans, allow_drained):
                    raise
            except self.core_error as error:
                raise GateEnrollmentError(
                    "Existing wrapped XRDP services failed gate verification; use guarded recovery, not live reenrollment.") from error
        if not allow_drained:
            raise GateEnrollmentError(
                "Legacy XRDP services need startup enrollment. Drain the host, close admission, "
                "and explicitly allow drained legacy enrollment; existing sessions are never adopted or forced off.")
        with self.manager.locked():
            self.verify_idle_evidence(evidence)
            self.verify_drained(admin_username)
            for root in (freezer.base, freezer.services, freezer.quarantine):
                if root.exists() or root.is_symlink():
                    if freezer._members(root) or freezer._read(root / "freezer.state") != "THAWED":
                        raise GateEnrollmentError("Existing freezer members/state require guarded recovery, not reenrollment.")
            for plan in plans:
                self.write_dropin(plan.path, plan.content)
            self.manager.command("systemctl", "daemon-reload")
            self.verify_effective_wrappers(plans)
            self.verify_idle_evidence(evidence)
            self.verify_drained(admin_username)
            # Reload/readback precedes any service stop. Admission must remain closed.
            self.manager.command("systemctl", "stop", *UNITS)
            self.verify_idle_evidence(evidence)
            self.verify_drained(admin_username)
            self.verify_effective_wrappers(plans)
            self.manager.command("systemctl", "start", "xrdp-sesman.service", "xrdp.service")
            freezer.wait_ready()
        return "freezer-v1"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--enroll-drained", action="store_true")
    parser.add_argument("--idle-evidence-base64")
    parser.add_argument("--admin-username", default="avdadmin")
    args = parser.parse_args()
    try:
        if os.geteuid() != 0 or sys.version_info < (3, 9):
            raise GateEnrollmentError("Gate enrollment requires trusted deployment root and the selected Python 3.9+ runtime.")
        if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", args.admin_username):
            raise GateEnrollmentError("Invalid broker administrator account.")
        spec = importlib.util.spec_from_file_location("broker_gate_core", "/usr/local/bin/broker-lease.py")
        core = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = core
        spec.loader.exec_module(core)
        manager = core.LeaseManager()
        evidence = json.loads(base64.b64decode(args.idle_evidence_base64, validate=True)) if args.idle_evidence_base64 else {"kind": "absent"}
        try:
            backend = GateInstaller(manager, core.parse_mountinfo, core_error=core.LeaseError).enroll(
                args.enroll_drained, evidence, args.admin_username)
        except core.LeaseError as error:
            raise GateEnrollmentError(str(error))
        print("Verified broker XRDP gate: " + backend)
        return 0
    except GateEnrollmentError as error:
        print(str(error), file=sys.stderr)
    except (OSError, ValueError, TypeError, AttributeError):
        print("Legacy XRDP gate enrollment could not be verified. No marker/fence reset or fallback was attempted.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
