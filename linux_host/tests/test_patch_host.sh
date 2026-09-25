#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/patch-host.sh"
STATE_DIR="/var/lib/linuxbroker-release-session"
STATE_FILE="$STATE_DIR/patch-state"
LOG_FILE="/var/log/linuxbroker-patch.log"
MANAGER_SHIMS=(dnf yum apt-get unattended-upgrade needs-restarting systemd-run)
MADE_SYSTEMD_DIR=0
HID_APT_GET=0

remove_shims() {
    local name
    for name in "${MANAGER_SHIMS[@]}"; do
        rm -f "$SHIM_DIR/$name"
    done
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
# while FAKE_PM_HOLD names a file, so a test can see a run in progress.
install_manager() {
    local name="$1"
    cat > "$SHIM_DIR/$name" <<'SHIM'
#!/bin/bash
echo "$(basename "$0") $*" >> "${FAKE_CALLS:-/dev/null}"
while [ -n "${FAKE_PM_HOLD:-}" ] && [ -e "$FAKE_PM_HOLD" ]; do sleep 0.2; done
if [ -n "${FAKE_PM_FAIL:-}" ]; then
  echo "Error: Failed to download metadata for repo 'rhel-9-baseos'"
  exit 1
fi
echo "Complete!"
SHIM
    chmod +x "$SHIM_DIR/$name"
}

setup_case() {
    remove_shims
    reset_work
    rm -f "$STATE_FILE" "$STATE_DIR/patch.lock" "$STATE_DIR/patch-run.lock" "$LOG_FILE"
    mkdir -p "$STATE_DIR"
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    unset FAKE_PM_FAIL FAKE_PM_HOLD
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

echo "patch-host.sh tests passed"
