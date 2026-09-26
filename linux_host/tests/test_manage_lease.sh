#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/manage-lease.sh"
LEASE_DIR="/var/lib/linuxbroker-release-session/leases"
LEASE="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
KEY_FILE="/run/linuxbroker-keyring/lbmluser"

setup_case() {
    reset_work
    install_basic_shims
    install_loginctl_shim
    install_process_shims
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    mkdir -p "$LEASE_DIR" /home/lbmluser /run/linuxbroker-keyring
    rm -f "$LEASE_DIR"/*.lease
    # The keyring key create-user.sh left at checkout.
    printf 'Lbt3stKeyringKey_AAAAAAAAAAAAAAAA\n' > "$KEY_FILE"
}

write_lease() { printf '%s\n' "$LEASE" > "$LEASE_DIR/$1.lease"; }

assert_call_before() {
    local first="$1"
    local second="$2"
    local first_line
    local second_line

    first_line=$(grep -nF "$first" "$FAKE_CALLS" | head -n 1 | cut -d: -f1)
    second_line=$(grep -nF "$second" "$FAKE_CALLS" | head -n 1 | cut -d: -f1)
    [ -n "$first_line" ] || fail "missing call: $first"
    [ -n "$second_line" ] || fail "missing call: $second"
    [ "$first_line" -lt "$second_line" ] || fail "$first did not run before $second"
}

setup_case
write_lease lbmluser
assert_eq "$(bash "$SCRIPT" read lbmluser)" "$LEASE"

setup_case
write_lease lbmluser
export FAKE_LOGINCTL_STATE=active
out=$(bash "$SCRIPT" clear lbmluser "$LEASE")
assert_contains "$out" "__LEASE_ACTION=in-use__"
assert_file_exists "$LEASE_DIR/lbmluser.lease"
assert_file_exists "$KEY_FILE"
! grep -Fq "loginctl terminate-user lbmluser" "$FAKE_CALLS" || fail "signed-in user should not be terminated"
! grep -Fq "pkill -KILL -u lbmluser" "$FAKE_CALLS" || fail "signed-in user processes should not be killed"
unset FAKE_LOGINCTL_STATE

setup_case
write_lease lbmluser
printf '0\n1\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
out=$(bash "$SCRIPT" clear lbmluser "$LEASE")
unset FAKE_MOUNTPOINT_SEQUENCE
assert_contains "$out" "__LEASE_ACTION=cleared__"
assert_not_exists "$LEASE_DIR/lbmluser.lease"
assert_not_exists "$KEY_FILE"
assert_call_before "loginctl terminate-user lbmluser" "umount -l /home/lbmluser"
assert_call_before "pkill -KILL -u lbmluser" "umount -l /home/lbmluser"

setup_case
write_lease lbmluser
printf '0\n1\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
out=$(bash "$SCRIPT" clear-any lbmluser)
unset FAKE_MOUNTPOINT_SEQUENCE
assert_contains "$out" "__LEASE_ACTION=cleared__"
assert_not_exists "$LEASE_DIR/lbmluser.lease"
assert_not_exists "$KEY_FILE"
assert_call_before "loginctl terminate-user lbmluser" "umount -l /home/lbmluser"
assert_call_before "pkill -KILL -u lbmluser" "umount -l /home/lbmluser"

setup_case
write_lease lbmluser
out=$(bash "$SCRIPT" clear lbmluser "ffffffff-1111-2222-3333-444444444444")
assert_contains "$out" "__LEASE_ACTION=mismatch__"
assert_file_exists "$LEASE_DIR/lbmluser.lease"
assert_file_exists "$KEY_FILE"

setup_case
out=$(bash "$SCRIPT" clear lbmluser "$LEASE")
assert_contains "$out" "__LEASE_ACTION=missing__"

if bash "$SCRIPT" read '../bad' >/dev/null 2>&1; then fail "invalid username accepted"; fi
if bash "$SCRIPT" clear lbmluser not-a-guid >/dev/null 2>&1; then fail "invalid lease accepted"; fi
rm -rf /run/linuxbroker-keyring