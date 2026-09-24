#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/apply-host-settings.sh"
SETTINGS_FILE="/etc/linuxbroker/host-settings.conf"

setup_case() {
    reset_work
    install_basic_shims
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    rm -rf /etc/linuxbroker /etc/dconf
    rm -f /var/log/linuxbroker-host-settings.log
}

setup_case
printf '{"SettingsVersion":2,"PreserveSessionsOnDisconnect":true,"ScreenLockEnabled":false}\n' | bash "$SCRIPT" >/dev/null
assert_file_contains "$SETTINGS_FILE" "LINUXBROKER_PRESERVE_SESSIONS_ON_DISCONNECT=true"
assert_file_contains "$SETTINGS_FILE" "LINUXBROKER_SCREEN_LOCK_ENABLED=false"

setup_case
printf '{"SettingsVersion":3}\n' | bash "$SCRIPT" >/dev/null
assert_file_contains "$SETTINGS_FILE" "LINUXBROKER_PRESERVE_SESSIONS_ON_DISCONNECT=false"

setup_case
if printf '{"UnknownKey":1}\n' | bash "$SCRIPT" >/dev/null 2>"$WORK_DIR/err"; then
    fail "unknown key accepted"
fi
assert_file_contains "$WORK_DIR/err" "Unknown settings key(s): UnknownKey"

setup_case
printf '{"SettingsVersion":4,"PreserveSessionsOnDisconnect":true,"ScreenLockEnabled":true}\n' | bash "$SCRIPT" >/dev/null
assert_file_contains "$SETTINGS_FILE" "LINUXBROKER_SCREEN_LOCK_ENABLED=true"
assert_file_contains "$SETTINGS_FILE" "LINUXBROKER_PRESERVE_SESSIONS_ON_DISCONNECT=false"
assert_file_contains /var/log/linuxbroker-host-settings.log "PreserveSessionsOnDisconnect cannot be enabled"