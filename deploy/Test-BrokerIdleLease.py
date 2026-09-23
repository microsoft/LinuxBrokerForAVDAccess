"""Read-only idle tombstone inspection and SQL-evidence verification for deployment."""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import uuid


STATE = Path("/var/lib/linuxbroker-release-session")
MAX_GENERATION = 9007199254740991


class IdleLeaseError(Exception):
    pass


def identifier(value):
    try:
        parsed = uuid.UUID(value)
    except (ValueError, TypeError, AttributeError):
        raise IdleLeaseError("The idle marker has an invalid identifier.")
    if not parsed.int or str(parsed) != value.lower():
        raise IdleLeaseError("The idle marker has an invalid identifier.")


def validate_tombstone(marker):
    if not isinstance(marker, dict) or marker.get("phase") != "cleaned":
        raise IdleLeaseError("An idle SQL host can retain only a cleaned fencing tombstone.")
    if (marker.get("gateClosed", False) is not False or marker.get("gateRestartRequired", False) is not False
            or marker.get("gateTerminated", False) is not False or type(marker.get("hadSession")) is not bool
            or marker.get("gateBackend") not in (None, "systemd-v2", "freezer-v1")):
        raise IdleLeaseError("The idle tombstone has an unresolved gate or invalid session state.")
    if not isinstance(marker.get("username"), str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,31}", marker["username"]):
        raise IdleLeaseError("The idle tombstone has an invalid mapped username.")
    if (type(marker.get("uid")) is not int or not 2000 <= marker["uid"] <= 2147483646
            or marker["uid"] in (65534, 65535)):
        raise IdleLeaseError("The idle tombstone has an invalid UID.")
    if type(marker.get("leaseGeneration")) is not int or not 1 <= marker["leaseGeneration"] <= MAX_GENERATION:
        raise IdleLeaseError("The idle tombstone has an invalid generation.")
    identifier(marker.get("leaseId"))
    identifier(marker.get("operationId"))
    if marker.get("gateBootId") is not None:
        identifier(marker["gateBootId"])
    return marker


def protected_state(state, owner_uid):
    if not state.exists() and not state.is_symlink():
        return
    info = state.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner_uid or info.st_mode & 0o022:
        raise IdleLeaseError("The broker state directory is not root-controlled.")
    legacy = state / "leases"
    if legacy.is_symlink() or (legacy.exists() and not legacy.is_dir()):
        raise IdleLeaseError("The legacy lease directory is not trustworthy.")
    if legacy.exists():
        info = legacy.lstat()
        if info.st_uid != owner_uid or info.st_mode & 0o022:
            raise IdleLeaseError("The legacy lease directory is not root-controlled.")
    if list(legacy.glob("*.lease")):
        raise IdleLeaseError("An idle SQL host still has a legacy lease marker.")


def inspect_marker(state=STATE, owner_uid=0):
    protected_state(state, owner_uid)
    path = state / "lease.json"
    if not path.exists() and not path.is_symlink():
        return {"kind": "absent"}
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_uid != owner_uid or stat.S_IMODE(before.st_mode) != 0o600:
        raise IdleLeaseError("The structured idle marker must be root-owned, regular, nonlinked, and mode 0600.")
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner_uid or stat.S_IMODE(info.st_mode) != 0o600:
            raise IdleLeaseError("The structured idle marker must be root-owned, regular, nonlinked, and mode 0600.")
        content = stream.read(65537)
    if len(content) > 65536:
        raise IdleLeaseError("The structured idle marker exceeds its size limit.")
    try:
        marker = validate_tombstone(json.loads(content))
    except (ValueError, UnicodeError):
        raise IdleLeaseError("The structured idle marker is malformed.")
    # Only the candidate mapping/fence and a fingerprint leave the guest; never the full marker/lease ID.
    return {
        "kind": "cleaned", "username": marker["username"], "uid": marker["uid"],
        "generation": marker["leaseGeneration"], "sha256": hashlib.sha256(content).hexdigest(),
    }


def verify_idle(expected, manager):
    with manager.locked():
        protected_state(manager.paths.state, manager.owner_uid)
        marker = manager.read()
        if marker is not None and stat.S_IMODE(manager.marker.lstat().st_mode) != 0o600:
            raise IdleLeaseError("The structured idle marker must retain mode 0600.")
        if expected.get("kind") == "absent":
            if marker is not None:
                raise IdleLeaseError("A marker appeared after trusted SQL idle-state validation.")
            return
        if expected.get("kind") != "cleaned":
            raise IdleLeaseError("Trusted SQL evidence for the idle marker is missing.")
        validate_tombstone(marker)
        if (marker["username"] != expected.get("username") or marker["uid"] != expected.get("uid")
                or type(expected.get("fence")) is not int or not 0 <= expected["fence"] <= MAX_GENERATION
                or marker["leaseGeneration"] > expected["fence"]):
            raise IdleLeaseError("The idle tombstone does not match retained SQL identity/fence evidence.")
        digest = hashlib.sha256(manager.marker.read_bytes()).hexdigest()
        if digest != expected.get("sha256"):
            raise IdleLeaseError("The idle marker changed after trusted SQL verification.")
        if manager.account(marker["username"]) is not None:
            raise IdleLeaseError("A cleaned tombstone still has a local account.")
        if manager.command("getent", "passwd", str(marker["uid"]), allowed=(0, 2)).returncode != 2:
            raise IdleLeaseError("The tombstone's UID still belongs to a local account.")
        if manager.mount_info(manager.paths.homes / marker["username"], require_leaf=True) is not None:
            raise IdleLeaseError("A cleaned tombstone still has a mounted local home.")
        # No write/unlink occurs: the cleaned marker is the durable fence for future operations.


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--inspect", action="store_true")
    actions.add_argument("--verify-base64")
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise IdleLeaseError("Idle lease inspection requires the trusted deployment root context.")
        if args.inspect:
            print("BROKER_IDLE_METADATA=" + json.dumps(inspect_marker(), sort_keys=True, separators=(",", ":")))
        else:
            expected = json.loads(base64.b64decode(args.verify_base64, validate=True).decode("utf-8"))
            spec = importlib.util.spec_from_file_location("broker_idle_core", "/usr/local/bin/broker-lease.py")
            core = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = core
            spec.loader.exec_module(core)
            try:
                verify_idle(expected, core.LeaseManager())
            except core.LeaseError:
                raise IdleLeaseError("The installed helper could not verify the protected idle host state.")
            print("BROKER_IDLE_LEASE_VERIFIED")
        return 0
    except IdleLeaseError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, AttributeError):
        print("Idle lease state could not be verified; no marker contents were logged or changed.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
