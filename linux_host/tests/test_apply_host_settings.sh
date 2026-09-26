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
    rm -rf /etc/linuxbroker /etc/dconf /etc/xdg/xfce4
    rm -f /var/log/linuxbroker-host-settings.log
}

trap 'rm -rf /etc/xdg/xfce4' EXIT

DCONF_KEYFILE="/etc/dconf/db/local.d/00-screensaver"
DCONF_LOCKS="/etc/dconf/db/local.d/locks/screensaver"
XFCONF_FILE="/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml"

# The value of a key in one section of the dconf keyfile.
keyfile_value() {
    awk -v section="[$1]" -v key="$2" '
        /^\[/ { in_section = ($0 == section); next }
        in_section && index($0, key "=") == 1 { print substr($0, length(key) + 2) }
    ' "$DCONF_KEYFILE"
}

# The xfconf delays in the order they appear: the blank delay, when there is one, then the
# lock delay.
xfconf_delays() {
    sed -n 's/.*<property name="delay" type="int" value="\([^"]*\)".*/\1/p' "$XFCONF_FILE" | tr '\n' ' '
}

apply_settings() {
    printf '%s\n' "$1" | bash "$SCRIPT" >/dev/null || fail "apply-host-settings.sh rejected $1"
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

# MATE gets the same policy as GNOME, in minutes.
setup_case
mkdir -p /etc/dconf
bash "$SCRIPT" --defaults >/dev/null || fail "--defaults failed"
assert_eq "$(keyfile_value org/gnome/desktop/session idle-delay)" "uint32 0"
assert_eq "$(keyfile_value org/mate/desktop/session idle-delay)" "0"
assert_eq "$(keyfile_value org/mate/screensaver idle-activation-enabled)" "false"
assert_eq "$(keyfile_value org/mate/screensaver lock-enabled)" "false"
assert_eq "$(keyfile_value org/mate/screensaver lock-delay)" "0"
assert_eq "$(keyfile_value org/mate/screensaver mode)" "'blank-only'"
assert_eq "$(keyfile_value org/mate/desktop/lockdown disable-lock-screen)" "true"
for key in /org/mate/desktop/session/idle-delay /org/mate/screensaver/idle-activation-enabled \
    /org/mate/screensaver/lock-enabled /org/mate/screensaver/lock-delay /org/mate/screensaver/mode \
    /org/mate/desktop/lockdown/disable-lock-screen /org/gnome/desktop/lockdown/disable-lock-screen; do
    assert_eq "$(grep -cxF "$key" "$DCONF_LOCKS")" "1" "lock for $key"
done
assert_not_exists "$XFCONF_FILE"
assert_file_contains "$FAKE_CALLS" "dconf update"

apply_settings '{"SettingsVersion":5,"ScreenIdleDelaySeconds":600,"ScreenLockEnabled":true,"ScreenLockDelaySeconds":90,"DisableLockScreen":false,"ScreenLockSettingsLocked":false}'
assert_eq "$(keyfile_value org/gnome/desktop/session idle-delay)" "uint32 600"
assert_eq "$(keyfile_value org/mate/desktop/session idle-delay)" "10"
assert_eq "$(keyfile_value org/mate/screensaver idle-activation-enabled)" "true"
assert_eq "$(keyfile_value org/mate/screensaver lock-enabled)" "true"
assert_eq "$(keyfile_value org/mate/screensaver lock-delay)" "2"
assert_eq "$(keyfile_value org/mate/desktop/lockdown disable-lock-screen)" "false"
assert_not_exists "$DCONF_LOCKS"

# Xfce reads xfconf: a system-wide channel file, whose properties only root may change.
setup_case
mkdir -p /etc/xdg/xfce4
bash "$SCRIPT" --defaults >/dev/null || fail "--defaults failed"
expected='<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by apply-host-settings.sh. Manual edits are overwritten. -->
<!-- The xfce4-screensaver settings every user starts with. Delays are in minutes. -->

<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false" unlocked="root"/>
    <property name="mode" type="int" value="0" unlocked="root"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="false" unlocked="root"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false" unlocked="root"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="false" unlocked="root"/>
      <property name="delay" type="int" value="0" unlocked="root"/>
    </property>
  </property>
</channel>'
assert_eq "$(cat "$XFCONF_FILE")" "$expected"
assert_eq "$(stat -c %a "$XFCONF_FILE")" "644"
assert_not_exists /etc/dconf

apply_settings '{"SettingsVersion":6,"ScreenIdleDelaySeconds":600,"ScreenLockEnabled":true,"ScreenLockDelaySeconds":90,"DisableLockScreen":false,"ScreenLockSettingsLocked":false}'
expected='<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by apply-host-settings.sh. Manual edits are overwritten. -->
<!-- The xfce4-screensaver settings every user starts with. Delays are in minutes. -->

<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="true"/>
    <property name="mode" type="int" value="0"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="true"/>
      <property name="delay" type="int" value="10"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="true"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="true"/>
      <property name="delay" type="int" value="2"/>
    </property>
  </property>
</channel>'
assert_eq "$(cat "$XFCONF_FILE")" "$expected"

# Unchanged settings leave the file alone.
: > /var/log/linuxbroker-host-settings.log
apply_settings '{"SettingsVersion":6,"ScreenIdleDelaySeconds":600,"ScreenLockEnabled":true,"ScreenLockDelaySeconds":90,"DisableLockScreen":false,"ScreenLockSettingsLocked":false}'
assert_not_contains_file /var/log/linuxbroker-host-settings.log "Xfce"

# The blank delay rounds up, the lock delay to the nearest minute, and both stop at 8 hours.
setup_case
mkdir -p /etc/dconf /etc/xdg/xfce4
for entry in "29|1|0" "30|1|1" "89|2|1" "90|2|2" "86400|480|480" '"090"|2|2'; do
    IFS='|' read -r seconds blank lock <<< "$entry"
    apply_settings "{\"SettingsVersion\":7,\"ScreenIdleDelaySeconds\":$seconds,\"ScreenLockDelaySeconds\":$seconds}"
    assert_eq "$(keyfile_value org/mate/desktop/session idle-delay)" "$blank" "MATE blank delay for $seconds seconds"
    assert_eq "$(keyfile_value org/mate/screensaver lock-delay)" "$lock" "MATE lock delay for $seconds seconds"
    assert_eq "$(xfconf_delays)" "$blank $lock " "Xfce delays for $seconds seconds"
done