#!/usr/bin/env python3
"""Install a hash-pinned, private broker runtime using stock Python 3.6 stdlib."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen


ROOT = Path("/usr/local/libexec/linuxbroker")
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_EXPANDED_BYTES = 1024 * 1024 * 1024


class RuntimeInstallError(Exception):
    pass


def validate_config(config):
    required = {"schemaVersion", "version", "build", "target", "minimumGlibc", "uri", "sha256"}
    if not isinstance(config, dict) or set(config) != required:
        raise RuntimeInstallError("The runtime lock has unknown or missing fields.")
    if type(config["schemaVersion"]) is not int or config["schemaVersion"] != 1:
        raise RuntimeInstallError("Unsupported runtime lock version.")
    if any(not isinstance(config[key], str) for key in required - {"schemaVersion"}):
        raise RuntimeInstallError("Runtime lock values must be explicit strings.")
    if not re.fullmatch(r"3\.(?:9|[1-9][0-9])\.[0-9]+", config["version"]):
        raise RuntimeInstallError("The broker requires an explicitly pinned Python 3.9+ release.")
    if not re.fullmatch(r"[0-9]{8}", config["build"]):
        raise RuntimeInstallError("Invalid runtime build identifier.")
    if config["target"] != "x86_64-unknown-linux-gnu" or config["minimumGlibc"] != "2.17":
        raise RuntimeInstallError("Use the baseline x86_64 GNU runtime compatible with glibc 2.17.")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", config["sha256"]):
        raise RuntimeInstallError("A pinned runtime SHA256 is required.")
    uri = urlparse(config["uri"])
    if uri.scheme != "https" or not uri.hostname or uri.username or uri.password or uri.query or uri.fragment:
        raise RuntimeInstallError("Runtime downloads require a nonsecret HTTPS URI.")
    return config


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def archive_members(archive):
    members = archive.getmembers()
    if len(members) > 20000:
        raise RuntimeInstallError("Runtime archive contains too many files.")
    seen = set()
    total = 0
    for member in members:
        path = PurePosixPath(member.name)
        if (not member.name or "\\" in member.name or path.is_absolute()
                or ".." in path.parts or not path.parts or path.parts[0] != "python"
                or any(ord(character) < 32 for character in member.name)):
            raise RuntimeInstallError("Unsafe path in runtime archive.")
        normalized = str(path)
        if normalized in seen:
            raise RuntimeInstallError("Duplicate path in runtime archive.")
        seen.add(normalized)
        if not (member.isfile() or member.isdir() or member.issym()):
            raise RuntimeInstallError("Unsupported runtime archive entry type.")
        if member.issym():
            target = PurePosixPath(member.linkname)
            resolved = posixpath.normpath(posixpath.join(str(path.parent), member.linkname))
            if (target.is_absolute() or "\\" in member.linkname
                    or not resolved.startswith("python/") or any(ord(c) < 32 for c in member.linkname)):
                raise RuntimeInstallError("Runtime archive link escapes its private directory.")
        if member.isfile():
            if member.size < 0:
                raise RuntimeInstallError("Invalid file length in runtime archive.")
            total += member.size
            if total > MAX_EXPANDED_BYTES:
                raise RuntimeInstallError("Runtime archive exceeds the expanded-size limit.")
    # Extract regular files first. No archive path may traverse a link created later.
    links = {str(PurePosixPath(member.name)) for member in members if member.issym()}
    for member in members:
        if any(str(parent) in links for parent in PurePosixPath(member.name).parents):
            raise RuntimeInstallError("A runtime archive path traverses another archive link.")
    return members


def extract_runtime(archive_path, destination):
    with tarfile.open(str(archive_path), "r:gz") as archive:
        members = archive_members(archive)
        for member in members:
            if member.issym():
                continue
            target = destination.joinpath(*PurePosixPath(member.name).parts)
            if member.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                with archive.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
        for member in members:
            if member.issym():
                target = destination.joinpath(*PurePosixPath(member.name).parts)
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                target.symlink_to(member.linkname)


def require_private_root(path):
    for current in [path] + list(path.parents):
        if not current.exists() and not current.is_symlink():
            continue
        info = current.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeInstallError("The private runtime directory must have root-controlled, nonlinked parents.")


def prepare_runtime_directory(path, parents=False):
    require_private_root(path)
    path.mkdir(mode=0o755, parents=parents, exist_ok=True)
    require_private_root(path)
    os.chown(str(path), 0, 0, follow_symlinks=False)
    # The migration runs with umask 077; mkdir(mode=0755) alone would leave mode 0700.
    path.chmod(0o755)


def verify_runtime(path, version):
    for parent, directories, files in os.walk(str(path), followlinks=False):
        for name in directories + files:
            item = Path(parent) / name
            info = item.lstat()
            if info.st_uid != 0:
                raise RuntimeInstallError("Runtime files must be root-owned before execution.")
            if item.is_symlink():
                if path not in item.resolve().parents:
                    raise RuntimeInstallError("Runtime link escapes its installed version.")
            elif info.st_mode & 0o022:
                raise RuntimeInstallError("Runtime files cannot be group/world-writable.")
    executable = path / "python" / "bin" / ("python" + ".".join(version.split(".")[:2]))
    if not executable.is_file() or executable.is_symlink():
        raise RuntimeInstallError("The pinned interpreter is missing or linked outside its expected location.")
    environment = dict(os.environ)
    for name in ("PYTHONPATH", "PYTHONHOME", "LD_PRELOAD", "LD_LIBRARY_PATH"):
        environment.pop(name, None)
    result = subprocess.run(
        [str(executable), "-I", "-c",
         "import argparse, dataclasses, fcntl, hashlib, json, pathlib, subprocess, sys, uuid; print(sys.version.split()[0])"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=30, env=environment,
    )
    if result.returncode != 0 or result.stdout.strip() != version:
        raise RuntimeInstallError("The pinned interpreter cannot run its required stdlib on this host.")
    return executable


def install(config):
    validate_config(config)
    if not hasattr(os, "geteuid") or os.geteuid() != 0 or platform.machine() != "x86_64":
        raise RuntimeInstallError("Private runtime installation requires root on Linux x86_64.")
    prepare_runtime_directory(ROOT, parents=True)
    runtimes = ROOT / "runtimes"
    prepare_runtime_directory(runtimes)
    version_name = "cpython-{}-{}-{}".format(config["version"], config["build"], config["sha256"][:16].lower())
    destination = runtimes / version_name
    stage = Path(tempfile.mkdtemp(prefix=".runtime-stage-", dir=str(ROOT)))
    temporary_link = ROOT / (".python3-" + stage.name)
    try:
        if destination.exists() or destination.is_symlink():
            require_private_root(destination)
            marker = destination / "archive.sha256"
            if (not marker.is_file() or marker.is_symlink() or marker.stat().st_uid != 0
                    or marker.stat().st_mode & 0o022 or marker.read_text().strip() != config["sha256"].lower()):
                raise RuntimeInstallError("Existing private runtime has a conflicting or incomplete digest marker.")
        else:
            archive_path = stage / "runtime.tar.gz"
            try:
                with urlopen(config["uri"], timeout=120) as response, archive_path.open("xb") as output:
                    if urlparse(response.geturl()).scheme != "https":
                        raise RuntimeInstallError("Runtime download redirected away from HTTPS.")
                    copied = 0
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        copied += len(block)
                        if copied > MAX_ARCHIVE_BYTES:
                            raise RuntimeInstallError("Runtime download exceeds the size limit.")
                        output.write(block)
            except OSError:
                raise RuntimeInstallError("Pinned runtime download failed; URI and response details were not logged.")
            if file_hash(archive_path).lower() != config["sha256"].lower():
                raise RuntimeInstallError("Pinned runtime SHA256 mismatch; no interpreter was activated.")
            expanded = stage / "expanded"
            expanded.mkdir(mode=0o755)
            extract_runtime(archive_path, expanded)
            verify_runtime(expanded, config["version"])
            marker = expanded / "archive.sha256"
            marker.write_text(config["sha256"].lower() + "\n")
            marker.chmod(0o644)
            expanded.rename(destination)
        executable = verify_runtime(destination, config["version"])
        selected = ROOT / "python3"
        if selected.exists() or selected.is_symlink():
            info = selected.lstat()
            if info.st_uid != 0 or not selected.is_symlink() or runtimes not in selected.resolve().parents:
                raise RuntimeInstallError("The existing runtime selector is not a broker-owned runtime link.")
        temporary_link.symlink_to(executable)
        os.chown(str(temporary_link), 0, 0, follow_symlinks=False)
        os.replace(str(temporary_link), str(selected))
        print("Installed pinned private broker Python {} ({}). System Python was not changed.".format(
            config["version"], config["build"]))
    finally:
        if temporary_link.is_symlink():
            temporary_link.unlink()
        # Only this invocation's newly allocated staging directory is removed.
        shutil.rmtree(str(stage))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config-base64", required=True)
    args = parser.parse_args()
    try:
        config = json.loads(base64.b64decode(args.config_base64, validate=True).decode("utf-8"))
        install(config)
    except (RuntimeInstallError, ValueError, OSError, subprocess.SubprocessError, tarfile.TarError) as error:
        if isinstance(error, RuntimeInstallError):
            print(str(error), file=sys.stderr)
        else:
            print("Private runtime installation failed; no interpreter activation was reported.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
