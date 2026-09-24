#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/create-user.sh"
LEGACY="$ROOT_DIR/linux_host/tests/fixtures/create-user.legacy.sh"
LEASE="11111111-2222-3333-4444-555555555555"

setup_case() {
    reset_work
    install_basic_shims
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    mkdir -p /awipsprofiles /var/lib/linuxbroker-release-session/leases
    rm -f /var/log/createuser.log
}

new_form_success() {
    local user="lbtestcu1" uid="21001" out shadow_before shadow_after lease_file
    setup_case
    cleanup_user "$user"
    shadow_before=$(getent shadow "$user" || true)

    out=$(printf 'S3cret!pass\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles "$uid" "$user" "$LEASE") || fail "new form failed"

    assert_contains "$out" "__CREATE_USER_RESULT=ok__"
    assert_eq "$(id -u "$user")" "$uid"
    id -nG "$user" | grep -qw tsusers || fail "missing tsusers membership"
    id -nG "$user" | grep -qw appusers || fail "missing appusers membership"
    shadow_after=$(getent shadow "$user")
    [ "$shadow_before" != "$shadow_after" ] || fail "shadow hash did not change"
    lease_file="/var/lib/linuxbroker-release-session/leases/$user.lease"
    assert_file_exists "$lease_file"
    assert_eq "$(cat "$lease_file")" "$LEASE"
    assert_eq "$(stat -c %a "$lease_file")" "600"
    assert_not_contains_file /var/log/createuser.log 'S3cret!pass'
    assert_file_contains "$FAKE_CALLS" "umount /awipsprofiles"
    cleanup_user "$user"
}

validation_failures() {
    local out user
    setup_case
    for spec in \
        "bad-name 21002 bad-user $LEASE Invalid username." \
        "bad-uid 999 lbtestcu2 $LEASE Invalid UID." \
        "bad-lease 21003 lbtestcu3 not-a-guid Invalid lease id."
    do
        set -- $spec
        user="$3"
        cleanup_user "$user"
        if out=$(printf 'pw\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles "$2" "$3" "$4" 2>&1); then
            fail "$1 unexpectedly succeeded"
        fi
        assert_contains "$out" "$5"
        ! id "$user" >/dev/null 2>&1 || fail "$user should not exist"
    done

    user="lbtestcu4"
    cleanup_user "$user"
    if out=$(bash "$SCRIPT" --password-stdin nfs.example:/profiles 21004 "$user" "$LEASE" 2>&1 </dev/null); then
        fail "missing password unexpectedly succeeded"
    fi
    assert_contains "$out" "Password was not supplied on stdin."
    ! id "$user" >/dev/null 2>&1 || fail "$user should not exist"
    cleanup_user "$user"
}

mount_failure() {
    local out user="lbtestcu5"
    setup_case
    cleanup_user "$user"
    export FAKE_MOUNT_FAIL=1
    if out=$(printf 'pw\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21005 "$user" "$LEASE" 2>&1); then
        fail "mount failure unexpectedly succeeded"
    fi
    unset FAKE_MOUNT_FAIL
    assert_contains "$out" "Failed to mount NFS share"
    ! id "$user" >/dev/null 2>&1 || fail "$user should not exist"
}

legacy_form_still_works() {
    local user="lbtestcu6"
    setup_case
    cleanup_user "$user"
    bash "$SCRIPT" nfs.example:/profiles 21006 "$user" "$LEASE"
    assert_eq "$(id -u "$user")" "21006"
    assert_eq "$(cat "/var/lib/linuxbroker-release-session/leases/$user.lease")" "$LEASE"
    cleanup_user "$user"
}

legacy_fixture_rejects_new_form() {
    local out user="lbtestcu7"
    setup_case
    cleanup_user "$user"
    if out=$(bash "$LEGACY" --password-stdin nfs.example:/profiles 21007 "$user" "$LEASE" 2>&1); then
        fail "legacy fixture accepted new form"
    fi
    assert_contains "$out" "Usage:"
    ! id "$user" >/dev/null 2>&1 || fail "$user should not exist"
}

new_form_success
validation_failures
mount_failure
legacy_form_still_works
legacy_fixture_rejects_new_form