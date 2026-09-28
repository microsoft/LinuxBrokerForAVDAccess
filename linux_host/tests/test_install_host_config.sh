#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/install-host-config.sh"
LOGROTATE_FILE="/etc/logrotate.d/linuxbroker"
RULE_FILE="/etc/udev/rules.d/99-nfs.rules"
TMPFILES_FILE="/etc/tmpfiles.d/linuxbroker.conf"
PROFILE_FILE="/etc/profile.d/linuxbroker-cache.sh"
CACHE_PARENT="/var/cache/linuxbroker"
CACHE_ROOT="$CACHE_PARENT/users"
LEGACY="/awipsprofiles"
MARKER="# Managed by the Linux Broker (install-host-config.sh)."
TEST_USER="lbtesthc1"
LOGS=(release-session release-session-watcher createuser linuxbroker-host-settings linuxbroker-session-control)
OUT=""
STATUS=0

# Everything the tests create. Whatever was there before is set aside and put back.
TOUCHED=("$LOGROTATE_FILE" "$RULE_FILE" "$TMPFILES_FILE" "$PROFILE_FILE" "$CACHE_PARENT" "$LEGACY" "$SHIM_DIR/udevadm")
UDEV_DIRECTORY_EXISTED=0
[ -d /etc/udev ] && UDEV_DIRECTORY_EXISTED=1

save_touched() {
    local path
    for path in "${TOUCHED[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            rm -rf "$path.lbtest-saved"
            mv "$path" "$path.lbtest-saved"
        fi
    done
}

restore_touched() {
    local path
    for path in "${TOUCHED[@]}"; do
        rm -rf "$path"
        if [ -e "$path.lbtest-saved" ] || [ -L "$path.lbtest-saved" ]; then
            mv "$path.lbtest-saved" "$path"
        fi
    done
    [ "$UDEV_DIRECTORY_EXISTED" -eq 1 ] || rm -rf /etc/udev
    cleanup_user "$TEST_USER"
}

save_touched
trap restore_touched EXIT

# A host with four NFS mounts: one at the kernel's 128 KiB, one already at 15 MiB, one whose
# device name is not major:minor, and one whose backing device has gone.
fake_nfs_mounts() {
    export LINUXBROKER_NFS_VOLUMES_FILE="$WORK_DIR/volumes"
    export LINUXBROKER_BDI_DIRECTORY="$WORK_DIR/bdi"
    mkdir -p "$WORK_DIR/bdi/0:52" "$WORK_DIR/bdi/0:53" "$WORK_DIR/outside"
    echo 128 > "$WORK_DIR/bdi/0:52/read_ahead_kb"
    echo 15360 > "$WORK_DIR/bdi/0:53/read_ahead_kb"
    echo 128 > "$WORK_DIR/outside/read_ahead_kb"
    cat > "$LINUXBROKER_NFS_VOLUMES_FILE" <<'EOF'
NV SERVER   PORT DEV          FSID                              FSC
v4 0a000004  801 0:52         7b1bcb0f6ec0bc49:0                no
v4 0a000004  801 0:53         7b1bcb0f6ec0bc49:1                no
v4 0a000005  801 ../outside   7b1bcb0f6ec0bc49:2                no
v4 0a000006  801 0:99         7b1bcb0f6ec0bc49:3                no
EOF
}

install_udevadm_shim() {
    cat > "$SHIM_DIR/udevadm" <<'SHIM'
#!/bin/bash
echo "udevadm $*" >> "${FAKE_CALLS:-/dev/null}"
exit "${FAKE_UDEVADM_STATUS:-0}"
SHIM
    chmod +x "$SHIM_DIR/udevadm"
}

setup_case() {
    local path
    for path in "${TOUCHED[@]}"; do
        rm -rf "$path"
    done
    reset_work
    install_basic_shims
    install_udevadm_shim
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    unset FAKE_MOUNTPOINT_STATUS FAKE_UDEVADM_STATUS
    fake_nfs_mounts
}

run_config() {
    OUT=$(bash "$SCRIPT" "$@" 2>&1)
    STATUS=$?
}

read_ahead() {
    cat "$WORK_DIR/$1/read_ahead_kb"
}

installed_files() {
    printf '%s\n' "$LOGROTATE_FILE" "$RULE_FILE" "$TMPFILES_FILE" "$PROFILE_FILE"
}

# The udevadm on this host other than the shim, if there is one.
real_udevadm() {
    local directory
    for directory in /usr/local/sbin /usr/sbin /usr/bin /sbin /bin; do
        if [ -x "$directory/udevadm" ]; then
            echo "$directory/udevadm"
            return 0
        fi
    done
    return 1
}

test_a_first_run_installs_everything() {
    local file log rule udevadm
    setup_case

    run_config
    assert_eq "$STATUS" "0" "first run: $OUT"
    assert_contains "$OUT" "Log rotation: wrote $LOGROTATE_FILE."
    assert_contains "$OUT" "NFS read-ahead: wrote $RULE_FILE."
    assert_contains "$OUT" "NFS read-ahead: set 15360 KiB on 1 NFS mount(s) that already existed."
    assert_contains "$OUT" "Local caches: wrote $TMPFILES_FILE."
    assert_contains "$OUT" "Local caches: $CACHE_ROOT is ready."
    assert_contains "$OUT" "Local caches: wrote $PROFILE_FILE."
    assert_contains "$OUT" "The Linux Broker host configuration is up to date."
    case "$OUT" in *ERROR*|*"Legacy mount root"*) fail "unexpected output: $OUT" ;; esac

    while IFS= read -r file; do
        assert_eq "$(stat -c '%a %U %G' "$file")" "644 root root" "$file"
        assert_eq "$(head -n 1 "$file")" "$MARKER Changes here are overwritten." "$file"
    done < <(installed_files)
    assert_eq "$(stat -c '%a %U %G' "$CACHE_PARENT")" "755 root root" "the cache parent"
    assert_eq "$(stat -c '%a %U %G' "$CACHE_ROOT")" "711 root root" "the cache root"
    assert_eq "$(find /etc/logrotate.d /etc/udev/rules.d /etc/tmpfiles.d /etc/profile.d -name '.*.??????' | wc -l | tr -d ' ')" \
        "0" "no temporary file is left"

    # udev is told about the new rule, and the mounts that already exist get the value.
    assert_file_contains "$FAKE_CALLS" "udevadm control --reload"
    assert_eq "$(read_ahead bdi/0:52)" "15360" "a mount at 128 KiB"
    assert_eq "$(read_ahead bdi/0:53)" "15360" "a mount already at 15 MiB"
    assert_eq "$(read_ahead outside)" "128" "a device name that is not major:minor"

    for log in "${LOGS[@]}"; do
        grep -qx "/var/log/$log.log" "$LOGROTATE_FILE" || fail "/var/log/$log.log is not rotated"
    done
    ! grep -q '^/var/log/linuxbroker-patch.log' "$LOGROTATE_FILE" || fail "patch-host.sh trims its own log"

    # The rule matches only NFS mounts. udev substitutes $kernel and reads $$ as a literal $;
    # any other $ is an invalid substitution that newer versions report when they load it.
    rule=$(grep -v '^#' "$RULE_FILE")
    assert_contains "$rule" 'SUBSYSTEM=="bdi", ACTION=="add"'
    assert_contains "$rule" "{if (\$\$4 == bdi) {ret=0}}"
    assert_contains "$rule" '/proc/fs/nfsfs/volumes", ATTR{read_ahead_kb}="15360"'
    rule=${rule//\$kernel/}
    rule=${rule//\$\$/}
    case "$rule" in *'$'*) fail "the rule has a \$ that udev does not substitute: $(grep -v '^#' "$RULE_FILE")" ;; esac
    if udevadm=$(real_udevadm) && "$udevadm" verify --help >/dev/null 2>&1; then
        "$udevadm" verify "$RULE_FILE" >"$WORK_DIR/verify.out" 2>&1 \
            || fail "udevadm verify rejects $RULE_FILE: $(cat "$WORK_DIR/verify.out")"
    fi

    assert_file_contains "$TMPFILES_FILE" "d /var/cache/linuxbroker 0755 root root -"
    assert_file_contains "$TMPFILES_FILE" "D /var/cache/linuxbroker/users 0711 root root -"
}

test_a_second_run_changes_nothing() {
    local file before after
    setup_case
    run_config
    assert_eq "$STATUS" "0" "first run: $OUT"
    before=$(while IFS= read -r file; do stat -c '%n %i %y %a' "$file"; done < <(installed_files))
    : > "$FAKE_CALLS"

    run_config
    assert_eq "$STATUS" "0" "second run: $OUT"
    after=$(while IFS= read -r file; do stat -c '%n %i %y %a' "$file"; done < <(installed_files))
    assert_eq "$after" "$before" "no file is rewritten"
    assert_contains "$OUT" "Log rotation: $LOGROTATE_FILE is up to date."
    assert_contains "$OUT" "NFS read-ahead: $RULE_FILE is up to date."
    assert_contains "$OUT" "Local caches: $TMPFILES_FILE is up to date."
    assert_contains "$OUT" "Local caches: $PROFILE_FILE is up to date."
    assert_contains "$OUT" "The Linux Broker host configuration is up to date."
    case "$OUT" in *"KiB on"*) fail "a mount already at 15 MiB was set again: $OUT" ;; esac
    assert_not_contains_file "$FAKE_CALLS" "udevadm"

    # A file that was changed by hand is put back.
    printf 'changed\n' >> "$PROFILE_FILE"
    chmod 600 "$PROFILE_FILE"
    run_config
    assert_contains "$OUT" "Local caches: wrote $PROFILE_FILE."
    assert_eq "$(stat -c '%a' "$PROFILE_FILE")" "644" "the mode is put back"
    assert_not_contains_file "$PROFILE_FILE" "changed"

    # So is one whose mode alone was changed, which would hide it from users.
    chmod 600 "$TMPFILES_FILE"
    run_config
    assert_contains "$OUT" "Local caches: wrote $TMPFILES_FILE."
    assert_eq "$(stat -c '%a %U' "$TMPFILES_FILE")" "644 root" "a mode alone is put back"
}

test_a_rule_an_administrator_wrote_is_left_alone() {
    local own='SUBSYSTEM=="bdi", ACTION=="add", ATTR{read_ahead_kb}="4096"'
    setup_case
    mkdir -p "$(dirname "$RULE_FILE")"
    printf '%s\n' "$own" > "$RULE_FILE"

    run_config
    assert_eq "$STATUS" "0" "$OUT"
    assert_contains "$OUT" "NFS read-ahead: left $RULE_FILE alone, because the Linux Broker did not write it."
    assert_eq "$(cat "$RULE_FILE")" "$own"
    assert_not_contains_file "$FAKE_CALLS" "udevadm"
    assert_eq "$(read_ahead bdi/0:52)" "128" "the mounts keep the administrator's value"

    # One this script wrote earlier is brought up to date.
    printf '%s Changes here are overwritten.\nSUBSYSTEM=="bdi", ACTION=="add", ATTR{read_ahead_kb}="1024"\n' "$MARKER" > "$RULE_FILE"
    run_config
    assert_eq "$STATUS" "0" "$OUT"
    assert_contains "$OUT" "NFS read-ahead: wrote $RULE_FILE."
    assert_file_contains "$RULE_FILE" 'ATTR{read_ahead_kb}="15360"'
    assert_file_contains "$FAKE_CALLS" "udevadm control --reload"
    assert_eq "$(read_ahead bdi/0:52)" "15360"
}

test_udev_and_nfs_problems_do_not_fail_the_run() {
    setup_case
    export FAKE_UDEVADM_STATUS=1
    run_config
    unset FAKE_UDEVADM_STATUS
    assert_eq "$STATUS" "0" "a failed reload: $OUT"
    assert_contains "$OUT" "NFS read-ahead: udevadm control --reload failed; udev loads the rule when the host restarts."
    assert_eq "$(read_ahead bdi/0:52)" "15360" "the mounts still get the value"

    if real_udevadm >/dev/null; then
        echo "Skipping the case without udevadm, which this host has."
    else
        setup_case
        rm -f "$SHIM_DIR/udevadm"
        run_config
        assert_eq "$STATUS" "0" "no udevadm: $OUT"
        assert_contains "$OUT" "NFS read-ahead: udevadm was not found, so udev was not asked to reload its rules."
        assert_file_exists "$RULE_FILE"
    fi

    # A host with no NFS mount yet.
    setup_case
    export LINUXBROKER_NFS_VOLUMES_FILE="$WORK_DIR/missing"
    run_config
    assert_eq "$STATUS" "0" "no NFS mounts: $OUT"
    case "$OUT" in *"KiB on"*) fail "no mount should have been set: $OUT" ;; esac
    assert_eq "$(read_ahead bdi/0:52)" "128"
}

test_the_legacy_mount_root_is_removed_only_when_empty() {
    setup_case
    mkdir "$LEGACY"
    run_config
    assert_eq "$STATUS" "0" "$OUT"
    assert_not_exists "$LEGACY"
    assert_contains "$OUT" "Legacy mount root: removed the empty $LEGACY; the share is mounted on /nfs_profiles now."

    setup_case
    mkdir -p "$LEGACY/someone"
    run_config
    assert_file_exists "$LEGACY/someone"
    assert_contains "$OUT" "Legacy mount root: left $LEGACY alone, because it is not empty."

    setup_case
    mkdir "$LEGACY"
    : > "$LEGACY/.hidden"
    run_config
    assert_file_exists "$LEGACY/.hidden"
    assert_contains "$OUT" "because it is not empty."

    setup_case
    mkdir "$LEGACY"
    export FAKE_MOUNTPOINT_STATUS=0
    run_config
    unset FAKE_MOUNTPOINT_STATUS
    assert_file_exists "$LEGACY"
    assert_contains "$OUT" "Legacy mount root: left $LEGACY alone, because something is mounted on it."

    setup_case
    mkdir -p "$WORK_DIR/target"
    ln -s "$WORK_DIR/target" "$LEGACY"
    run_config
    [ -L "$LEGACY" ] || fail "the link was removed"
    assert_file_exists "$WORK_DIR/target"
    assert_contains "$OUT" "Legacy mount root: left $LEGACY alone, because it is not a directory."

    setup_case
    printf 'not a directory\n' > "$LEGACY"
    run_config
    assert_file_exists "$LEGACY"
    assert_contains "$OUT" "because it is not a directory."
    assert_eq "$STATUS" "0" "$OUT"
}

test_a_failed_step_fails_the_run() {
    setup_case
    printf 'not a directory\n' > "$CACHE_PARENT"
    run_config
    assert_eq "$STATUS" "1" "$OUT"
    assert_contains "$OUT" "ERROR: Local caches: could not prepare $CACHE_ROOT."
    assert_contains "$OUT" "The Linux Broker host configuration is incomplete; run install-host-config.sh again as root."
    # The other steps still ran.
    assert_file_exists "$LOGROTATE_FILE"
    assert_file_exists "$RULE_FILE"
    assert_file_exists "$PROFILE_FILE"
}

test_usage_and_root() {
    local copy
    setup_case
    run_config --help
    assert_eq "$STATUS" "2" "an argument"
    assert_contains "$OUT" "Usage:"
    assert_not_exists "$LOGROTATE_FILE"

    copy=$(mktemp -d)
    cp "$SCRIPT" "$copy/install-host-config.sh"
    chmod 755 "$copy" "$copy/install-host-config.sh"
    OUT=$(cd / && runuser -u nobody -- bash "$copy/install-host-config.sh" 2>&1)
    STATUS=$?
    rm -rf "$copy"
    assert_eq "$STATUS" "1" "not root"
    assert_contains "$OUT" "install-host-config.sh must run as root."
    assert_not_exists "$LOGROTATE_FILE"
}

test_the_cache_is_emptied_at_boot() {
    if ! command -v systemd-tmpfiles >/dev/null 2>&1; then
        echo "Skipping the tmpfiles case: systemd-tmpfiles is not installed."
        return 0
    fi
    setup_case
    run_config
    assert_eq "$STATUS" "0" "$OUT"
    mkdir -p "$CACHE_ROOT/someone/fontconfig"
    : > "$CACHE_ROOT/someone/fontconfig/cache-1"
    touch -d '30 days ago' "$CACHE_ROOT/someone/fontconfig/cache-1" "$CACHE_ROOT/someone/fontconfig" "$CACHE_ROOT/someone"

    # The daily clean-up leaves a cache in use alone, however old.
    systemd-tmpfiles --clean "$TMPFILES_FILE" >/dev/null 2>&1 || fail "systemd-tmpfiles --clean failed"
    assert_file_exists "$CACHE_ROOT/someone/fontconfig/cache-1"

    # What systemd-tmpfiles-setup.service runs at boot.
    systemd-tmpfiles --create --remove --boot "$TMPFILES_FILE" >/dev/null 2>&1 || fail "systemd-tmpfiles --boot failed"
    assert_not_exists "$CACHE_ROOT/someone"
    assert_eq "$(stat -c '%a %U %G' "$CACHE_ROOT")" "711 root root" "the cache root stays"

    rm -rf "$CACHE_PARENT"
    systemd-tmpfiles --create "$TMPFILES_FILE" >/dev/null 2>&1 || fail "systemd-tmpfiles --create failed"
    assert_eq "$(stat -c '%a %U %G' "$CACHE_PARENT")" "755 root root" "the cache parent is created"
    assert_eq "$(stat -c '%a %U %G' "$CACHE_ROOT")" "711 root root" "the cache root is created"
}

# Prints XDG_CACHE_HOME, and whether the script's own variables are left behind, after a shell
# running as $1 sources the profile script. The rest are NAME=VALUE pairs for its environment.
login_shell_cache() {
    local user="$1" shell="$2"
    shift 2
    # shellcheck disable=SC2016 # expanded by the inner shell
    (cd / && runuser -u "$user" -- env -i PATH=/usr/bin:/bin "$@" "$shell" -c \
        '. "$1"; printf "%s|%s|%s" "${XDG_CACHE_HOME:-}" "${linuxbroker_user-unset}" "${linuxbroker_cache-unset}"' \
        profile "$PROFILE_FILE")
}

test_login_shells_use_the_local_cache() {
    local cache="$CACHE_ROOT/$TEST_USER" shell target
    setup_case
    run_config
    assert_eq "$STATUS" "0" "$OUT"
    cleanup_user "$TEST_USER"
    useradd -M -s /bin/bash -u 21101 "$TEST_USER" || fail "could not create $TEST_USER"

    for shell in dash bash; do
        rm -rf "$cache"
        assert_eq "$(login_shell_cache "$TEST_USER" "$shell")" "|unset|unset" "$shell without a cache"

        mkdir -m 700 "$cache"
        chown "$TEST_USER:$TEST_USER" "$cache"
        assert_eq "$(login_shell_cache "$TEST_USER" "$shell")" "$cache|unset|unset" "$shell with a cache"
        assert_eq "$(login_shell_cache "$TEST_USER" "$shell" XDG_CACHE_HOME=/srv/cache)" "/srv/cache|unset|unset" \
            "$shell keeps a value already set"

        chown root:root "$cache"
        assert_eq "$(login_shell_cache "$TEST_USER" "$shell")" "|unset|unset" "$shell with a cache root owns"

        rm -rf "$cache"
        target=$(mktemp -d)
        chmod 700 "$target"
        chown "$TEST_USER:$TEST_USER" "$target"
        ln -s "$target" "$cache"
        assert_eq "$(login_shell_cache "$TEST_USER" "$shell")" "|unset|unset" "$shell with a link"
        rm -rf "$cache" "$target"
    done

    # Root has no broker cache, and a shell that treats unset variables as errors is fine.
    assert_eq "$(login_shell_cache root dash)" "|unset|unset" "root"
    mkdir -m 700 "$cache"
    chown "$TEST_USER:$TEST_USER" "$cache"
    # shellcheck disable=SC2016 # expanded by the inner shell
    OUT=$(cd / && runuser -u "$TEST_USER" -- env -i PATH=/usr/bin:/bin dash -u -c '. "$1"; echo "$XDG_CACHE_HOME"' \
        profile "$PROFILE_FILE" 2>&1) || fail "the profile script fails under set -u: $OUT"
    assert_eq "$OUT" "$cache" "set -u"
}

test_logs_rotate_with_their_owner_and_mode() {
    local log directory="$WORK_DIR/log"
    if ! command -v logrotate >/dev/null 2>&1; then
        echo "Skipping the log rotation case: logrotate is not installed."
        return 0
    fi
    setup_case
    run_config
    assert_eq "$STATUS" "0" "$OUT"
    logrotate -d -s "$WORK_DIR/debug.state" "$LOGROTATE_FILE" >"$WORK_DIR/logrotate-debug.out" 2>&1 \
        || fail "logrotate rejects $LOGROTATE_FILE: $(cat "$WORK_DIR/logrotate-debug.out")"

    # The same configuration, pointed at a scratch directory.
    mkdir -p "$directory"
    sed "s|^/var/log/|$directory/|" "$LOGROTATE_FILE" > "$WORK_DIR/logrotate.conf"
    for log in "${LOGS[@]}"; do
        printf '2026-01-01 00:00:00 - a line\n' > "$directory/$log.log"
        chmod 600 "$directory/$log.log"
    done
    chown root:adm "$directory/createuser.log"
    chmod 640 "$directory/createuser.log"
    printf 'patch\n' > "$directory/linuxbroker-patch.log"

    logrotate -f -s "$WORK_DIR/logrotate.state" "$WORK_DIR/logrotate.conf" >"$WORK_DIR/logrotate.out" 2>&1 \
        || fail "logrotate failed: $(cat "$WORK_DIR/logrotate.out")"
    for log in "${LOGS[@]}"; do
        assert_file_contains "$directory/$log.log.1" "a line"
        [ ! -s "$directory/$log.log" ] || fail "$log.log was not emptied"
    done
    assert_eq "$(stat -c '%a %U %G' "$directory/release-session.log")" "600 root root" "a new log keeps the mode"
    assert_eq "$(stat -c '%a %U %G' "$directory/createuser.log")" "640 root adm" "a new log keeps the owner"
    assert_not_exists "$directory/linuxbroker-patch.log.1"
}

test_a_first_run_installs_everything
test_a_second_run_changes_nothing
test_a_rule_an_administrator_wrote_is_left_alone
test_udev_and_nfs_problems_do_not_fail_the_run
test_the_legacy_mount_root_is_removed_only_when_empty
test_a_failed_step_fails_the_run
test_usage_and_root
test_the_cache_is_emptied_at_boot
test_login_shells_use_the_local_cache
test_logs_rotate_with_their_owner_and_mode

echo "install-host-config.sh tests passed"
