"""Kernel mountinfo compatibility fixtures, not util-linux output mocks."""

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


if sys.platform == "linux":
    specification = importlib.util.spec_from_file_location(
        "broker_mountinfo_test", Path(__file__).resolve().parents[1] / "broker-lease.py",
    )
    broker = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = broker
    specification.loader.exec_module(broker)


@unittest.skipUnless(sys.platform == "linux", "Kernel mountinfo validation runs on Linux.")
class MountinfoCompatibility(unittest.TestCase):
    def test_rhel7_to_current_kernel_records_share_the_same_interface(self):
        # Representative ABI records for the supported kernel generations; these are
        # synthetic compatibility fixtures, not claims of live distro validation.
        variants = {
            "RHEL7 / kernel 3.10": b"shared:25",
            "RHEL8 / kernel 4.18": b"shared:25 master:1",
            "RHEL9 / kernel 5.14": b"shared:25 master:1 propagate_from:2",
            "Ubuntu22.04 / kernel 5.15": b"",
            "Ubuntu24.04 / kernel 6.8": b"shared:25 unbindable future_extension:1",
        }
        for platform, optional in variants.items():
            with self.subTest(platform=platform):
                before = b"47 25 0:41 /User_Profile /home/User_Profile rw,relatime"
                line = before + (b" " + optional if optional else b"") + b" - nfs4 server:/profiles rw,vers=4.1,sec=sys\n"
                self.assertEqual(broker.parse_mountinfo(line), [{
                    "id": 47, "parent": 25, "major": 0, "minor": 41, "fsroot": "/User_Profile",
                    "target": "/home/User_Profile", "fstype": "nfs4", "source": "server:/profiles",
                    "super_options": ("rw", "vers=4.1", "sec=sys"),
                }])

    def test_space_tab_newline_and_literal_backslash_are_decoded_once(self):
        line = (
            br"47 25 0:41 /profile\040with\011tab\012newline\134040 /home/space\040tab\011newline\012slash\134040 rw"
            br" - nfs4 server:/exports\040name\134011 rw" + b"\n"
        )
        mount = broker.parse_mountinfo(line)[0]
        self.assertEqual(mount["fsroot"], "/profile with\ttab\nnewline\\040")
        self.assertEqual(mount["target"], "/home/space tab\tnewline\nslash\\040")
        self.assertEqual(mount["source"], "server:/exports name\\011")

    def test_non_utf8_path_bytes_are_preserved_without_loss(self):
        mount = broker.parse_mountinfo(b"47 25 0:41 /profile\xff /home/profile\xff rw - nfs server:/profiles\xfe rw\n")[0]
        self.assertEqual(os.fsencode(mount["target"]), b"/home/profile\xff")
        self.assertEqual(os.fsencode(mount["source"]), b"server:/profiles\xfe")

    def test_ipv6_sources_and_absent_namespace_parent_are_valid(self):
        mount = broker.parse_mountinfo(b"47 9000 0:41 / /awipsprofiles rw - nfs4 [2001:db8::1]:/profiles rw,vers=4.1\n")[0]
        self.assertEqual(mount["source"], "[2001:db8::1]:/profiles")
        self.assertEqual(mount["parent"], 9000)

    def test_malformed_or_truncated_records_fail_instead_of_looking_unmounted(self):
        good = b"47 25 0:41 / /awipsprofiles rw - nfs4 server:/profiles rw\n"
        invalid = [
            b"", good.rstrip(b"\n"), b"\n", good + b"\n",
            b"47 25 0:41 / /awipsprofiles rw nfs4 server:/profiles rw\n",
            good.replace(b"47 25", b"x 25"),
            good.replace(b"47 25", b"47 -1"),
            good.replace(b"0:41", b"0:x"),
            good.replace(b"/awipsprofiles", b"relative"),
            good.replace(b"/awipsprofiles", br"/a\999"),
            good.replace(b"/awipsprofiles", br"/a\040\000"),
            good.replace(b"/awipsprofiles", b"/a\0b"),
            good.replace(b"/awipsprofiles", b"/a\tb"),
            good.replace(b" rw\n", b"\n"),
            good.replace(b" rw\n", b" rw unexpected\n"),
            good + good,
        ]
        for record in invalid:
            with self.subTest(record=record), self.assertRaises(broker.LeaseError):
                broker.parse_mountinfo(record)

    def test_unrelated_malformed_record_is_not_silently_skipped(self):
        with self.assertRaises(broker.LeaseError):
            broker.parse_mountinfo(b"47 25 0:41 / /awipsprofiles rw - nfs4 server:/profiles rw\nbroken\n")


@unittest.skipUnless(sys.platform == "linux", "Kernel mountinfo validation runs on Linux.")
class MountinfoLookup(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="linuxbroker-mountinfo-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.table = self.root / "mountinfo"
        self.target = self.root / "home"
        self.target.mkdir()
        paths = broker.Paths(mountinfo=self.table)
        self.manager = broker.LeaseManager(paths=paths, runner=self.no_commands)

    @staticmethod
    def no_commands(*_args, **_kwargs):
        raise AssertionError("Mount inspection must not execute a host command.")

    def record(self, mount_id=47, target=None, device=None, fstype="nfs4", root="/profile"):
        target = self.target if target is None else target
        device = self.target.stat().st_dev if device is None else device
        values = [
            str(mount_id), "25", f"{os.major(device)}:{os.minor(device)}", root, str(target),
            "rw,relatime", "-", fstype, "server:/profiles", "rw",
        ]
        escaped = [os.fsencode(value).replace(b"\\", br"\134").replace(b" ", br"\040")
                   .replace(b"\t", br"\011").replace(b"\n", br"\012") for value in values]
        return b" ".join(escaped) + b"\n"

    def test_exact_mountpoints_not_substrings_or_parent_filesystems(self):
        self.table.write_bytes(self.record())
        self.assertEqual(self.manager.mount_info(self.target), {
            "target": str(self.target), "source": "server:/profiles", "fstype": "nfs4", "fsroot": "/profile",
        })
        self.assertIsNone(self.manager.mount_info(self.target / "unmounted-child"))
        self.assertIsNone(self.manager.mount_info(self.root / "home-other"))
        self.assertIsNone(self.manager.mount_info(self.root))

    def test_paths_containing_whitespace_are_matched_after_unescaping(self):
        target = self.root / "space tab\tnewline\nbackslash\\040"
        target.mkdir()
        self.table.write_bytes(self.record(target=target))
        self.assertEqual(self.manager.mount_info(target)["target"], str(target))

    def test_stacked_target_and_stacked_ancestor_are_not_guessed(self):
        for document in (
            self.record() + self.record(mount_id=48),
            self.record() + self.record(mount_id=48, target=self.root)
            + self.record(mount_id=49, target=self.root),
        ):
            with self.subTest(document=document):
                self.table.write_bytes(document)
                with self.assertRaises(broker.LeaseError):
                    self.manager.mount_info(self.target)

    def test_nested_mount_is_rejected_even_when_the_home_mount_is_absent(self):
        for document in (
            self.record() + self.record(mount_id=48, target=self.target / "nested"),
            self.record(mount_id=48, target=self.target / "nested"),
        ):
            with self.subTest(document=document):
                self.table.write_bytes(document)
                with self.assertRaises(broker.LeaseError):
                    self.manager.mount_info(self.target, require_leaf=True)
        self.table.write_bytes(self.record() + self.record(mount_id=48, target=self.root / "home-other"))
        self.assertIsNotNone(self.manager.mount_info(self.target, require_leaf=True))

    def test_visible_filesystem_must_match_the_kernel_record(self):
        self.table.write_bytes(self.record(device=os.makedev(0, 0)))
        with self.assertRaises(broker.LeaseError):
            self.manager.mount_info(self.target)

    def test_missing_or_unreadable_mountinfo_is_uncertainty(self):
        with self.assertRaises(broker.LeaseError):
            self.manager.mount_info(self.target)
        with patch.object(Path, "read_bytes", side_effect=PermissionError("test access denied")):
            with self.assertRaises(broker.LeaseError):
                self.manager.mount_info(self.target)

    def test_each_lookup_reads_a_fresh_snapshot(self):
        self.table.write_bytes(self.record())
        self.assertIsNotNone(self.manager.mount_info(self.target))
        self.table.write_bytes(self.record(target=self.root))
        self.assertIsNone(self.manager.mount_info(self.target))

    def test_real_local_proc_mountinfo_is_read_only_and_needs_no_findmnt(self):
        # Only inspect kernel metadata; never mount, unmount, or change host state.
        manager = broker.LeaseManager(runner=self.no_commands)
        mount = manager.mount_info(Path("/"))
        self.assertIsNotNone(mount)
        self.assertEqual(mount["target"], "/")
        self.assertEqual(set(mount), {"target", "source", "fstype", "fsroot"})
        self.assertTrue(mount["fsroot"].startswith("/"))
        self.assertTrue(mount["fstype"])


if __name__ == "__main__":
    unittest.main()
