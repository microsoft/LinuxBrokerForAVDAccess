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
    mkdir -p /nfs_profiles /var/lib/linuxbroker-release-session/leases
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
    assert_eq "$(getent passwd "$user" | cut -d: -f7)" "/bin/bash" "login shell"
    id -nG "$user" | grep -qw tsusers || fail "missing tsusers membership"
    id -nG "$user" | grep -qw appusers || fail "missing appusers membership"
    shadow_after=$(getent shadow "$user")
    [ "$shadow_before" != "$shadow_after" ] || fail "shadow hash did not change"
    lease_file="/var/lib/linuxbroker-release-session/leases/$user.lease"
    assert_file_exists "$lease_file"
    assert_eq "$(cat "$lease_file")" "$LEASE"
    assert_eq "$(stat -c %a "$lease_file")" "600"
    assert_not_contains_file /var/log/createuser.log 'S3cret!pass'
    assert_file_contains "$FAKE_CALLS" "mount -t nfs nfs.example:/profiles /nfs_profiles"
    assert_file_contains "$FAKE_CALLS" "umount /nfs_profiles"
    assert_file_contains /var/log/createuser.log "Mount NFS root on /nfs_profiles"
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
    assert_eq "$(getent passwd "$user" | cut -d: -f7)" "/bin/bash" "login shell"
    assert_eq "$(cat "/var/lib/linuxbroker-release-session/leases/$user.lease")" "$LEASE"
    # Only the broker that sends the password on stdin gets a local cache.
    assert_not_exists "/var/cache/linuxbroker/users/$user"
    cleanup_user "$user"
}

# Ubuntu users that an earlier version created have /bin/sh; any other shell is left alone.
existing_users_get_bash_instead_of_sh() {
    local user="lbtestcu8" other="lbtestcu9"
    setup_case
    cleanup_user "$user"
    cleanup_user "$other"
    useradd -d "/home/$user" -u 21008 -U -s /bin/sh "$user" -M
    useradd -d "/home/$other" -u 21009 -U -s /usr/bin/dash "$other" -M

    printf 'pw1\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21008 "$user" "$LEASE" >/dev/null \
        || fail "the existing user was not prepared"
    assert_eq "$(getent passwd "$user" | cut -d: -f7)" "/bin/bash" "switched from /bin/sh"
    assert_file_contains /var/log/createuser.log "Changed the login shell of $user from /bin/sh to /bin/bash."

    printf 'pw2\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21009 "$other" "$LEASE" >/dev/null \
        || fail "the other user was not prepared"
    assert_eq "$(getent passwd "$other" | cut -d: -f7)" "/usr/bin/dash" "a chosen shell"
    cleanup_user "$user"
    cleanup_user "$other"
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

# The broker sends the user's keyring key on a second line, for the xrdp session launcher.
keyring_key_is_left_for_the_session() {
    local user="lbtestcu10" key="Lbt3stKeyringKey_AAAAAAAAAAAAAAAAAAAAAAAAAA" key_file out
    local saved=""
    setup_case
    cleanup_user "$user"
    if [ -e /run/linuxbroker-keyring ]; then
        saved="/run/linuxbroker-keyring.lbtest-saved"
        rm -rf "$saved"
        mv /run/linuxbroker-keyring "$saved"
    fi
    key_file="/run/linuxbroker-keyring/$user"

    out=$(printf 'pw\n%s\n' "$key" | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE") \
        || fail "provisioning with a keyring key failed"
    assert_contains "$out" "__CREATE_USER_RESULT=ok__"
    assert_eq "$(cat "$key_file")" "$key"
    assert_eq "$(stat -c '%a %U' "$key_file")" "400 $user"
    assert_eq "$(stat -c '%a %U' /run/linuxbroker-keyring)" "711 root"
    assert_eq "$(find /run/linuxbroker-keyring -name ".$user.*" | wc -l | tr -d ' ')" "0" "no temporary file is left"
    assert_not_contains_file /var/log/createuser.log "$key"

    # A reconnect sends the same key again; a new one replaces it.
    printf 'pw\n%s\n' "${key/A/B}" | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE" >/dev/null \
        || fail "provisioning with a new keyring key failed"
    assert_eq "$(cat "$key_file")" "${key/A/B}"

    # Anything that is not a key is ignored, and removes the old one.
    for bad in "short" "has space in it, which no key has" "$(printf 'x%.0s' {1..129})"; do
        printf 'pw\n%s\n' "$key" | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE" >/dev/null
        printf 'pw\n%s\n' "$bad" | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE" >/dev/null \
            || fail "a malformed keyring key failed the checkout"
        assert_not_exists "$key_file"
    done
    assert_file_contains /var/log/createuser.log "Ignoring a keyring key for $user that is not a valid key."

    # A broker without a keyring vault sends none, which also removes a key left earlier.
    printf 'pw\n%s\n' "$key" | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE" >/dev/null
    printf 'pw\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles 21010 "$user" "$LEASE" >/dev/null \
        || fail "provisioning without a keyring key failed"
    assert_not_exists "$key_file"

    cleanup_user "$user"
    rm -rf /run/linuxbroker-keyring
    if [ -n "$saved" ]; then
        mv "$saved" /run/linuxbroker-keyring
    fi
}

provision() {
    printf 'pw\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles "$2" "$1" "$LEASE" >/dev/null \
        || fail "provisioning $1 failed"
}

# Each user gets a cache on the local disk for the xrdp session launcher. Only root can add
# entries to its parent, so one the user owns is kept for a reconnect and anything else is
# replaced.
local_cache_is_prepared_for_the_session() {
    local user="lbtestcu11" uid="21011" cache="/var/cache/linuxbroker/users/lbtestcu11" saved="" out
    setup_case
    cleanup_user "$user"
    if [ -e /var/cache/linuxbroker ]; then
        saved="/var/cache/linuxbroker.lbtest-saved"
        rm -rf "$saved"
        mv /var/cache/linuxbroker "$saved"
    fi

    provision "$user" "$uid"
    assert_eq "$(stat -c '%a %U %G' "$cache")" "700 $user $user" "a new cache"
    assert_eq "$(stat -c '%a %U %G' /var/cache/linuxbroker)" "755 root root" "the cache parent"
    assert_eq "$(stat -c '%a %U %G' /var/cache/linuxbroker/users)" "711 root root" "the cache root"
    assert_file_contains /var/log/createuser.log "Created the local cache of $user in $cache."

    # A reconnect keeps what the session cached.
    mkdir -p "$cache/fontconfig"
    printf 'cached\n' > "$cache/fontconfig/cache-1"
    chown -R "$user:$user" "$cache/fontconfig"
    chmod 755 "$cache"
    : > /var/log/createuser.log
    provision "$user" "$uid"
    assert_eq "$(cat "$cache/fontconfig/cache-1")" "cached" "a reconnect keeps the cache"
    assert_eq "$(stat -c '%a %U' "$cache")" "700 $user" "a reconnect restores the mode"
    assert_not_contains_file /var/log/createuser.log "Created the local cache"
    assert_not_contains_file /var/log/createuser.log "Replacing"

    # A link, a file, or a directory someone else owns is replaced, and a link is not followed.
    mkdir -p "$WORK_DIR/elsewhere"
    printf 'keep\n' > "$WORK_DIR/elsewhere/file"
    chown -R "$user:$user" "$WORK_DIR/elsewhere"
    chmod 700 "$WORK_DIR/elsewhere"
    rm -rf "$cache"
    ln -s "$WORK_DIR/elsewhere" "$cache"
    chown -h "$user:$user" "$cache"
    provision "$user" "$uid"
    [ ! -L "$cache" ] || fail "the link was kept"
    assert_eq "$(stat -c '%a %U' "$cache")" "700 $user" "a link is replaced"
    assert_eq "$(cat "$WORK_DIR/elsewhere/file")" "keep" "the link target is left alone"
    assert_file_contains /var/log/createuser.log "Replacing $cache, which was not a directory that $user owns."

    rm -rf "$cache"
    printf 'not a directory\n' > "$cache"
    provision "$user" "$uid"
    assert_eq "$(stat -c '%F %a %U' "$cache")" "directory 700 $user" "a file is replaced"

    rm -rf "$cache"
    mkdir -p "$cache"
    printf 'planted\n' > "$cache/planted"
    chown -R nobody "$cache"
    provision "$user" "$uid"
    assert_eq "$(stat -c '%a %U' "$cache")" "700 $user" "a directory someone else owns is replaced"
    assert_not_exists "$cache/planted"

    # Loose modes on the parents are put back.
    chmod 777 /var/cache/linuxbroker /var/cache/linuxbroker/users
    provision "$user" "$uid"
    assert_eq "$(stat -c '%a' /var/cache/linuxbroker)" "755" "the cache parent mode is restored"
    assert_eq "$(stat -c '%a' /var/cache/linuxbroker/users)" "711" "the cache root mode is restored"

    # Without a cache the session keeps its caches in the home directory, so the checkout
    # still succeeds.
    rm -rf /var/cache/linuxbroker
    printf 'not a directory\n' > /var/cache/linuxbroker
    out=$(printf 'pw\n' | bash "$SCRIPT" --password-stdin nfs.example:/profiles "$uid" "$user" "$LEASE") \
        || fail "a checkout without a cache failed"
    assert_contains "$out" "__CREATE_USER_RESULT=ok__"
    assert_file_contains /var/log/createuser.log "so the cache of $user stays in the home directory."

    cleanup_user "$user"
    rm -rf /var/cache/linuxbroker
    if [ -n "$saved" ]; then
        mv "$saved" /var/cache/linuxbroker
    fi
}

new_form_success
validation_failures
mount_failure
legacy_form_still_works
existing_users_get_bash_instead_of_sh
legacy_fixture_rejects_new_form
keyring_key_is_left_for_the_session
local_cache_is_prepared_for_the_session