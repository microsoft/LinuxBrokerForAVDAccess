#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/patch-host.sh"
STATE_DIR="/var/lib/linuxbroker-release-session"
STATE_FILE="$STATE_DIR/patch-state"
LOG_FILE="/var/log/linuxbroker-patch.log"
MANAGER_SHIMS=(dnf yum apt-get unattended-upgrade needs-restarting systemd-run)
BOOT_SHIMS=(grubby dracut lsinitrd update-initramfs uname df)
MADE_SYSTEMD_DIR=0
HID_APT_GET=0

remove_shims() {
    local name
    for name in "${MANAGER_SHIMS[@]}" "${BOOT_SHIMS[@]}"; do
        rm -f "$SHIM_DIR/$name"
    done
    # Only the files the boot tests create; the container has no kernels of its own.
    rm -f /boot/*lbtest*
    rm -f /run/reboot-required
    if [ "$MADE_SYSTEMD_DIR" = "1" ]; then
        rmdir /run/systemd/system 2>/dev/null || true
        MADE_SYSTEMD_DIR=0
    fi
    if [ "$HID_APT_GET" = "1" ]; then
        mv -f /usr/bin/apt-get.linuxbroker-test /usr/bin/apt-get
        HID_APT_GET=0
    fi
}
trap remove_shims EXIT

# A package manager that records its arguments. It fails when FAKE_PM_FAIL is set, and waits
# while FAKE_PM_HOLD names a file, so a test can see a run in progress. With FAKE_NEW_KERNEL
# it installs that kernel into /boot, and its initramfs unless FAKE_NO_INITRAMFS is set, and
# makes it the default as RHEL does.
install_manager() {
    local name="$1"
    cat > "$SHIM_DIR/$name" <<'SHIM'
#!/bin/bash
echo "$(basename "$0") $*" >> "${FAKE_CALLS:-/dev/null}"
while [ -n "${FAKE_PM_HOLD:-}" ] && [ -e "$FAKE_PM_HOLD" ]; do sleep 0.2; done
if [ -n "${FAKE_NEW_KERNEL:-}" ]; then
  printf 'kernel' > "/boot/vmlinuz-$FAKE_NEW_KERNEL"
  if [ -z "${FAKE_NO_INITRAMFS:-}" ]; then
    if [ "${FAKE_BOOT_STYLE:-rhel}" = "ubuntu" ]; then
      printf 'initramfs' > "/boot/initrd.img-$FAKE_NEW_KERNEL"
    else
      printf 'initramfs' > "/boot/initramfs-$FAKE_NEW_KERNEL.img"
    fi
  fi
  if [ -n "${FAKE_GRUBBY_DEFAULT:-}" ] && [ -f "$FAKE_GRUBBY_DEFAULT" ]; then
    echo "/boot/vmlinuz-$FAKE_NEW_KERNEL" > "$FAKE_GRUBBY_DEFAULT"
  fi
fi
if [ -n "${FAKE_PM_FAIL:-}" ]; then
  echo "Error: Failed to download metadata for repo 'rhel-9-baseos'"
  exit 1
fi
echo "Complete!"
SHIM
    chmod +x "$SHIM_DIR/$name"
}

# /boot as a test sees it: the running kernel FAKE_RUNNING with a full-size (sparse) initramfs,
# FAKE_BOOT_FREE_MB free, and stand-ins for grubby (RHEL only), dracut, update-initramfs and
# lsinitrd, which treats a file starting with "corrupt" as damaged.
install_boot_shims() {
    local style="$1"
    mkdir -p /boot
    export FAKE_BOOT_STYLE="$style"
    if [ "$style" = "ubuntu" ]; then
        export FAKE_RUNNING="6.8.0-1.lbtest-azure"
        printf 'kernel' > "/boot/vmlinuz-$FAKE_RUNNING"
        truncate -s 70M "/boot/initrd.img-$FAKE_RUNNING"
    else
        export FAKE_RUNNING="5.14.0-1.lbtest.x86_64"
        export FAKE_GRUBBY_DEFAULT="$WORK_DIR/grubby-default"
        echo "/boot/vmlinuz-$FAKE_RUNNING" > "$FAKE_GRUBBY_DEFAULT"
        printf 'kernel' > "/boot/vmlinuz-$FAKE_RUNNING"
        truncate -s 256M "/boot/initramfs-$FAKE_RUNNING.img"
        truncate -s 40M "/boot/initramfs-${FAKE_RUNNING}kdump.img"
        cat > "$SHIM_DIR/grubby" <<'SHIM'
#!/bin/bash
echo "grubby $*" >> "${FAKE_CALLS:-/dev/null}"
case "$1" in
  --default-kernel) cat "$FAKE_GRUBBY_DEFAULT" ;;
  --set-default) echo "$2" > "$FAKE_GRUBBY_DEFAULT" ;;
esac
SHIM
    fi
    cat > "$SHIM_DIR/uname" <<'SHIM'
#!/bin/bash
if [ "$*" = "-r" ]; then echo "$FAKE_RUNNING"; else exec /usr/bin/uname "$@"; fi
SHIM
    cat > "$SHIM_DIR/df" <<'SHIM'
#!/bin/bash
if [ "$*" = "-Pm /boot" ] && [ -n "${FAKE_BOOT_FREE_MB:-}" ]; then
  echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
  echo "/dev/sda2 960 $((960 - FAKE_BOOT_FREE_MB)) $FAKE_BOOT_FREE_MB 70% /boot"
else
  exec /usr/bin/df "$@"
fi
SHIM
    cat > "$SHIM_DIR/dracut" <<'SHIM'
#!/bin/bash
echo "dracut $*" >> "${FAKE_CALLS:-/dev/null}"
if [ -n "${FAKE_DRACUT_FAIL:-}" ]; then
  echo "cp: error writing '$2': No space left on device"
  exit 1
fi
printf 'initramfs' > "$2"
SHIM
    cat > "$SHIM_DIR/update-initramfs" <<'SHIM'
#!/bin/bash
echo "update-initramfs $*" >> "${FAKE_CALLS:-/dev/null}"
[ -n "${FAKE_DRACUT_FAIL:-}" ] && exit 1
printf 'initramfs' > "/boot/initrd.img-$3"
SHIM
    cat > "$SHIM_DIR/lsinitrd" <<'SHIM'
#!/bin/bash
[ -s "$1" ] && [ "$(head -c 7 "$1")" != "corrupt" ]
SHIM
    chmod +x "$SHIM_DIR/uname" "$SHIM_DIR/df" "$SHIM_DIR/dracut" "$SHIM_DIR/update-initramfs" "$SHIM_DIR/lsinitrd"
    [ -f "$SHIM_DIR/grubby" ] && chmod +x "$SHIM_DIR/grubby"
    return 0
}

setup_case() {
    remove_shims
    reset_work
    rm -f "$STATE_FILE" "$STATE_DIR/patch.lock" "$STATE_DIR/patch-run.lock" "$LOG_FILE"
    mkdir -p "$STATE_DIR"
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    unset FAKE_PM_FAIL FAKE_PM_HOLD FAKE_NEW_KERNEL FAKE_NO_INITRAMFS FAKE_BOOT_FREE_MB FAKE_DRACUT_FAIL \
        FAKE_BOOT_STYLE FAKE_GRUBBY_DEFAULT FAKE_RUNNING
}

marker() {
    printf '%s\n' "$1" | sed -n "s/^__PATCH_HOST_$2=//p" | tail -n 1
}

# Polls status until the run is no longer running.
wait_for_run() {
    local out attempts=0
    while :; do
        out=$(bash "$SCRIPT" status)
        [ "$(marker "$out" STATE)" != "running" ] && { printf '%s\n' "$out"; return 0; }
        attempts=$((attempts + 1))
        [ "$attempts" -gt 50 ] && fail "the patch run never finished: $out"
        sleep 0.2
    done
}

test_arguments_are_validated() {
    setup_case
    local status

    bash "$SCRIPT" start everything >/dev/null 2>&1; status=$?
    assert_eq "$status" "2" "mode"
    bash "$SCRIPT" start all 'bad token!' >/dev/null 2>&1; status=$?
    assert_eq "$status" "2" "token"
    bash "$SCRIPT" status extra >/dev/null 2>&1; status=$?
    assert_eq "$status" "2" "status arguments"
    bash "$SCRIPT" reboot >/dev/null 2>&1; status=$?
    assert_eq "$status" "2" "unknown action"
}

test_status_without_a_run() {
    setup_case
    install_manager dnf
    local out
    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" STATE)" "none"
    assert_eq "$(marker "$out" TOKEN)" ""
}

test_dnf_run_detaches_and_succeeds() {
    setup_case
    install_manager dnf
    local out

    out=$(bash "$SCRIPT" start all run12-vm5-1)
    assert_eq "$(marker "$out" RESULT)" "started"
    assert_eq "$(marker "$out" TOKEN)" "run12-vm5-1"
    assert_eq "$(marker "$out" MANAGER)" "dnf"

    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(marker "$out" EXIT_CODE)" "0"
    assert_eq "$(marker "$out" MODE)" "all"
    [ -n "$(marker "$out" FINISHED_AT)" ] || fail "no finish time"
    assert_file_contains "$FAKE_CALLS" "dnf -y upgrade --refresh"
    assert_file_contains "$LOG_FILE" "Complete!"

    # Repeating the same start only reports the run.
    out=$(bash "$SCRIPT" start all run12-vm5-1)
    assert_eq "$(marker "$out" RESULT)" "already-started"
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(grep -c '^dnf ' "$FAKE_CALLS")" "1" "dnf runs"
}

test_security_updates_only() {
    setup_case
    install_manager dnf
    bash "$SCRIPT" start security run1-vm1-1 >/dev/null
    wait_for_run >/dev/null
    assert_file_contains "$FAKE_CALLS" "dnf -y upgrade --security --refresh"
}

test_a_run_in_progress_is_not_started_twice() {
    setup_case
    install_manager dnf
    export FAKE_PM_HOLD="$WORK_DIR/hold"
    touch "$FAKE_PM_HOLD"
    local out

    bash "$SCRIPT" start all run2-vm1-1 >/dev/null
    sleep 0.5
    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" STATE)" "running"

    out=$(bash "$SCRIPT" start all run2-vm1-2)
    assert_eq "$(marker "$out" RESULT)" "busy"
    assert_eq "$(marker "$out" TOKEN)" "run2-vm1-1"

    rm -f "$FAKE_PM_HOLD"
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(grep -c '^dnf ' "$FAKE_CALLS")" "1" "dnf runs"
}

test_a_failed_run_reports_why() {
    setup_case
    install_manager dnf
    export FAKE_PM_FAIL=1
    local out

    bash "$SCRIPT" start all run3-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "failed"
    assert_eq "$(marker "$out" EXIT_CODE)" "1"
    assert_contains "$(marker "$out" SUMMARY)" "Failed to download metadata"

    # A new token starts a new run once the last one has ended.
    unset FAKE_PM_FAIL
    out=$(bash "$SCRIPT" start all run3-vm1-2)
    assert_eq "$(marker "$out" RESULT)" "started"
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
}

test_yum_on_rhel7() {
    setup_case
    install_manager yum
    bash "$SCRIPT" start security run4-vm1-1 >/dev/null
    local out
    out=$(wait_for_run)
    assert_eq "$(marker "$out" MANAGER)" "yum"
    assert_file_contains "$FAKE_CALLS" "yum -y update --security"
}

test_apt_on_ubuntu() {
    setup_case
    install_manager apt-get
    install_manager unattended-upgrade
    local out

    bash "$SCRIPT" start all run5-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" MANAGER)" "apt"
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_file_contains "$FAKE_CALLS" "apt-get -o DPkg::Lock::Timeout=600 update"
    assert_file_contains "$FAKE_CALLS" "force-confold -y --with-new-pkgs upgrade"
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "no"

    touch /run/reboot-required
    out=$(bash "$SCRIPT" start security run5-vm1-2)
    out=$(wait_for_run)
    assert_file_contains "$FAKE_CALLS" "unattended-upgrade -v"
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "yes"

    # Security updates alone need unattended-upgrades.
    rm -f "$SHIM_DIR/unattended-upgrade"
    bash "$SCRIPT" start security run5-vm1-3 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "failed"
    assert_eq "$(marker "$out" EXIT_CODE)" "3"
    assert_contains "$(marker "$out" SUMMARY)" "unattended-upgrades is not installed"
}

test_reboot_required_on_rhel() {
    setup_case
    install_manager dnf
    cat > "$SHIM_DIR/needs-restarting" <<'SHIM'
#!/bin/bash
exit "${FAKE_NEEDS_RESTARTING:-0}"
SHIM
    chmod +x "$SHIM_DIR/needs-restarting"
    local out

    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "no"
    out=$(FAKE_NEEDS_RESTARTING=1 bash "$SCRIPT" status)
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "yes"
    out=$(FAKE_NEEDS_RESTARTING=2 bash "$SCRIPT" status)
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "unknown"

    rm -f "$SHIM_DIR/needs-restarting"
    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" REBOOT_REQUIRED)" "unknown"
}

test_a_run_that_vanished_is_interrupted() {
    setup_case
    install_manager dnf
    printf 'STATE=running\nMODE=all\nTOKEN=run6-vm1-1\nSTARTED_AT=%s\nFINISHED_AT=\nEXIT_CODE=\nMANAGER=dnf\nUNIT=\nPID=999999\n' \
        "$(( $(date +%s) - 600 ))" > "$STATE_FILE"
    echo "Downloading packages: 42%" > "$LOG_FILE"
    local out

    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" STATE)" "interrupted"
    assert_contains "$(marker "$out" SUMMARY)" "Downloading packages"

    # The same token is not run again; a new one is.
    out=$(bash "$SCRIPT" start all run6-vm1-1)
    assert_eq "$(marker "$out" RESULT)" "already-started"
    out=$(bash "$SCRIPT" start all run6-vm1-2)
    assert_eq "$(marker "$out" RESULT)" "started"
    wait_for_run >/dev/null
}

test_a_damaged_state_file_is_ignored() {
    setup_case
    install_manager dnf
    printf 'STATE=running; rm -rf /\nTOKEN=$(reboot)\nPID=abc\n' > "$STATE_FILE"
    local out
    out=$(bash "$SCRIPT" status)
    assert_eq "$(marker "$out" STATE)" "none"
    assert_eq "$(marker "$out" TOKEN)" ""
}

test_systemd_runs_the_patch_as_a_transient_unit() {
    setup_case
    install_manager dnf
    if [ ! -d /run/systemd/system ]; then
        mkdir -p /run/systemd/system
        MADE_SYSTEMD_DIR=1
    fi
    # Records the unit and runs it in the background, as systemd would.
    cat > "$SHIM_DIR/systemd-run" <<'SHIM'
#!/bin/bash
echo "systemd-run $*" >> "${FAKE_CALLS:-/dev/null}"
while [ $# -gt 0 ] && [[ "$1" == --* ]]; do shift; done
setsid "$@" >/dev/null 2>&1 < /dev/null &
SHIM
    chmod +x "$SHIM_DIR/systemd-run"
    local out

    out=$(bash "$SCRIPT" start all run7-vm1-1)
    assert_eq "$(marker "$out" RESULT)" "started"
    assert_file_contains "$FAKE_CALLS" "systemd-run --unit=linuxbroker-patch-"
    assert_file_contains "$FAKE_CALLS" "patch-host.sh run all run7-vm1-1"
    assert_file_contains "$STATE_FILE" "UNIT=linuxbroker-patch-"
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
}

test_no_package_manager() {
    setup_case
    # Hide the container's own apt-get; remove_shims puts it back.
    if [ -e /usr/bin/apt-get ]; then
        mv /usr/bin/apt-get /usr/bin/apt-get.linuxbroker-test
        HID_APT_GET=1
    fi
    local out status
    out=$(bash "$SCRIPT" start all run8-vm1-1 2>&1); status=$?
    assert_eq "$status" "1"
    assert_contains "$out" "__PATCH_HOST_RESULT=unsupported"
    assert_not_exists "$STATE_FILE"
}

# Azure's RHEL 9 image has a 960 MB /boot and 256 MB initramfs images, so it holds two
# kernels; dnf keeps three by default and the third one's initramfs does not fit.
test_a_full_boot_keeps_two_kernels() {
    setup_case
    install_manager dnf
    install_boot_shims rhel
    export FAKE_NEW_KERNEL="5.14.0-2.lbtest.x86_64" FAKE_BOOT_FREE_MB=254
    local out

    bash "$SCRIPT" start security run9-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(grep '^dnf ' "$FAKE_CALLS" | tail -n 1)" "dnf -y upgrade --security --refresh --setopt=installonly_limit=2"
    assert_file_contains "$LOG_FILE" "/boot has 254 MB free and a kernel needs about 347 MB"

    # With room for another kernel the host's own limit applies.
    export FAKE_BOOT_FREE_MB=2000
    bash "$SCRIPT" start all run9-vm1-2 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(grep '^dnf ' "$FAKE_CALLS" | tail -n 1)" "dnf -y upgrade --refresh"
}

test_a_missing_or_damaged_initramfs_is_rebuilt() {
    setup_case
    install_manager dnf
    install_boot_shims rhel
    export FAKE_NEW_KERNEL="5.14.0-2.lbtest.x86_64" FAKE_NO_INITRAMFS=1 FAKE_BOOT_FREE_MB=2000
    local out

    bash "$SCRIPT" start security run10-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_file_contains "$FAKE_CALLS" "dracut -f /boot/initramfs-5.14.0-2.lbtest.x86_64.img 5.14.0-2.lbtest.x86_64"
    assert_file_contains "$LOG_FILE" "Built /boot/initramfs-5.14.0-2.lbtest.x86_64.img."
    assert_eq "$(cat "$FAKE_GRUBBY_DEFAULT")" "/boot/vmlinuz-5.14.0-2.lbtest.x86_64" "the new kernel stays the default"

    # A truncated image is no better than none.
    printf 'corrupt image' > /boot/initramfs-5.14.0-2.lbtest.x86_64.img
    unset FAKE_NEW_KERNEL
    bash "$SCRIPT" start security run10-vm1-2 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_eq "$(head -c 9 /boot/initramfs-5.14.0-2.lbtest.x86_64.img)" "initramfs" "rebuilt"
}

# What happened on a real host: dnf reported success, the initramfs was never written, and a
# restart would have stopped in GRUB. The run fails instead and the host still boots.
test_a_kernel_that_cannot_boot_fails_the_run() {
    setup_case
    install_manager dnf
    install_boot_shims rhel
    export FAKE_NEW_KERNEL="5.14.0-2.lbtest.x86_64" FAKE_NO_INITRAMFS=1 FAKE_DRACUT_FAIL=1 FAKE_BOOT_FREE_MB=100
    local out

    bash "$SCRIPT" start security run11-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "failed"
    assert_eq "$(marker "$out" EXIT_CODE)" "5"
    assert_contains "$(marker "$out" SUMMARY)" "Could not build the initramfs for 5.14.0-2.lbtest.x86_64; /boot has 100 MB free."
    assert_file_contains "$FAKE_CALLS" "grubby --set-default /boot/vmlinuz-5.14.0-1.lbtest.x86_64"
    assert_eq "$(cat "$FAKE_GRUBBY_DEFAULT")" "/boot/vmlinuz-5.14.0-1.lbtest.x86_64" "the running kernel is the default again"
    assert_not_exists /boot/initramfs-5.14.0-2.lbtest.x86_64.img
    assert_file_contains "$LOG_FILE" "Made the running kernel, 5.14.0-1.lbtest.x86_64, the default again"
}

test_ubuntu_rebuilds_a_missing_initrd() {
    setup_case
    install_manager apt-get
    install_boot_shims ubuntu
    export FAKE_NEW_KERNEL="6.8.0-2.lbtest-azure" FAKE_NO_INITRAMFS=1 FAKE_BOOT_FREE_MB=2000
    local out

    bash "$SCRIPT" start all run12-vm1-1 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "succeeded"
    assert_file_contains "$FAKE_CALLS" "update-initramfs -c -k 6.8.0-2.lbtest-azure"
    assert_eq "$(grep '^apt-get ' "$FAKE_CALLS" | tail -n 1)" \
        "apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y --with-new-pkgs upgrade"

    export FAKE_DRACUT_FAIL=1
    rm -f /boot/initrd.img-6.8.0-2.lbtest-azure
    bash "$SCRIPT" start all run12-vm1-2 >/dev/null
    out=$(wait_for_run)
    assert_eq "$(marker "$out" STATE)" "failed"
    assert_eq "$(marker "$out" EXIT_CODE)" "5"
}

test_arguments_are_validated
test_status_without_a_run
test_dnf_run_detaches_and_succeeds
test_security_updates_only
test_a_run_in_progress_is_not_started_twice
test_a_failed_run_reports_why
test_yum_on_rhel7
test_apt_on_ubuntu
test_reboot_required_on_rhel
test_a_run_that_vanished_is_interrupted
test_a_damaged_state_file_is_ignored
test_systemd_runs_the_patch_as_a_transient_unit
test_no_package_manager
test_a_full_boot_keeps_two_kernels
test_a_missing_or_damaged_initramfs_is_rebuilt
test_a_kernel_that_cannot_boot_fails_the_run
test_ubuntu_rebuilds_a_missing_initrd

echo "patch-host.sh tests passed"
