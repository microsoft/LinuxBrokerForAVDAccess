#!/bin/bash
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR="$ROOT_DIR/linux_host/tests"
WORK_DIR="$TEST_DIR/.work"
SHIM_DIR="/usr/local/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2' got '$1'${3:+ ($3)}"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "expected text to contain '$2'${3:+ ($3)}: $1" ;; esac; }
assert_not_contains_file() { ! grep -Fq "$2" "$1" 2>/dev/null || fail "did not expect '$2' in $1"; }
assert_file_contains() { grep -Fq "$2" "$1" || fail "expected '$2' in $1"; }
assert_file_exists() { [ -e "$1" ] || fail "expected $1 to exist"; }
assert_not_exists() { [ ! -e "$1" ] || fail "expected $1 to be absent"; }

reset_work() {
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
}

cleanup_user() {
    local username="$1"
    if id "$username" >/dev/null 2>&1; then
        userdel -r "$username" >/dev/null 2>&1 || userdel "$username" >/dev/null 2>&1 || true
    fi
    rm -rf "/home/$username" "/awipsprofiles/$username" "/var/lib/linuxbroker-release-session/leases/$username.lease"
}

install_basic_shims() {
    mkdir -p "$SHIM_DIR"
    cat > "$SHIM_DIR/mount" <<'SHIM'
#!/bin/bash
if [ "${FAKE_MOUNT_FAIL:-0}" = "1" ]; then
  echo "fake mount failure" >&2
  exit 32
fi
echo "mount $*" >> "${FAKE_CALLS:-/dev/null}"
exit 0
SHIM
    cat > "$SHIM_DIR/umount" <<'SHIM'
#!/bin/bash
echo "umount $*" >> "${FAKE_CALLS:-/dev/null}"
exit 0
SHIM
    cat > "$SHIM_DIR/mountpoint" <<'SHIM'
#!/bin/bash
if [ -n "${FAKE_MOUNTPOINT_SEQUENCE:-}" ] && [ -f "$FAKE_MOUNTPOINT_SEQUENCE" ]; then
  status=$(head -n 1 "$FAKE_MOUNTPOINT_SEQUENCE")
  tail -n +2 "$FAKE_MOUNTPOINT_SEQUENCE" > "$FAKE_MOUNTPOINT_SEQUENCE.next" || true
  mv "$FAKE_MOUNTPOINT_SEQUENCE.next" "$FAKE_MOUNTPOINT_SEQUENCE"
  exit "$status"
fi
exit "${FAKE_MOUNTPOINT_STATUS:-1}"
SHIM
    cat > "$SHIM_DIR/systemctl" <<'SHIM'
#!/bin/bash
echo "systemctl $*" >> "${FAKE_CALLS:-/dev/null}"
case "$1" in
  is-enabled) exit 1 ;;
  *) exit 0 ;;
esac
SHIM
    cat > "$SHIM_DIR/dconf" <<'SHIM'
#!/bin/bash
echo "dconf $*" >> "${FAKE_CALLS:-/dev/null}"
exit 0
SHIM
    chmod +x "$SHIM_DIR/mount" "$SHIM_DIR/umount" "$SHIM_DIR/mountpoint" "$SHIM_DIR/systemctl" "$SHIM_DIR/dconf"
}

install_loginctl_shim() {
    cat > "$SHIM_DIR/loginctl" <<'SHIM'
#!/bin/bash
case "$1" in
  show-user)
    if [ "${FAKE_LOGINCTL_STATE:-offline}" = "active" ]; then
      echo "State=active"
    else
      echo "State=${FAKE_LOGINCTL_STATE:-offline}"
    fi
    ;;
  list-sessions)
    cat "${FAKE_LOGINCTL_SESSIONS:-/dev/null}"
    ;;
  terminate-session)
    echo "$2" >> "${FAKE_LOGINCTL_TERMINATED:-/dev/null}"
    ;;
  terminate-user)
    echo "loginctl terminate-user $2" >> "${FAKE_CALLS:-/dev/null}"
    ;;
  list-users)
    cat "${FAKE_LOGINCTL_USERS:-/dev/null}"
    ;;
esac
SHIM
    chmod +x "$SHIM_DIR/loginctl"
}

install_ps_shim() {
    cat > "$SHIM_DIR/ps" <<'SHIM'
#!/bin/bash
if [ "$1" = "h" ]; then
  cat "${FAKE_PS_XORG:-/dev/null}"
  exit 0
fi
if [ "$1" = "-p" ]; then
  echo "${FAKE_PS_COMM:-xrdp}"
  exit 0
fi
/bin/ps "$@"
SHIM
    chmod +x "$SHIM_DIR/ps"
}

install_process_shims() {
    cat > "$SHIM_DIR/pkill" <<'SHIM'
#!/bin/bash
echo "pkill $*" >> "${FAKE_CALLS:-/dev/null}"
exit "${FAKE_PKILL_STATUS:-1}"
SHIM
    cat > "$SHIM_DIR/pgrep" <<'SHIM'
#!/bin/bash
echo "pgrep $*" >> "${FAKE_CALLS:-/dev/null}"
exit "${FAKE_PGREP_STATUS:-1}"
SHIM
    chmod +x "$SHIM_DIR/pkill" "$SHIM_DIR/pgrep"
}

install_curl_shim() {
    cat > /usr/bin/curl <<'SHIM'
#!/bin/bash
out=""
for ((i=1; i<=$#; i++)); do
  arg="${!i}"
  if [ "$arg" = "-o" ]; then
    j=$((i+1)); out="${!j}"
  fi
  if [[ "$arg" == *"metadata/identity"* ]]; then
    printf '{"access_token":"token"}'
    exit 0
  fi
done
if [ -n "$out" ]; then
  printf '%s' "${FAKE_RELEASE_BODY:-{}}" > "$out"
fi
printf '%s' "${FAKE_HTTP_STATUS:-200}"
SHIM
    chmod +x /usr/bin/curl
}