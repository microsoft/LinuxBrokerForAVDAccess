"""Run freezer preflight against synthetic cgroup files and read-only systemctl stubs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SOURCE = (REPO / "custom_script_extensions" / "check-broker-host-prerequisites.sh").read_text(encoding="utf-8")


class HostPrerequisiteTests(unittest.TestCase):
    def run_preflight(self, version=252, filesystem="cgroup2fs", state="running", freeze="0", event="0",
                      active="active", missing_file=False, group="/system.slice/", mode="full",
                      directory_owner="0", directory_mode="755", legacy=False, enrolled=True):
        parent = REPO / "deploy" / ".artifacts"
        parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="prerequisite-test-", dir=str(parent)) as temporary:
            root = Path(temporary)
            cgroups = root / "cgroup"
            cgroups.mkdir()
            (cgroups / "cgroup.controllers").write_bytes(b"cpu memory pids\n")
            for unit in ("xrdp.service", "xrdp-sesman.service"):
                directory = cgroups / "system.slice" / unit
                directory.mkdir(parents=True)
                if not missing_file:
                    (directory / "cgroup.freeze").write_bytes(freeze.encode())
                (directory / "cgroup.events").write_bytes(("populated 1\nfrozen " + event + "\n").encode())
            def shell_path(path):
                text = path.as_posix()
                return "/" + text[0].lower() + text[2:] if os.name == "nt" else text

            mountinfo = root / "mountinfo"
            records = "22 1 253:0 / / rw - xfs /dev/root rw\n"
            if legacy:
                for controller in ("freezer", "systemd"):
                    directory = cgroups / controller
                    directory.mkdir()
                    (directory / "cgroup.procs").write_bytes(b"")
                    options = "freezer" if controller == "freezer" else "name=systemd"
                    records += "3{} 22 0:3{} / {} rw - cgroup cgroup rw,{}\n".format(
                        1 if controller == "freezer" else 2, 1 if controller == "freezer" else 2,
                        shell_path(directory), options)
            mountinfo.write_bytes(records.encode())
            helper = root / "manage-lease.sh"
            runtime = root / "python3"
            if enrolled:
                helper.write_bytes(b'#!/bin/bash\nprintf "%s\\n" "$*" >> "$BROKER_TEST_CALLS"\n[[ "$*" == gate-status ]] || exit 93\nprintf \'{"backend":"freezer-v1","ready":true}\\n\'\n')
                runtime.write_bytes(b"#!/bin/bash\nexit 94\n")
                helper.chmod(0o755)
                runtime.chmod(0o755)
            script = root / "check.sh"
            stubs = """
systemctl() {
    printf '%s\\n' "$*" >> "$BROKER_TEST_CALLS"
    case "$1" in
        --version) printf 'systemd %s (fixture)\\n' "$BROKER_TEST_VERSION" ;;
        show)
            printf 'LoadState=loaded\\nActiveState=%s\\nControlGroup=%s%s\\nFreezerState=%s\\n' \
                "$BROKER_TEST_ACTIVE" "$BROKER_TEST_GROUP" "$2" "$BROKER_TEST_STATE"
            ;;
        *) echo 'Mutating/live systemctl operation forbidden in compatibility tests.' >&2; return 91 ;;
    esac
}
stat() {
    case "$1:$2" in
        -fc:%T)
            case "$3" in
                */freezer|*/systemd) printf 'cgroupfs\\n' ;;
                *) printf '%s\\n' "$BROKER_TEST_FILESYSTEM" ;;
            esac
            ;;
        -c:%u) printf '%s\\n' "$BROKER_TEST_DIRECTORY_OWNER" ;;
        -c:%a) printf '%s\\n' "$BROKER_TEST_DIRECTORY_MODE" ;;
        *) return 92 ;;
    esac
}
"""
            source = SOURCE.replace("/sys/fs/cgroup", shell_path(cgroups)).replace(
                "/proc/self/mountinfo", shell_path(mountinfo)).replace(
                "/usr/local/bin/manage-lease.sh", shell_path(helper)).replace(
                "/usr/local/libexec/linuxbroker/python3", shell_path(runtime))
            script.write_bytes((stubs + source).encode("utf-8"))
            environment = dict(os.environ)
            environment.update({
                "BROKER_TEST_VERSION": str(version), "BROKER_TEST_FILESYSTEM": filesystem,
                "BROKER_TEST_ACTIVE": active, "BROKER_TEST_GROUP": group, "BROKER_TEST_STATE": state,
                "BROKER_TEST_CALLS": (root / "calls").as_posix(),
                "BROKER_TEST_DIRECTORY_OWNER": directory_owner, "BROKER_TEST_DIRECTORY_MODE": directory_mode,
            })
            (root / "calls").write_bytes(b"")
            bash = shutil.which("bash")
            self.assertIsNotNone(bash, "Bash is required for the synthetic shell preflight tests.")
            result = subprocess.run([bash, "--noprofile", "--norc", script.as_posix(), mode], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            self.assertTrue((root / "calls").is_file(), "The synthetic shell fixture did not start: " + result.stderr)
            calls = (root / "calls").read_text().splitlines()
            self.assertTrue(all(line in ("--version", "gate-status") or line.startswith("show ") for line in calls))
            return result

    def test_supported_systemd_and_unified_cgroup_v2(self):
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("read-only check", result.stdout)

    def test_minimum_supported_systemd_boundary(self):
        self.assertEqual(self.run_preflight(version=246).returncode, 0)
        self.assertNotEqual(self.run_preflight(version=245).returncode, 0)

    def test_old_systemd_cannot_use_v2_gate_without_legacy_controllers(self):
        for version in (219, 239):
            with self.subTest(version=version):
                result = self.run_preflight(version=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("systemd >=246", result.stderr)

    def test_missing_complete_gate_controllers_fails(self):
        for filesystem in ("tmpfs", "cgroup", "unknown"):
            with self.subTest(filesystem=filesystem):
                result = self.run_preflight(filesystem=filesystem)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unified cgroup v2", result.stderr)

    def test_rhel7_and_rhel8_use_verified_legacy_controller_without_new_systemd(self):
        for version in (219, 239):
            with self.subTest(version=version):
                result = self.run_preflight(version=version, filesystem="tmpfs", legacy=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('"backend":"freezer-v1"', result.stdout)

    def test_legacy_platform_check_does_not_claim_enrollment(self):
        for mode in ("platform", "legacy-enrollment"):
            with self.subTest(mode=mode):
                result = self.run_preflight(version=219, filesystem="tmpfs", legacy=True, enrolled=False, mode=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("enrollment", result.stdout)
        result = self.run_preflight(version=219, filesystem="tmpfs", legacy=True, enrolled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not enrolled", result.stderr)

    def test_missing_freezer_interface_fails(self):
        self.assertNotEqual(self.run_preflight(missing_file=True).returncode, 0)

    def test_inactive_or_missing_xrdp_is_not_ready(self):
        for state in ("inactive", "failed", "activating"):
            with self.subTest(state=state):
                self.assertNotEqual(self.run_preflight(active=state).returncode, 0)

    def test_unknown_and_transitioning_freezer_states_fail(self):
        for state in ("", "freezing", "thawing", "unsupported"):
            with self.subTest(state=state):
                self.assertNotEqual(self.run_preflight(state=state).returncode, 0)

    def test_inconsistent_cgroup_and_systemd_states_fail(self):
        self.assertNotEqual(self.run_preflight(state="running", freeze="1", event="1").returncode, 0)
        self.assertNotEqual(self.run_preflight(state="frozen", freeze="1", event="0").returncode, 0)

    def test_frozen_gate_is_not_thawed_by_preflight(self):
        result = self.run_preflight(state="frozen", freeze="1", event="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("leaves it unchanged", result.stderr)
        self.assertIn("gateClosed recovery", result.stderr)

    def test_resume_requires_running_gate_and_installed_core_readiness_probe(self):
        self.assertEqual(self.run_preflight(mode="ready").returncode, 0)
        result = self.run_preflight(mode="ready", state="frozen", freeze="1", event="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("before checkout can resume", result.stderr)
        self.assertNotEqual(self.run_preflight(mode="ready", enrolled=False).returncode, 0)
        self.assertEqual(self.run_preflight(mode="ready", legacy=True, filesystem="tmpfs", version=219).returncode, 0)

    def test_control_group_cannot_escape_kernel_mount(self):
        self.assertNotEqual(self.run_preflight(group="/../../tmp/").returncode, 0)

    def test_platform_mode_does_not_require_xrdp_before_package_installation(self):
        result = self.run_preflight(mode="platform", active="inactive", missing_file=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("after package installation", result.stdout)

    def test_privileged_helper_parent_must_be_root_controlled(self):
        self.assertNotEqual(self.run_preflight(directory_owner="1000").returncode, 0)
        self.assertNotEqual(self.run_preflight(directory_mode="775").returncode, 0)
        self.assertNotEqual(self.run_preflight(directory_mode="777").returncode, 0)
        self.assertEqual(self.run_preflight(directory_mode="755").returncode, 0)


if __name__ == "__main__":
    unittest.main()
