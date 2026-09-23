"""Offline cross-distro mount-introspection and private-runtime deployment tests."""

import ast
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile
import tempfile
import types
import unittest
from unittest import mock


sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


runtime = load_module("broker_runtime_installer", REPO / "custom_script_extensions" / "install-broker-python.py")
if sys.platform == "win32":
    # Only import compatibility is stubbed; the tests must never acquire a Linux lease lock.
    with mock.patch.dict(sys.modules, {"fcntl": types.ModuleType("fcntl")}):
        lease = load_module("broker_mount_compatibility", REPO / "linux_host" / "broker-lease.py")
else:
    lease = load_module("broker_mount_compatibility", REPO / "linux_host" / "broker-lease.py")


ROOT_MOUNT = "22 1 253:0 / / rw,relatime - xfs /dev/mapper/rhel-root rw,attr2,inode64\n"


class MountInfoCompatibilityTests(unittest.TestCase):
    def inspect(self, content, target="/home/alice", error=None, device=(0, 41), require_leaf=False, stat_error=None):
        def read_bytes(path, *args, **kwargs):
            self.assertEqual(path.as_posix(), "/proc/self/mountinfo")
            if error:
                raise error
            return content.encode("utf-8")

        class MountedPath(PurePosixPath):
            def stat(self):
                if stat_error:
                    raise stat_error
                return types.SimpleNamespace(st_dev=device)

        def forbidden_command(*args, **kwargs):
            self.fail("Mount introspection cannot depend on findmnt --json, FSROOT, or another subprocess.")

        manager = lease.LeaseManager(runner=forbidden_command)
        with mock.patch.object(Path, "read_bytes", read_bytes), \
                mock.patch.object(lease.os, "major", lambda value: value[0], create=True), \
                mock.patch.object(lease.os, "minor", lambda value: value[1], create=True):
            return manager.mount_info(MountedPath(target), require_leaf=require_leaf)

    def test_rhel7_mountinfo_bind_root_and_nfs_source(self):
        content = ROOT_MOUNT + (
            "35 22 0:38 / /awipsprofiles rw,relatime shared:12 - nfs4 server:/exports/profiles rw,vers=4.1\n"
            "36 22 0:38 /alice /home/alice rw,relatime - nfs4 server:/exports/profiles rw,vers=4.1\n"
        )
        result = self.inspect(content, device=(0, 38))
        self.assertEqual(set(result), {"target", "source", "fstype", "fsroot"})
        self.assertEqual(result["target"], "/home/alice")
        self.assertEqual(result["source"], "server:/exports/profiles")
        self.assertEqual(result["fstype"], "nfs4")
        self.assertEqual(result["fsroot"], "/alice")

    def test_rhel8_optional_mount_fields(self):
        result = self.inspect(ROOT_MOUNT + (
            "43 22 0:51 /alice /home/alice rw,nosuid master:7 propagate_from:4 - nfs server:/profiles rw,vers=3\n"
        ), device=(0, 51))
        self.assertEqual(result["fstype"], "nfs")
        self.assertEqual(result["fsroot"], "/alice")

    def test_rhel9_and_ubuntu_ipv6_export(self):
        for optional in ("shared:8", "shared:8 master:4"):
            with self.subTest(optional=optional):
                result = self.inspect(ROOT_MOUNT + (
                    "49 22 0:41 /alice /home/alice rw,relatime {} - nfs4 [fd00::4]:/export rw,vers=4.2\n".format(optional)
                ))
                self.assertEqual(result["source"], "[fd00::4]:/export")

    def test_proc_escaping_in_target_source_and_root(self):
        result = self.inspect(
            ROOT_MOUNT + r"50 22 0:41 /alice\040profile /home/alice\040profile rw - nfs4 server:/export\040name rw" + "\n",
            target="/home/alice profile",
        )
        self.assertEqual(result["target"], "/home/alice profile")
        self.assertEqual(result["fsroot"], "/alice profile")
        self.assertEqual(result["source"], "server:/export name")

    def test_octal_backslash_is_decoded_once(self):
        result = self.inspect(
            ROOT_MOUNT + r"50 22 0:41 /alice\134040 /home/alice rw - nfs4 server:/export\134040 rw" + "\n"
        )
        self.assertEqual(result["fsroot"], r"/alice\040")
        self.assertEqual(result["source"], r"server:/export\040")

    def test_tabs_and_newlines_are_kernel_escaped_not_field_separators(self):
        result = self.inspect(
            ROOT_MOUNT + r"50 22 0:41 /alice\011name\012line /home/alice rw - nfs4 server:/export rw" + "\n"
        )
        self.assertEqual(result["fsroot"], "/alice\tname\nline")

    def test_only_verified_absence_returns_none(self):
        self.assertIsNone(self.inspect(ROOT_MOUNT))
        self.assertIsNone(self.inspect(ROOT_MOUNT + "41 22 0:41 /alice /home/alice-other rw - nfs4 server:/export rw\n"))

    def test_stacked_same_target_mount_is_ambiguous(self):
        content = ROOT_MOUNT + (
            "41 22 0:41 /alice /home/alice rw - nfs4 server:/export rw\n"
            "42 22 0:42 /other /home/alice rw - nfs4 other:/export rw\n"
        )
        with self.assertRaises(lease.LeaseError):
            self.inspect(content)

    def test_read_failure_is_not_unmounted(self):
        for error in (PermissionError("denied"), OSError("unavailable")):
            with self.subTest(error=type(error).__name__), self.assertRaises(lease.LeaseError):
                self.inspect(ROOT_MOUNT, error=error)

    def test_visible_device_mismatch_blocks_unmount(self):
        content = ROOT_MOUNT + "41 22 0:41 /alice /home/alice rw - nfs4 server:/export rw\n"
        with self.assertRaises(lease.LeaseError):
            self.inspect(content, device=(0, 42))
        with self.assertRaises(lease.LeaseError):
            self.inspect(content, stat_error=PermissionError("cannot stat"))

    def test_nested_mount_blocks_home_cleanup(self):
        content = ROOT_MOUNT + (
            "41 22 0:41 /alice /home/alice rw - nfs4 server:/export rw\n"
            "42 41 0:42 / /home/alice/nested rw - tmpfs tmpfs rw\n"
        )
        with self.assertRaises(lease.LeaseError):
            self.inspect(content, require_leaf=True)

    def test_malformed_or_incomplete_mount_inventory_fails_closed(self):
        for row in (
            "",
            "not mountinfo\n",
            "41 22 0:41 /alice /home/alice rw nfs4 server:/export rw\n",
            "41 22 0:41 /alice /home/alice rw - nfs4\n",
            r"41 22 0:41 /alice\123 /home/alice rw - nfs4 server:/export rw" + "\n",
            "41 22 0:41 /alice /home/alice rw - nfs4 server:/export rw\nbroken trailing record\n",
        ):
            with self.subTest(row=row), self.assertRaises(lease.LeaseError):
                self.inspect(row)


class PinnedRuntimeInstallerTests(unittest.TestCase):
    def config(self):
        return json.loads((REPO / "deploy" / "linux-python.lock.json").read_text(encoding="utf-8"))

    def test_bootstrap_installer_uses_python36_syntax(self):
        source = (REPO / "custom_script_extensions" / "install-broker-python.py").read_text(encoding="utf-8")
        ast.parse(source, feature_version=(3, 6))
        self.assertNotIn("capture_output=", source)
        self.assertNotIn("text=True", source)
        self.assertNotIn("dataclasses", [node.module for node in ast.walk(ast.parse(source)) if isinstance(node, ast.ImportFrom)])

    def test_runtime_lock_is_exact_and_compatible(self):
        config = runtime.validate_config(self.config())
        self.assertEqual(config["minimumGlibc"], "2.17")
        self.assertEqual(config["target"], "x86_64-unknown-linux-gnu")
        self.assertEqual(len(config["sha256"]), 64)
        self.assertIn("/releases/download/{}/".format(config["build"]), config["uri"])

    def test_runtime_selector_parent_permissions_are_explicit_not_umask_dependent(self):
        directory = Path("owned-runtime-directory")
        with mock.patch.object(runtime, "require_private_root") as guard, \
                mock.patch.object(Path, "mkdir") as mkdir, \
                mock.patch.object(runtime.os, "chown", create=True) as chown, \
                mock.patch.object(Path, "chmod") as chmod:
            runtime.prepare_runtime_directory(directory)
        self.assertEqual(guard.call_count, 2)
        mkdir.assert_called_once_with(mode=0o755, parents=False, exist_ok=True)
        chown.assert_called_once_with(str(directory), 0, 0, follow_symlinks=False)
        chmod.assert_called_once_with(0o755)

    def test_unpinned_secret_bearing_or_incompatible_locks_rejected(self):
        mutations = (
            ("sha256", ""),
            ("version", "3.6.15"),
            ("uri", "https://example.org/runtime.tar.gz?sig=secret"),
            ("uri", "http://example.org/runtime.tar.gz"),
            ("target", "x86_64_v3-unknown-linux-gnu"),
            ("minimumGlibc", "2.28"),
        )
        for key, value in mutations:
            with self.subTest(key=key):
                config = self.config()
                config[key] = value
                with self.assertRaises(runtime.RuntimeInstallError):
                    runtime.validate_config(config)

    def archive(self, entries):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name, kind, link in entries:
                entry = tarfile.TarInfo(name)
                entry.type = kind
                entry.linkname = link
                if kind == tarfile.REGTYPE:
                    entry.size = 1
                    archive.addfile(entry, io.BytesIO(b"x"))
                else:
                    archive.addfile(entry)
        stream.seek(0)
        return tarfile.open(fileobj=stream, mode="r:gz")

    def test_internal_python_selector_link_allowed(self):
        with self.archive((
            ("python/bin/python3.11", tarfile.REGTYPE, ""),
            ("python/bin/python3", tarfile.SYMTYPE, "python3.11"),
        )) as archive:
            self.assertEqual(len(runtime.archive_members(archive)), 2)

    def test_tar_traversal_links_devices_and_duplicates_rejected(self):
        cases = (
            [("../escape", tarfile.REGTYPE, "")],
            [("/absolute", tarfile.REGTYPE, "")],
            [("python/bin/link", tarfile.SYMTYPE, "../../../escape")],
            [("python/bin/link", tarfile.SYMTYPE, "/bin/sh")],
            [("python/bin/device", tarfile.CHRTYPE, "")],
            [("python/bin/hardlink", tarfile.LNKTYPE, "python/bin/python3")],
            [("python/file", tarfile.REGTYPE, ""), ("python/file", tarfile.REGTYPE, "")],
            [("python/lib", tarfile.SYMTYPE, "bin"), ("python/lib/injected", tarfile.REGTYPE, "")],
        )
        for entries in cases:
            with self.subTest(entries=entries), self.archive(entries) as archive:
                with self.assertRaises(runtime.RuntimeInstallError):
                    runtime.archive_members(archive)

    def test_hash_is_actual_archive_bytes(self):
        with tempfile.TemporaryDirectory(prefix="broker-runtime-test-") as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"abc")
            self.assertEqual(runtime.file_hash(path), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")


if __name__ == "__main__":
    unittest.main()
