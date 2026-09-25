#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/session-control.sh"
LEASE_DIR="/var/lib/linuxbroker-release-session/leases"
SHARE="nfsaccount.file.core.windows.net:/nfsaccount/home"
BROKER_USER="lbscuser"
PLAIN_USER="lbscplain"
SYSTEM_USER="lbscsystem"

install_session_shims() {
    # pgrep answers from a sequence, so a test can show processes that go away.
    cat > "$SHIM_DIR/pgrep" <<'SHIM'
#!/bin/bash
echo "pgrep $*" >> "${FAKE_CALLS:-/dev/null}"
if [ -n "${FAKE_PGREP_SEQUENCE:-}" ] && [ -s "$FAKE_PGREP_SEQUENCE" ]; then
  status=$(head -n 1 "$FAKE_PGREP_SEQUENCE")
  tail -n +2 "$FAKE_PGREP_SEQUENCE" > "$FAKE_PGREP_SEQUENCE.next"
  mv "$FAKE_PGREP_SEQUENCE.next" "$FAKE_PGREP_SEQUENCE"
  exit "$status"
fi
exit "${FAKE_PGREP_STATUS:-1}"
SHIM
    cat > "$SHIM_DIR/runuser" <<'SHIM'
#!/bin/bash
echo "runuser $*" >> "${FAKE_CALLS:-/dev/null}"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
SHIM
    cat > "$SHIM_DIR/notify-send" <<'SHIM'
#!/bin/bash
printf 'notify-send' >> "${FAKE_CALLS:-/dev/null}"
printf ' [%s]' "$@" >> "${FAKE_CALLS:-/dev/null}"
printf ' DISPLAY=%s DBUS=%s\n' "${DISPLAY:-}" "${DBUS_SESSION_BUS_ADDRESS:-}" >> "${FAKE_CALLS:-/dev/null}"
exit "${FAKE_NOTIFY_STATUS:-0}"
SHIM
    cat > "$SHIM_DIR/xmessage" <<'SHIM'
#!/bin/bash
printf 'xmessage' >> "${FAKE_CALLS:-/dev/null}"
printf ' [%s]' "$@" >> "${FAKE_CALLS:-/dev/null}"
printf '\n' >> "${FAKE_CALLS:-/dev/null}"
SHIM
    # Stands in for the NFS mount: it can populate the "share" with a profile to reset.
    cat > "$SHIM_DIR/mount" <<'SHIM'
#!/bin/bash
echo "mount $*" >> "${FAKE_CALLS:-/dev/null}"
[ "${FAKE_MOUNT_FAIL:-0}" = "1" ] && exit 32
target="$4"
echo "$target" > "${FAKE_MOUNT_TARGET:-/dev/null}"
case "${FAKE_PROFILE_FIXTURE:-}" in
  directory) mkdir -p "$target/$FAKE_PROFILE_USER" && echo keep > "$target/$FAKE_PROFILE_USER/marker" ;;
  symlink) ln -s /etc "$target/$FAKE_PROFILE_USER" ;;
  file) echo not-a-directory > "$target/$FAKE_PROFILE_USER" ;;
esac
exit 0
SHIM
    chmod +x "$SHIM_DIR/pgrep" "$SHIM_DIR/runuser" "$SHIM_DIR/notify-send" "$SHIM_DIR/xmessage" "$SHIM_DIR/mount"
}

ensure_users() {
    groupadd -f tsusers
    id "$BROKER_USER" >/dev/null 2>&1 || useradd -u 3102 -M -G tsusers "$BROKER_USER"
    id "$PLAIN_USER" >/dev/null 2>&1 || useradd -u 3101 -M "$PLAIN_USER"
    id "$SYSTEM_USER" >/dev/null 2>&1 || useradd -r -M -G tsusers "$SYSTEM_USER"
}

setup_case() {
    reset_work
    install_basic_shims
    install_loginctl_shim
    install_ps_shim
    install_process_shims
    install_session_shims
    ensure_users
    export FAKE_CALLS="$WORK_DIR/calls.log"
    export FAKE_PS_XORG="$WORK_DIR/xorg.txt"
    export FAKE_MOUNT_TARGET="$WORK_DIR/mount-target"
    : > "$FAKE_CALLS"
    : > "$FAKE_PS_XORG"
    unset FAKE_PGREP_SEQUENCE FAKE_PGREP_STATUS FAKE_NOTIFY_STATUS FAKE_MOUNT_FAIL FAKE_PROFILE_FIXTURE FAKE_MOUNTPOINT_SEQUENCE
    export FAKE_PROFILE_USER="$BROKER_USER"
    mkdir -p "$LEASE_DIR"
    rm -f "$LEASE_DIR"/*.lease
    rm -rf /run/linuxbroker/profile-reset.*
}

expect_status() {
    local expected="$1"
    local label="$2"
    shift 2
    local status

    "$@" >/dev/null 2>&1
    status=$?
    [ "$status" -eq "$expected" ] || fail "$label: expected exit $expected, got $status"
}

pgrep_sequence() {
    printf '%s\n' "$@" > "$WORK_DIR/pgrep-sequence"
    export FAKE_PGREP_SEQUENCE="$WORK_DIR/pgrep-sequence"
}

# A process whose command line carries a display, as an xrdp X server's does. It is started in
# this shell, so it can be reaped and checked.
start_fake_xorg() {
    bash -c 'sleep 60; true' fake-xorg "$1" -auth /tmp/lbsc-xauth -config xrdp/xorg.conf >/dev/null 2>&1 &
    FAKE_XORG_PID=$!
}

process_alive() {
    local attempt
    for attempt in $(seq 1 20); do
        kill -0 "$1" 2>/dev/null || return 1
        sleep 0.1
    done
    return 0
}

# ---------------------------------------------------------------- validation

setup_case
expect_status 2 "no arguments" bash "$SCRIPT"
expect_status 2 "unknown verb" bash "$SCRIPT" logoff "$BROKER_USER"
expect_status 2 "path traversal" bash "$SCRIPT" signout '../etc'
expect_status 2 "username too long" bash "$SCRIPT" signout "$(printf 'a%.0s' {1..65})"
expect_status 2 "bad share" bash "$SCRIPT" reset-profile 'share;rm -rf /' "$BROKER_USER"
expect_status 2 "share with a parent directory" bash "$SCRIPT" reset-profile 'host:/a/../b' "$BROKER_USER"

out=$(bash "$SCRIPT" signout root 2>/dev/null)
assert_contains "$out" "__SESSION_CONTROL_RESULT=refused" "root is refused"
expect_status 3 "root" bash "$SCRIPT" signout root
expect_status 3 "management account" bash "$SCRIPT" signout avdadmin
expect_status 3 "system account" bash "$SCRIPT" signout "$SYSTEM_USER"
expect_status 3 "not a broker user" bash "$SCRIPT" signout "$PLAIN_USER"
! grep -Fq "terminate-user" "$FAKE_CALLS" || fail "a refused account was signed out"

# ------------------------------------------------------------------- signout

setup_case
out=$(bash "$SCRIPT" signout lbscnobody)
assert_contains "$out" "__SESSION_CONTROL_RESULT=no-session" "unknown account"

setup_case
export FAKE_PGREP_STATUS=1
out=$(bash "$SCRIPT" signout "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=no-session" "nothing running"
! grep -Fq "terminate-user" "$FAKE_CALLS" || fail "signed out a user with nothing running"

setup_case
start_fake_xorg :11
xorg_pid=$FAKE_XORG_PID
printf '%s 3102 /usr/lib/xorg/Xorg :11 -config xrdp/xorg.conf\n' "$xorg_pid" > "$FAKE_PS_XORG"
pgrep_sequence 0 0 1
out=$(bash "$SCRIPT" signout "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=signed-out" "signed out"
assert_file_contains "$FAKE_CALLS" "loginctl terminate-user $BROKER_USER"
assert_file_contains "$FAKE_CALLS" "pkill -TERM -u $BROKER_USER"
! process_alive "$xorg_pid" || fail "the user's X server is still running"
wait "$xorg_pid" 2>/dev/null

setup_case
export FAKE_PGREP_STATUS=0
out=$(bash "$SCRIPT" signout "$BROKER_USER")
status=$?
assert_eq "$status" "1" "processes that never end"
assert_contains "$out" "__SESSION_CONTROL_RESULT=signout-incomplete"
assert_file_contains "$FAKE_CALLS" "pkill -KILL -u $BROKER_USER"

# ------------------------------------------------------------------- message

setup_case
expect_status 2 "empty message" bash -c "printf '   \n' | bash '$SCRIPT' message $BROKER_USER"
expect_status 2 "message too long" bash -c "head -c 2100 /dev/zero | tr '\\0' a | bash '$SCRIPT' message $BROKER_USER"

setup_case
out=$(printf 'Hello' | bash "$SCRIPT" message "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=no-session" "no session"
assert_contains "$out" "__SESSION_CONTROL_DELIVERED=0"

setup_case
start_fake_xorg :12
xorg_pid=$FAKE_XORG_PID
printf '%s 3102 /usr/lib/xorg/Xorg :12 -config xrdp/xorg.conf\n' "$xorg_pid" > "$FAKE_PS_XORG"
out=$(printf '<b>Restarting</b> soon & save\a your work' | bash "$SCRIPT" message "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=delivered" "delivered"
assert_contains "$out" "__SESSION_CONTROL_SESSIONS=1"
assert_contains "$out" "__SESSION_CONTROL_DELIVERED=1"
assert_file_contains "$FAKE_CALLS" "runuser -u $BROKER_USER -- notify-send"
assert_file_contains "$FAKE_CALLS" "[&lt;b&gt;Restarting&lt;/b&gt; soon &amp; save your work]"
assert_file_contains "$FAKE_CALLS" "DISPLAY=:12 DBUS=unix:path=/run/user/3102/bus"
kill "$xorg_pid" 2>/dev/null
wait "$xorg_pid" 2>/dev/null

# Without a notification the message falls back to xmessage.
setup_case
export FAKE_NOTIFY_STATUS=1
start_fake_xorg :13
xorg_pid=$FAKE_XORG_PID
printf '%s 3102 /usr/lib/xorg/Xorg :13 -config xrdp/xorg.conf\n' "$xorg_pid" > "$FAKE_PS_XORG"
out=$(printf 'Plain text' | bash "$SCRIPT" message "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_DELIVERED=1" "xmessage fallback"
sleep 0.2
assert_file_contains "$FAKE_CALLS" "xmessage [-center] [-timeout] [300] [Message from your administrator: Plain text]"
# The fallback runs as the session's owner too: the display comes from a process they own.
assert_file_contains "$FAKE_CALLS" "runuser -u $BROKER_USER -- xmessage -center -timeout 300"
assert_eq "$(grep -c '^runuser ' "$FAKE_CALLS")" "2" "notify-send and xmessage both through runuser"
kill "$xorg_pid" 2>/dev/null
wait "$xorg_pid" 2>/dev/null

# Without runuser nothing is shown, rather than running an X client as root.
setup_case
start_fake_xorg :17
xorg_pid=$FAKE_XORG_PID
printf '%s 3102 /usr/lib/xorg/Xorg :17 -config xrdp/xorg.conf\n' "$xorg_pid" > "$FAKE_PS_XORG"
mv "$SHIM_DIR/runuser" "$SHIM_DIR/runuser.off"
real_runuser=$(command -v runuser || true)
[ -n "$real_runuser" ] && mv "$real_runuser" "$real_runuser.off"
out=$(printf 'Plain text' | bash "$SCRIPT" message "$BROKER_USER")
[ -n "$real_runuser" ] && mv "$real_runuser.off" "$real_runuser"
mv "$SHIM_DIR/runuser.off" "$SHIM_DIR/runuser"
assert_contains "$out" "__SESSION_CONTROL_SESSIONS=1" "session found without runuser"
assert_contains "$out" "__SESSION_CONTROL_DELIVERED=0" "nothing delivered without runuser"
sleep 0.2
assert_eq "$(grep -c '^xmessage' "$FAKE_CALLS")" "0" "no xmessage as root"
kill "$xorg_pid" 2>/dev/null
wait "$xorg_pid" 2>/dev/null

# A broadcast reaches broker users only.
setup_case
start_fake_xorg :14
broker_pid=$FAKE_XORG_PID
start_fake_xorg :15
plain_pid=$FAKE_XORG_PID
start_fake_xorg :16
root_pid=$FAKE_XORG_PID
{
    printf '%s 3102 /usr/lib/xorg/Xorg :14 -config xrdp/xorg.conf\n' "$broker_pid"
    printf '%s 3101 /usr/lib/xorg/Xorg :15 -config xrdp/xorg.conf\n' "$plain_pid"
    printf '%s 0 /usr/lib/xorg/Xorg :16 -config xrdp/xorg.conf\n' "$root_pid"
    printf '999999 3102 /usr/lib/xorg/Xorg :99 vnc\n'
} > "$FAKE_PS_XORG"
out=$(printf 'Maintenance tonight' | bash "$SCRIPT" message-all)
assert_contains "$out" "__SESSION_CONTROL_SESSIONS=1" "only broker sessions"
assert_contains "$out" "__SESSION_CONTROL_DELIVERED=1"
assert_eq "$(grep -c '^notify-send' "$FAKE_CALLS")" "1" "one notification"
kill "$broker_pid" "$plain_pid" "$root_pid" 2>/dev/null
wait 2>/dev/null

# ------------------------------------------------------------- reset-profile

reset_target() { cat "$FAKE_MOUNT_TARGET"; }

setup_case
expect_status 3 "reset root" bash "$SCRIPT" reset-profile "$SHARE" root
expect_status 3 "reset a plain account" bash "$SCRIPT" reset-profile "$SHARE" "$PLAIN_USER"

setup_case
export FAKE_MOUNTPOINT_STATUS=0
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
status=$?
unset FAKE_MOUNTPOINT_STATUS
assert_eq "$status" "3" "home still mounted"
assert_contains "$out" "__SESSION_CONTROL_RESULT=profile-in-use"
! grep -Fq "mount -t nfs" "$FAKE_CALLS" || fail "mounted the share while the home was in use"

setup_case
printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n' > "$LEASE_DIR/$BROKER_USER.lease"
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=profile-in-use" "lease present"

setup_case
export FAKE_PGREP_STATUS=0
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=profile-in-use" "processes running"

setup_case
printf '1\n0\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
export FAKE_PROFILE_FIXTURE=directory
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=profile-reset" "profile reset"
assert_contains "$out" "__SESSION_CONTROL_RENAMED_TO=$BROKER_USER.reset-"
target=$(reset_target)
renamed=$(printf '%s' "$out" | sed -n "s/^__SESSION_CONTROL_RENAMED_TO=//p")
assert_file_exists "$target/$renamed/marker"
assert_not_exists "$target/$BROKER_USER"
assert_file_contains "$FAKE_CALLS" "mount -t nfs $SHARE $target -o vers=4,minorversion=1,sec=sys,nconnect=4"
assert_file_contains "$FAKE_CALLS" "umount $target"
[[ "$target" == /run/linuxbroker/profile-reset.* ]] || fail "the share was not mounted at a private mount point: $target"

setup_case
printf '1\n0\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=profile-missing" "no profile yet"

setup_case
printf '1\n0\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
export FAKE_PROFILE_FIXTURE=symlink
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER" 2>/dev/null)
status=$?
assert_eq "$status" "3" "symlinked profile"
assert_contains "$out" "__SESSION_CONTROL_RESULT=refused"
[ -L "$(reset_target)/$BROKER_USER" ] || fail "the symlink was moved"
assert_file_exists /etc/passwd

setup_case
printf '1\n0\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
export FAKE_PROFILE_FIXTURE=file
expect_status 3 "profile that is a file" bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER"

setup_case
printf '1\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
export FAKE_MOUNT_FAIL=1
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
status=$?
assert_eq "$status" "1" "mount failure"
assert_contains "$out" "__SESSION_CONTROL_RESULT=failed"

# The mount "succeeded" but nothing is mounted: never touch the local directory.
setup_case
printf '1\n1\n' > "$WORK_DIR/mountpoints"
export FAKE_MOUNTPOINT_SEQUENCE="$WORK_DIR/mountpoints"
out=$(bash "$SCRIPT" reset-profile "$SHARE" "$BROKER_USER")
assert_contains "$out" "__SESSION_CONTROL_RESULT=failed" "share not mounted"
[ -z "$(ls -A /run/linuxbroker 2>/dev/null)" ] || fail "left the empty mount point behind"

cleanup_user "$BROKER_USER"
cleanup_user "$PLAIN_USER"
cleanup_user "$SYSTEM_USER"
