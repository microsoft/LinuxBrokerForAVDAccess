#!/usr/local/libexec/linuxbroker/python3 -I
"""Root-owned host half of a generation-fenced broker operation; never stores credentials."""

import sys

if sys.version_info < (3, 9):
    print("The broker requires the deployment-pinned Python 3.9+ runtime.", file=sys.stderr)
    raise SystemExit(1)

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import signal
import shutil
import stat
import subprocess
import tempfile
import time
import uuid


MAX_LEASE_GENERATION = 9007199254740991


class LeaseError(Exception):
    pass


class NoLease(LeaseError):
    pass


@dataclass(frozen=True)
class Paths:
    state: Path = Path("/var/lib/linuxbroker-release-session")
    homes: Path = Path("/home")
    profiles: Path = Path("/awipsprofiles")
    skel: Path = Path("/etc/skel")
    mountinfo: Path = Path("/proc/self/mountinfo")
    proc: Path = Path("/proc")


def _mount_field(value):
    # Decode the kernel's four path escapes once, not Python/unicode escapes.
    escapes = {b"040": b" ", b"011": b"\t", b"012": b"\n", b"134": b"\\"}
    if not value or b"\0" in value or re.search(br"\\(?!040|011|012|134)", value):
        raise LeaseError("Kernel mount state contains an invalid field.")
    decoded = re.sub(br"\\(040|011|012|134)", lambda match: escapes[match[1]], value)
    return os.fsdecode(decoded)


def parse_mountinfo(document):
    """Read the stable Linux mountinfo ABI (2.6.26+), independent of util-linux."""
    if not document or not document.endswith(b"\n") or b"\0" in document or b"\t" in document:
        raise LeaseError("Kernel mount state is empty or incomplete.")
    mounts, identifiers = [], set()
    for line in document.split(b"\n")[:-1]:
        fields = line.split(b" ")
        try:
            separator = fields.index(b"-", 6)
        except ValueError as exc:
            raise LeaseError("Kernel mount state is malformed.") from exc
        if (separator + 4 != len(fields) or any(not field for field in fields)
                or not re.fullmatch(br"[1-9][0-9]*", fields[0])
                or not re.fullmatch(br"[0-9]+", fields[1])
                or not re.fullmatch(br"[0-9]+:[0-9]+", fields[2])
                or not re.fullmatch(br"[A-Za-z0-9_.-]+", fields[separator + 1])):
            raise LeaseError("Kernel mount state is malformed.")
        mount_id = int(fields[0])
        if mount_id in identifiers:
            raise LeaseError("Kernel mount state contains duplicate mount identifiers.")
        identifiers.add(mount_id)
        root, target = _mount_field(fields[3]), _mount_field(fields[4])
        if not root.startswith("/") or not target.startswith("/"):
            raise LeaseError("Kernel mount paths must be absolute.")
        major, minor = (int(part) for part in fields[2].split(b":"))
        mounts.append({
            "id": mount_id, "parent": int(fields[1]), "major": major, "minor": minor,
            "fsroot": root, "target": target, "fstype": os.fsdecode(fields[separator + 1]),
            "source": _mount_field(fields[separator + 2]),
            "super_options": tuple(os.fsdecode(fields[separator + 3]).split(",")),
        })
    return mounts


def identity(username, uid, lease_id, generation):
    reserved = {
        "root", "avdadmin", "nobody", "daemon", "bin", "sys", "sync", "games", "man", "lp",
        "mail", "news", "uucp", "proxy", "www-data", "backup", "list", "irc", "sshd",
        "postgres", "messagebus", "polkitd",
    }
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,31}", username) or username.lower() in reserved:
        raise LeaseError("Invalid or reserved username.")
    if type(uid) is not int or not 2000 <= uid <= 2147483646 or uid in (65534, 65535):
        raise LeaseError("Invalid broker UID.")
    if type(generation) is not int or not 1 <= generation <= MAX_LEASE_GENERATION:
        raise LeaseError("Invalid lease generation.")
    return {
        "username": username, "uid": uid, "leaseId": identifier(lease_id),
        "leaseGeneration": generation,
    }


def identifier(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError) as exc:
        raise LeaseError("Invalid operation or lease identifier.") from exc
    if not parsed.int or str(parsed) != value.lower():
        raise LeaseError("Invalid operation or lease identifier.")
    return str(parsed)


class LeaseManager:
    def __init__(self, paths=Paths(), runner=subprocess.run, owner_uid=0):
        self.paths = paths
        self.runner = runner
        self.owner_uid = owner_uid
        self.marker = paths.state / "lease.json"

    def command(self, *args, input=None, allowed=(0,)):
        try:
            result = self.runner(list(args), input=input, text=True, capture_output=True, timeout=30)
        except (subprocess.SubprocessError, OSError) as exc:
            raise LeaseError(f"Host command did not complete: {args[0]}.") from exc
        if result.returncode not in allowed:
            # stderr, stdout and stdin can contain secrets (notably chpasswd diagnostics).
            raise LeaseError(f"Host command failed: {args[0]} (exit {result.returncode}).")
        return result

    @contextmanager
    def locked(self):
        self.paths.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.paths.state.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != self.owner_uid or info.st_mode & 0o022:
            raise LeaseError("The broker state directory is not protected.")
        descriptor = os.open(self.paths.state / "lease.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(descriptor).st_uid != self.owner_uid:
                raise LeaseError("The broker lock is not protected.")
            deadline = time.monotonic() + 60
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise LeaseError("A host lease operation is still in progress.")
                    time.sleep(0.1)
            yield
        finally:
            os.close(descriptor)

    def read(self):
        if not self.marker.exists() and not self.marker.is_symlink():
            return None
        info = self.marker.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != self.owner_uid or info.st_mode & 0o077:
            raise LeaseError("The lease marker is not protected.")
        try:
            marker = json.loads(self.marker.read_text(encoding="utf-8"))
            expected = identity(marker["username"], marker["uid"], marker["leaseId"], marker["leaseGeneration"])
            if any(marker[key] != value for key, value in expected.items()):
                raise LeaseError("Invalid lease marker.")
            if marker["phase"] not in ("ready", "provisioning", "cleanup", "cleaned") or type(marker["hadSession"]) is not bool:
                raise LeaseError("Invalid lease marker.")
            if type(marker.get("gateClosed", False)) is not bool:
                raise LeaseError("Invalid XRDP gate marker.")
            if type(marker.get("gateRestartRequired", False)) is not bool:
                raise LeaseError("Invalid XRDP restart marker.")
            if type(marker.get("gateTerminated", False)) is not bool:
                raise LeaseError("Invalid XRDP termination marker.")
            if marker.get("gateBackend") not in (None, "systemd-v2", "freezer-v1"):
                raise LeaseError("Invalid XRDP gate backend.")
            if marker.get("gateBootId") is not None:
                identifier(marker["gateBootId"])
            if (marker.get("gateTerminated", False) and not marker.get("gateRestartRequired", False)
                    or marker.get("gateRestartRequired", False) and not marker.get("gateClosed", False)):
                raise LeaseError("The XRDP recovery marker is inconsistent.")
            if marker.get("operationId") is not None:
                identifier(marker["operationId"])
        except (ValueError, KeyError, TypeError) as exc:
            raise LeaseError("Invalid lease marker.") from exc
        return marker

    def write(self, marker):
        descriptor, filename = tempfile.mkstemp(prefix=".lease-", dir=self.paths.state)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(marker, stream, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(filename, self.marker)
            directory = os.open(self.paths.state, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(filename):
                os.unlink(filename)

    def account(self, username):
        result = self.command("getent", "passwd", username, allowed=(0, 2))
        if result.returncode == 2:
            return None
        fields = result.stdout.strip().split(":")
        if len(fields) != 7 or fields[0] != username or not fields[2].isdigit() or not fields[3].isdigit():
            raise LeaseError("The local account could not be verified.")
        return {"uid": int(fields[2]), "gid": int(fields[3]), "home": fields[5]}

    def verify_account(self, data, required=False):
        account = self.account(data["username"])
        if account is None:
            if required:
                raise LeaseError("The expected local account is missing.")
        elif account["uid"] != data["uid"] or account["home"] != str(self.paths.homes / data["username"]):
            raise LeaseError("The local account does not match the immutable mapping.")
        return account

    def mount_info(self, path, require_leaf=False):
        if not path.is_absolute():
            raise LeaseError("Mount inspection requires an absolute path.")
        try:
            mounts = parse_mountinfo(self.paths.mountinfo.read_bytes())
        except OSError as exc:
            raise LeaseError("Kernel mount state could not be read.") from exc
        target = str(path)
        ancestors = {}
        for mount in mounts:
            candidate = mount["target"]
            if candidate == target or target.startswith(candidate.rstrip("/") + "/"):
                ancestors[candidate] = ancestors.get(candidate, 0) + 1
            if require_leaf and candidate.startswith(target.rstrip("/") + "/"):
                raise LeaseError("The home contains another mount; cleanup requires reconciliation.")
        if any(count > 1 for count in ancestors.values()):
            raise LeaseError("Stacked mounts make the target ambiguous.")
        matching = [mount for mount in mounts if mount["target"] == target]
        if not matching:
            return None
        mount = matching[0]
        try:
            device = path.stat().st_dev
        except OSError as exc:
            raise LeaseError("The mounted path could not be verified.") from exc
        if (os.major(device), os.minor(device)) != (mount["major"], mount["minor"]):
            raise LeaseError("The visible filesystem does not match the mount record.")
        return {key: mount[key] for key in ("target", "source", "fstype", "fsroot")}

    def verify_home_mount(self, data):
        home = self.paths.homes / data["username"]
        if home.is_symlink():
            raise LeaseError("A home path must not be a symlink.")
        mount = self.mount_info(home, require_leaf=True)
        if mount is not None and (
            mount.get("fstype") not in ("nfs", "nfs4")
            or Path(mount.get("fsroot", "")).name != data["username"]
            or home.stat().st_uid != data["uid"]
        ):
            raise LeaseError("The home mount does not match the persistent profile.")
        return mount

    def reserve(self, data, operation, phase):
        current = self.read()
        if current:
            same = all(current[key] == data[key] for key in ("username", "uid", "leaseId"))
            if data["leaseGeneration"] < current["leaseGeneration"]:
                raise LeaseError("Stale lease generation.")
            if data["leaseGeneration"] == current["leaseGeneration"]:
                if not same or current.get("operationId") != operation:
                    raise LeaseError("The operation does not match the marker.")
                if phase == "provisioning" and current["phase"] == "ready":
                    raise LeaseError("Credential rotation requires a new reserved generation.")
            elif not same and not (current["phase"] == "cleaned" and phase == "provisioning"):
                raise LeaseError("A different lease still owns the host.")
            if phase == "cleanup" and not same:
                raise LeaseError("Cleanup does not match the lease marker.")
            if phase == "provisioning" and same and current["phase"] in ("cleanup", "cleaned"):
                raise LeaseError("A reclaiming lease cannot be reprovisioned.")
            if phase == "provisioning" and current.get("gateClosed", False):
                raise LeaseError("The XRDP cleanup gate requires recovery first.")
        else:
            if phase != "provisioning" or list((self.paths.state / "leases").glob("*.lease")):
                raise LeaseError("A verified lease marker is required; migrate legacy assignments first.")
            if self.account(data["username"]) is not None:
                raise LeaseError("An unmarked account cannot be claimed.")
        marker = {
            **data, "operationId": operation, "phase": phase,
            "hadSession": current["hadSession"] if current and current["leaseId"] == data["leaseId"] else False,
            "gateClosed": current.get("gateClosed", False) if current else False,
            "gateBackend": current.get("gateBackend") if current else None,
            "gateRestartRequired": current.get("gateRestartRequired", False) if current else False,
            "gateTerminated": current.get("gateTerminated", False) if current else False,
            "gateBootId": current.get("gateBootId") if current else None,
        }
        if current and current["phase"] == "cleaned" and phase == "cleanup":
            marker["phase"] = "cleaned"
        self.write(marker)
        return marker

    def migrate(self, data):
        with self.locked():
            self.gate_status()
            self.verify_account(data, required=True)
            if self.verify_home_mount(data) is None:
                raise LeaseError("An active legacy lease must have its verified NFS home mounted.")
            current = self.read()
            if current and (any(current[key] != value for key, value in data.items())
                            or current["phase"] != "ready" or current.get("gateClosed", False)
                            or current.get("gateRestartRequired", False)):
                raise LeaseError("The existing marker conflicts with the approved migration.")
            legacy = self.paths.state / "leases" / (data["username"] + ".lease")
            for path in (self.paths.state / "leases").glob("*.lease"):
                if path != legacy or path.is_symlink() or identifier(path.read_text().strip()) != data["leaseId"]:
                    raise LeaseError("A legacy marker conflicts with the approved migration.")
            marker = current or {
                **data, "operationId": None, "phase": "ready", "hadSession": bool(self.sessions(data)),
            }
            self.write(marker)
            if legacy.exists():
                legacy.unlink()
            return {"outcome": "migrated", **data}

    def provision(self, data, operation, nfs_share, password):
        if not nfs_share or ":/" not in nfs_share or re.search(r"\s", nfs_share) or nfs_share.startswith("-"):
            raise LeaseError("A configured NFS export is required.")
        if not 16 <= len(password) <= 256 or any(char in password for char in "\r\n:\0"):
            raise LeaseError("Invalid credential input.")
        with self.locked():
            self.gate_status()
            marker = self.reserve(data, operation, "provisioning")
            account = self.verify_account(data)
            group_arguments = ["-U"]
            if account is None:
                group = self.command("getent", "group", data["username"], allowed=(0, 2))
                if group.returncode == 0:
                    fields = group.stdout.strip().split(":")
                    if (len(fields) != 4 or fields[0] != data["username"] or fields[2] != str(data["uid"])
                            or fields[3] not in ("", data["username"])):
                        raise LeaseError("An existing local group conflicts with the mapping.")
                    # useradd may have created its private group before an interrupted account write.
                    group_arguments = ["-g", data["username"]]
            root = self.paths.profiles
            if root.is_symlink():
                raise LeaseError("The NFS mount root must not be a symlink.")
            root.mkdir(mode=0o755, parents=True, exist_ok=True)
            mounted = self.mount_info(root)
            if mounted is None:
                self.command("mount", "-t", "nfs", "-o", "vers=4,minorversion=1,sec=sys,nconnect=4", "--", nfs_share, str(root))
                mounted = self.mount_info(root)
            if not mounted or mounted.get("fstype") not in ("nfs", "nfs4") or mounted.get("source") != nfs_share:
                raise LeaseError("The NFS export could not be verified.")
            home = self.paths.homes / data["username"]
            profile = root / data["username"]
            if profile.is_symlink() or home.is_symlink():
                raise LeaseError("Profile and home paths must not be symlinks.")
            if account is None:
                self.command("useradd", "-d", str(home), "-u", str(data["uid"]), *group_arguments,
                             "-M", "-s", "/bin/bash", "--", data["username"])
                account = self.verify_account(data, required=True)
            if not profile.exists():
                staging = Path(tempfile.mkdtemp(prefix=f".{data['username']}-", dir=root))
                shutil.copytree(self.paths.skel, staging, symlinks=True, dirs_exist_ok=True)
                for directory, dirs, files in os.walk(staging, followlinks=False):
                    for path in [Path(directory), *(Path(directory) / name for name in dirs + files)]:
                        os.chown(path, data["uid"], account["gid"], follow_symlinks=False)
                # An interrupted skeleton copy never publishes a half-owned profile.
                staging.rename(profile)
            if not profile.is_dir() or profile.stat().st_uid != data["uid"]:
                raise LeaseError("The existing profile ownership does not match the mapping.")
            home.mkdir(mode=0o700, parents=True, exist_ok=True)
            mounted_home = self.mount_info(home)
            if mounted_home is None:
                if any(home.iterdir()):
                    raise LeaseError("The local home mount point is not empty.")
                self.command("mount", "--bind", "--", str(profile), str(home))
            if self.verify_home_mount(data) is None or not os.path.samestat(profile.stat(), home.stat()):
                raise LeaseError("The local home is not the expected persistent profile.")
            for group in ("tsusers", "appusers"):
                self.command("groupadd", "--force", group)
            self.command("usermod", "-a", "-G", "tsusers,appusers", "--", data["username"])
            self.command("chpasswd", input=f'{data["username"]}:{password}\n')
            marker["phase"] = "ready"
            self.write(marker)
            return self.ack(marker, "ready")

    def sessions(self, data):
        processes = self.command("ps", "-eo", "pid=,uid=,comm=,args=").stdout
        sockets = self.command("ss", "-xnp").stdout
        sessions = []
        for line in processes.splitlines():
            fields = line.split(None, 3)
            if len(fields) != 4 or fields[2] != "Xorg" or "xrdp" not in fields[3]:
                continue
            if not fields[0].isdigit() or not fields[1].isdigit():
                raise LeaseError("XRDP process state could not be verified.")
            if int(fields[1]) == 0:
                raise LeaseError("A root-owned XRDP session cannot be safely attributed.")
            if int(fields[1]) != data["uid"]:
                continue
            display = re.search(r"(?:^|\s):([0-9]+)(?:\s|$)", fields[3])
            if display is None:
                raise LeaseError("XRDP display state could not be verified.")
            active = any(
                re.search(rf"xrdp_display_{display[1]}(?:\D|$)", socket)
                and re.search(rf"pid={fields[0]}(?:\D|$)", socket)
                for socket in sockets.splitlines()
            )
            sessions.append({"pid": int(fields[0]), "display": display[1], "state": "active" if active else "disconnected"})
        return sessions

    def disconnect_idle(self, data, xorg_pid):
        with self.locked():
            marker = self.read()
            if not marker or marker["phase"] != "ready" or any(marker[key] != value for key, value in data.items()):
                raise LeaseError("The idle observation is stale.")
            self.verify_account(data, required=True)
            legacy = self.legacy_freezer()
            if legacy is not None:
                with self.session_gate(marker):
                    session = next((item for item in self.sessions(data)
                                    if item["pid"] == xorg_pid and item["state"] == "active"), None)
                    if session is None:
                        raise LeaseError("The idle session is no longer active.")
                    sockets = self.command("ss", "-xnp").stdout
                    pids = set()
                    for line in sockets.splitlines():
                        if re.search(rf"xrdp_display_{session['display']}(?:\D|$)", line):
                            pids.update(int(value) for value in re.findall(r"pid=([0-9]+)", line))
                    for pid in pids - {xorg_pid}:
                        self._session_freezer.disconnect_connection(pid)
                    if not pids - {xorg_pid}:
                        raise LeaseError("No matching XRDP connection could be disconnected.")
                return self.ack(marker, "disconnected")
            session = next((item for item in self.sessions(data) if item["pid"] == xorg_pid and item["state"] == "active"), None)
            if session is None:
                raise LeaseError("The idle session is no longer active.")
            sockets = self.command("ss", "-xnp").stdout
            pids = set()
            for line in sockets.splitlines():
                if re.search(rf"xrdp_display_{session['display']}(?:\D|$)", line):
                    pids.update(int(value) for value in re.findall(r"pid=([0-9]+)", line))
            signalled = False
            for pid in pids - {xorg_pid}:
                try:
                    descriptor = os.pidfd_open(pid)
                except ProcessLookupError:
                    continue
                try:
                    if self.command("ps", "-p", str(pid), "-o", "comm=", allowed=(0, 1)).stdout.strip() != "xrdp":
                        continue
                    signal.pidfd_send_signal(descriptor, signal.SIGTERM)
                    signalled = True
                finally:
                    os.close(descriptor)
            if not signalled:
                raise LeaseError("No matching XRDP connection could be disconnected.")
            return self.ack(marker, "disconnected")

    def observe(self):
        with self.locked():
            marker = self.read()
            if not marker:
                raise NoLease("No live lease.")
            if marker.get("gateClosed", False) or marker.get("gateRestartRequired", False):
                raise LeaseError("The XRDP gate requires guarded recovery.")
            if marker["phase"] == "cleaned":
                raise NoLease("No live lease.")
            if marker["phase"] != "ready" or marker.get("gateClosed", False):
                raise LeaseError("A host lease operation is in progress.")
            self.verify_account(marker, required=True)
            sessions = self.sessions(marker)
            active = next((session for session in sessions if session["state"] == "active"), None)
            state = "active" if active else "disconnected" if sessions or not marker["hadSession"] else "logged_off"
            if sessions and not marker["hadSession"]:
                marker["hadSession"] = True
                self.write(marker)
            return {
                **{key: marker[key] for key in ("username", "uid", "leaseId", "leaseGeneration")},
                "state": state, "xorgPid": active["pid"] if active else None,
            }

    def end_sessions(self, data):
        listing = self.command("loginctl", "list-sessions", "--no-legend", "--no-pager").stdout
        for line in listing.splitlines():
            fields = line.split()
            if len(fields) < 3 or fields[1] != str(data["uid"]):
                continue
            if fields[2] != data["username"] or not re.fullmatch(r"[A-Za-z0-9_-]+", fields[0]):
                raise LeaseError("Logind session ownership is uncertain.")
            actual_uid = self.command("loginctl", "show-session", fields[0], "-p", "User", "--no-pager").stdout.strip()
            if actual_uid != f'User={data["uid"]}':
                raise LeaseError("Logind session ownership changed.")
            self.command("loginctl", "terminate-session", fields[0])
        self.command("pkill", "-TERM", "-u", str(data["uid"]), allowed=(0, 1))
        for _ in range(20):
            if self.command("pgrep", "-u", str(data["uid"]), allowed=(0, 1)).returncode == 1:
                return
            time.sleep(0.1)
        self.command("pkill", "-KILL", "-u", str(data["uid"]), allowed=(0, 1))
        if self.command("pgrep", "-u", str(data["uid"]), allowed=(0, 1)).returncode != 1:
            raise LeaseError("Matching user processes have not ended.")

    def legacy_freezer(self):
        mounts = parse_mountinfo(self.paths.mountinfo.read_bytes())
        if not any(mount["fstype"] == "cgroup" and "freezer" in mount["super_options"] for mount in mounts):
            return None
        module = runpy.run_path(str(Path(__file__).with_name("broker-freezer.py")))
        return module["LegacyFreezer"](self, mounts, LeaseError)

    def gate_status(self):
        marker = self.read()
        if marker and (marker.get("gateClosed", False) or marker.get("gateRestartRequired", False)):
            raise LeaseError("A lease operation must recover the XRDP gate before activation.")
        freezer = self.legacy_freezer()
        if freezer is not None:
            freezer.check(require_thawed=True)
            return {"backend": "freezer-v1", "ready": True}
        for unit in ("xrdp.service", "xrdp-sesman.service"):
            if self.command("systemctl", "show", unit, "-p", "FreezerState", "--value").stdout.strip() != "running":
                raise LeaseError("The XRDP gate is unavailable or requires guarded recovery.")
        return {"backend": "systemd-v2", "ready": True}

    @contextmanager
    def session_gate(self, marker):
        units = ("xrdp.service", "xrdp-sesman.service")
        freezer = self.legacy_freezer()
        backend = "freezer-v1" if freezer is not None else "systemd-v2"
        boot_id = identifier((self.paths.proc / "sys/kernel/random/boot_id").read_text(encoding="ascii").strip())
        if marker.get("gateClosed") and marker.get("gateBackend") not in (None, backend):
            raise LeaseError("The interrupted XRDP gate backend requires explicit recovery.")
        if marker.get("gateClosed") and marker.get("gateBootId") not in (None, boot_id):
            # A verified new boot cannot retain the old frozen tasks or accepted
            # authentication state. Re-establish the gate and recheck this lease.
            if freezer is not None:
                freezer.check(require_thawed=True, cleanup_uid=marker["uid"])
            marker["gateClosed"] = False
            marker["gateRestartRequired"] = False
            marker["gateTerminated"] = False
            self.write(marker)
        if marker.get("gateRestartRequired", False):
            if freezer is None:
                raise LeaseError("The interrupted legacy XRDP restart requires its original backend.")
            if marker.get("gateTerminated", False):
                freezer.restart()
                marker["gateRestartRequired"] = False
                marker["gateTerminated"] = False
                marker["gateClosed"] = False
            else:
                freezer.recover_termination(marker["uid"])
                marker["gateTerminated"] = True
            self.write(marker)
        if freezer is not None and not marker.get("gateTerminated", False):
            freezer.check(require_thawed=not marker.get("gateClosed", False), cleanup_uid=marker["uid"])
        marker["gateBackend"] = backend
        marker["gateBootId"] = boot_id
        marker["gateClosed"] = True
        self.write(marker)
        self._session_freezer = freezer
        try:
            if freezer is not None:
                if not marker.get("gateTerminated", False):
                    freezer.freeze(marker["uid"])
            else:
                self.command("systemctl", "freeze", *units)
                for unit in units:
                    if self.command("systemctl", "show", unit, "-p", "FreezerState", "--value").stdout.strip() != "frozen":
                        raise LeaseError("The XRDP reconnect gate could not be verified.")
            yield
        finally:
            if freezer is not None:
                if marker.get("gateRestartRequired", False):
                    if not marker.get("gateTerminated", False):
                        raise LeaseError("Interrupted XRDP termination remains frozen for guarded recovery.")
                    freezer.restart()
                    marker["gateRestartRequired"] = False
                    marker["gateTerminated"] = False
                else:
                    freezer.thaw()
                freezer.check(require_thawed=True, cleanup_uid=marker["uid"])
            else:
                self.command("systemctl", "thaw", *units)
                for unit in units:
                    if self.command("systemctl", "show", unit, "-p", "FreezerState", "--value").stdout.strip() != "running":
                        raise LeaseError("XRDP could not be resumed after cleanup.")
            marker["gateClosed"] = False
            self.write(marker)
            self._session_freezer = None

    def cleanup_locked(self, data, marker, reason):
        account = self.verify_account(data)
        mounted = self.verify_home_mount(data)
        if marker["phase"] == "cleaned":
            if account or mounted:
                raise LeaseError("A cleaned lease has unexpected host state.")
            return "cleaned"
        if account:
            self.command("usermod", "--lock", "--", data["username"])
            sessions = self.sessions(data)
            active = any(session["state"] == "active" for session in sessions)
            if reason != "admin" and (active or (reason == "logged_off" and sessions)):
                self.command("usermod", "--unlock", "--", data["username"])
                marker["phase"], marker["hadSession"] = "ready", True
                return "active" if active else "disconnected"
        elif self.sessions(data):
            raise LeaseError("Sessions exist without their expected account.")
        if self._session_freezer is not None and not marker.get("gateTerminated", False):
            targets = self._session_freezer.termination_targets(data["uid"])
            marker["gateRestartRequired"] = True
            self.write(marker)
            self._session_freezer.terminate(targets)
            marker["gateTerminated"] = True
            self.write(marker)
        if account:
            self.end_sessions(data)
        home = self.paths.homes / data["username"]
        if mounted:
            self.command("umount", "--", str(home))
        if self.mount_info(home, require_leaf=True) is not None:
            raise LeaseError("The local home is still mounted.")
        if account:
            self.command("userdel", "--", data["username"])
        if self.account(data["username"]) is not None:
            raise LeaseError("The local account still exists.")
        if home.exists():
            # rmdir is deliberately nonrecursive and follows verified unmount.
            home.rmdir()
        marker["phase"] = "cleaned"
        return "cleaned"

    def cleanup(self, data, operation, reason):
        if reason not in ("admin", "expired", "logged_off"):
            raise LeaseError("Invalid cleanup reason.")
        with self.locked():
            marker = self.reserve(data, operation, "cleanup")
            self.verify_account(data)
            self.verify_home_mount(data)
            with self.session_gate(marker):
                outcome = self.cleanup_locked(data, marker, reason)
            return self.ack(marker, outcome)

    @staticmethod
    def ack(marker, outcome):
        return {
            "outcome": outcome,
            **{key: marker[key] for key in ("leaseId", "leaseGeneration", "operationId")},
        }


def main():
    if os.geteuid() != 0:
        print("Lease management requires root.", file=sys.stderr)
        return 1
    os.umask(0o077)
    os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("observe")
    commands.add_parser("gate-status")
    run = commands.add_parser("run-xrdp")
    run.add_argument("unit", choices=("xrdp.service", "xrdp-sesman.service"))
    run.add_argument("command", nargs=argparse.REMAINDER)
    for action in ("migrate", "provision", "cleanup", "disconnect-idle"):
        command = commands.add_parser(action)
        if action == "provision":
            command.add_argument("nfs_share")
            command.add_argument("uid", type=int)
            command.add_argument("username")
        else:
            command.add_argument("username")
            command.add_argument("uid", type=int)
        command.add_argument("lease_id")
        command.add_argument("generation", type=int)
        if action in ("provision", "cleanup"):
            command.add_argument("operation_id")
        if action == "cleanup":
            command.add_argument("reason", choices=("admin", "expired", "logged_off"))
        if action == "disconnect-idle":
            command.add_argument("xorg_pid", type=int)
    args = parser.parse_args()
    manager = LeaseManager()
    try:
        if args.action == "observe":
            result = manager.observe()
        elif args.action == "gate-status":
            result = manager.gate_status()
        elif args.action == "run-xrdp":
            freezer = manager.legacy_freezer()
            if freezer is None:
                raise LeaseError("The legacy startup wrapper requires a dedicated cgroup-v1 freezer.")
            freezer.run(args.unit, args.command)
            raise LeaseError("The XRDP executable did not start.")
        else:
            data = identity(args.username, args.uid, args.lease_id, args.generation)
            if args.action == "migrate":
                result = manager.migrate(data)
            elif args.action == "provision":
                result = manager.provision(data, identifier(args.operation_id), args.nfs_share, sys.stdin.read(258).removesuffix("\n"))
            elif args.action == "disconnect-idle":
                result = manager.disconnect_idle(data, args.xorg_pid)
            else:
                result = manager.cleanup(data, identifier(args.operation_id), args.reason)
        print(json.dumps(result, sort_keys=True))
        return 0
    except NoLease:
        return 3
    except (LeaseError, OSError) as exc:
        print(f"Lease operation incomplete: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
