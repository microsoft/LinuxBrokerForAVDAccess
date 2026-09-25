#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

SCRIPT="$ROOT_DIR/linux_host/xrdp-startwm.sh"
LAUNCHER="/usr/local/bin/xrdp-startwm.sh"
SESMAN_INI="/etc/xrdp/sesman.ini"
BACKUP="/etc/xrdp/sesman.ini.linuxbroker-orig"
STATE_FILE="/etc/linuxbroker/xrdp-startwm.conf"
DESKTOP_FILE="/etc/linuxbroker/desktop.conf"
RULE_FILE="/etc/polkit-1/rules.d/45-linuxbroker-xrdp.rules"
FAKE_SESMAN_PID=""

# Everything the tests create. Whatever was there before is set aside and put back.
TOUCHED=(/etc/xrdp /usr/libexec/xrdp /etc/polkit-1 /etc/X11 /usr/share/gnome-session /etc/linuxbroker
    "$LAUNCHER" "$SHIM_DIR/systemctl" "$SHIM_DIR/gnome-session" "$SHIM_DIR/logger")

stop_fake_sesman() {
    if [ -n "$FAKE_SESMAN_PID" ]; then
        kill "$FAKE_SESMAN_PID" 2>/dev/null || true
        wait "$FAKE_SESMAN_PID" 2>/dev/null || true
        FAKE_SESMAN_PID=""
    fi
    unset FAKE_SESMAN_PID_FILE
}

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
    stop_fake_sesman
    for path in "${TOUCHED[@]}"; do
        rm -rf "$path"
        if [ -e "$path.lbtest-saved" ] || [ -L "$path.lbtest-saved" ]; then
            mv "$path.lbtest-saved" "$path"
        fi
    done
}

save_touched
trap restore_touched EXIT

setup_case() {
    local path
    stop_fake_sesman
    for path in "${TOUCHED[@]}"; do
        rm -rf "$path"
    done
    reset_work
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"
    install -m 755 "$SCRIPT" "$LAUNCHER"
    # Reports the fake xrdp-sesman, when one runs, as the service's main process.
    cat > "$SHIM_DIR/systemctl" <<'SHIM'
#!/bin/bash
echo "systemctl $*" >> "${FAKE_CALLS:-/dev/null}"
if [ "$1" = "show" ]; then
  cat "${FAKE_SESMAN_PID_FILE:-/nonexistent}" 2>/dev/null || echo 0
fi
exit 0
SHIM
    cat > "$SHIM_DIR/logger" <<'SHIM'
#!/bin/bash
echo "logger $*" >> "${FAKE_CALLS:-/dev/null}"
SHIM
    chmod +x "$SHIM_DIR/systemctl" "$SHIM_DIR/logger"
    mkdir -p /etc/xrdp
}

# A process that counts the SIGHUPs it receives, standing in for xrdp-sesman.
start_fake_sesman() {
    local attempts=0
    export FAKE_SESMAN_PID_FILE="$WORK_DIR/sesman.pid"
    rm -f "$WORK_DIR/hup" "$WORK_DIR/sesman.ready"
    # shellcheck disable=SC2016 # expanded by the inner shell
    bash -c 'trap "echo hup >> \"\$1\"" HUP; : > "$2"; while :; do sleep 0.1; done' \
        fake-sesman "$WORK_DIR/hup" "$WORK_DIR/sesman.ready" &
    FAKE_SESMAN_PID=$!
    echo "$FAKE_SESMAN_PID" > "$FAKE_SESMAN_PID_FILE"
    while [ ! -e "$WORK_DIR/sesman.ready" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -gt 50 ] && fail "the fake xrdp-sesman did not start"
        sleep 0.1
    done
}

hup_count() {
    if [ -f "$WORK_DIR/hup" ]; then
        wc -l < "$WORK_DIR/hup" | tr -d ' '
    else
        echo 0
    fi
}

# The reloads received once at least $1 have arrived, or after two seconds. A signal is only
# handled when the fake's sleep ends, so a little more time is allowed for an extra one.
wait_for_hups() {
    local attempts=0
    while [ "$(hup_count)" -lt "$1" ] && [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        sleep 0.1
    done
    sleep 0.3
    hup_count
}

# A stand-in for a session script that records how it was started.
fake_session_script() {
    local path="$1" label="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<SHIM
#!/bin/bash
{
  echo "ran=$label"
  echo "args=\$*"
  for name in DESKTOP_SESSION XDG_SESSION_DESKTOP XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GNOME_SHELL_SESSION_MODE LBTEST_PROFILE; do
    echo "\$name=\${!name:-}"
  done
} > "\${LBTEST_SESSION_OUT:-/dev/null}"
SHIM
    chmod 755 "$path"
}

state_value() {
    sed -n 's/^ORIGINAL_WM=//p' "$STATE_FILE"
}

write_ubuntu_sesman() {
    cat > "$SESMAN_INI" <<'INI'
;; See `man 5 sesman.ini` for details

[Globals]
; listening port
ListenPort=3350
EnableUserWindowManager=true
; Give in relative path to user's home directory
UserWindowManager=startwm.sh
; Give in full path or relative path to /etc/xrdp
DefaultWindowManager=startwm.sh
; Give in full path or relative path to /etc/xrdp
ReconnectScript=reconnectwm.sh

[Security]
AllowRootLogin=false
DefaultWindowManager=not-read-here.sh
INI
}

test_install_on_ubuntu() {
    setup_case
    write_ubuntu_sesman
    chmod 640 "$SESMAN_INI"
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    mkdir -p /etc/polkit-1/rules.d
    start_fake_sesman
    local original out status ini_before

    original=$(cat "$SESMAN_INI")
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "install: $out"
    assert_contains "$out" "falls back to /etc/xrdp/startwm.sh"
    assert_eq "$(grep -c '^DefaultWindowManager=/usr/local/bin/xrdp-startwm.sh$' "$SESMAN_INI")" "1"
    assert_file_contains "$SESMAN_INI" "UserWindowManager=startwm.sh"
    assert_file_contains "$SESMAN_INI" "ReconnectScript=reconnectwm.sh"
    assert_file_contains "$SESMAN_INI" "DefaultWindowManager=not-read-here.sh"
    assert_file_contains "$SESMAN_INI" "; Give in relative path to user's home directory"
    assert_eq "$(stat -c %a "$SESMAN_INI")" "640" "sesman.ini keeps its mode"
    assert_eq "$(cat "$BACKUP")" "$original" "backup"
    assert_eq "$(state_value)" "/etc/xrdp/startwm.sh"
    assert_eq "$(stat -c %a "$STATE_FILE")" "644"
    assert_eq "$(stat -c %a /etc/linuxbroker)" "755"
    assert_file_contains "$RULE_FILE" 'subject.isInGroup("tsusers")'
    assert_file_contains "$RULE_FILE" '"org.freedesktop.packagekit.system-sources-refresh"'
    assert_file_contains "$RULE_FILE" '"org.freedesktop.color-manager.create-device"'
    assert_eq "$(stat -c %a "$RULE_FILE")" "644"
    assert_eq "$(ls -A /etc/xrdp | tr '\n' ' ')" "sesman.ini sesman.ini.linuxbroker-orig startwm.sh " "no temporary files"
    assert_eq "$(ls -A /etc/polkit-1/rules.d | tr '\n' ' ')" "45-linuxbroker-xrdp.rules "
    assert_eq "$(wait_for_hups 1)" "1" "xrdp-sesman reloaded"

    # Running it again changes nothing, and reloads nothing.
    ini_before=$(md5sum "$SESMAN_INI")
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "second install: $out"
    assert_contains "$out" "already starts sessions"
    assert_eq "$(md5sum "$SESMAN_INI")" "$ini_before"
    assert_eq "$(cat "$BACKUP")" "$original" "backup after a second install"
    assert_eq "$(wait_for_hups 1)" "1" "no second reload"

    # The rule is managed.
    echo "// edited" >> "$RULE_FILE"
    bash "$LAUNCHER" --install >/dev/null 2>&1 || fail "install over an edited rule"
    assert_not_contains_file "$RULE_FILE" "// edited"

    # A lost record is rebuilt from the backup, not from the first fallback.
    fake_session_script /usr/libexec/xrdp/startwm-bash.sh fallback
    rm -f "$STATE_FILE"
    bash "$LAUNCHER" --install >/dev/null 2>&1 || fail "install without a record"
    assert_eq "$(state_value)" "/etc/xrdp/startwm.sh" "record rebuilt from the backup"
    assert_eq "$(md5sum "$SESMAN_INI")" "$ini_before"

    # A package update that replaced sesman.ini is taken over again; the first backup stays.
    write_ubuntu_sesman
    echo "; new in this version" >> "$SESMAN_INI"
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "install over a replaced sesman.ini: $out"
    assert_eq "$(grep -c '^DefaultWindowManager=/usr/local/bin/xrdp-startwm.sh$' "$SESMAN_INI")" "1"
    assert_file_contains "$SESMAN_INI" "; new in this version"
    assert_eq "$(cat "$BACKUP")" "$original" "the first backup is kept"
    assert_eq "$(wait_for_hups 2)" "2" "reloaded again"
}

test_install_on_rhel() {
    setup_case
    cat > "$SESMAN_INI" <<'INI'
[Globals]
ListenPort=3350
DefaultWindowManager=startwm-bash.sh
ReconnectScript=reconnectwm.sh
INI
    fake_session_script /usr/libexec/xrdp/startwm-bash.sh rhel-startwm
    local out status

    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "install: $out"
    assert_eq "$(state_value)" "/usr/libexec/xrdp/startwm-bash.sh"
    assert_file_contains "$SESMAN_INI" "DefaultWindowManager=/usr/local/bin/xrdp-startwm.sh"
    assert_contains "$out" "polkit is not installed"
    assert_not_exists /etc/polkit-1
    # Without a running xrdp-sesman there is nothing to reload.
    assert_file_contains "$FAKE_CALLS" "systemctl show --property MainPID --value xrdp-sesman.service"
}

test_install_reads_sesman_ini_as_xrdp_does() {
    local out status

    # A missing key is xrdp's default, startwm.sh, and is added after the section header.
    setup_case
    printf '[globals]\nListenPort=3350\n\n[Security]\nAllowRootLogin=false\n' > "$SESMAN_INI"
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "missing key: $out"
    assert_eq "$(sed -n '2p' "$SESMAN_INI")" "DefaultWindowManager=/usr/local/bin/xrdp-startwm.sh" "added after the header"
    assert_eq "$(grep -c 'DefaultWindowManager' "$SESMAN_INI")" "1"
    assert_eq "$(state_value)" "/etc/xrdp/startwm.sh" "xrdp's default"

    # Names are case-insensitive and values trimmed; the last value wins.
    setup_case
    printf '[GLOBALS]\nDefaultWindowManager=startwm.sh\n  defaultwindowmanager =  /usr/libexec/xrdp/custom.sh  \n' > "$SESMAN_INI"
    fake_session_script /usr/libexec/xrdp/custom.sh custom
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "mixed case: $out"
    assert_eq "$(state_value)" "/usr/libexec/xrdp/custom.sh"
    assert_eq "$(grep -ci 'defaultwindowmanager' "$SESMAN_INI")" "2"
    assert_eq "$(grep -c '^DefaultWindowManager=/usr/local/bin/xrdp-startwm.sh$' "$SESMAN_INI")" "2"

    # A script that is not there falls back to the distribution's.
    setup_case
    printf '[Globals]\nDefaultWindowManager=/usr/libexec/xrdp/missing.sh\n' > "$SESMAN_INI"
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "0" "missing script: $out"
    assert_eq "$(state_value)" "/etc/xrdp/startwm.sh"
}

test_install_refusals() {
    local out status before

    # No xrdp: exit 3, and nothing is written.
    setup_case
    rm -rf /etc/xrdp
    mkdir -p /etc/polkit-1/rules.d
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "3" "without xrdp: $out"
    assert_contains "$out" "xrdp is not installed"
    assert_not_exists /etc/linuxbroker
    assert_not_exists "$RULE_FILE"

    # No [Globals] section: nothing changes.
    setup_case
    printf '[Security]\nAllowRootLogin=false\n' > "$SESMAN_INI"
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    before=$(cat "$SESMAN_INI")
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "1" "without [Globals]: $out"
    assert_contains "$out" "has no [Globals] section"
    assert_eq "$(cat "$SESMAN_INI")" "$before"
    assert_not_exists "$STATE_FILE"
    assert_not_exists "$BACKUP"
    assert_eq "$(ls -A /etc/xrdp | tr '\n' ' ')" "sesman.ini startwm.sh " "no temporary files"

    # No session script to fall back to.
    setup_case
    printf '[Globals]\nDefaultWindowManager=startwm.sh\n' > "$SESMAN_INI"
    out=$(bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "1" "without a session script: $out"
    assert_contains "$out" "No xrdp session script was found"
    assert_file_contains "$SESMAN_INI" "DefaultWindowManager=startwm.sh"

    # Only root.
    setup_case
    write_ubuntu_sesman
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    out=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$LAUNCHER" --install 2>&1); status=$?
    assert_eq "$status" "1" "as nobody: $out"
    assert_contains "$out" "must run as root"
    assert_file_contains "$SESMAN_INI" "DefaultWindowManager=startwm.sh"

    # Only the one option.
    out=$(bash "$LAUNCHER" --install extra 2>&1); status=$?
    assert_eq "$status" "2" "extra argument"
}

# A Debian-family host with GNOME: x11-common's Xsession and xrdp's own script, recorded.
setup_debian_session() {
    fake_session_script /etc/X11/Xsession xsession
    mkdir -p /etc/X11/Xsession.d /usr/share/gnome-session/sessions /etc/linuxbroker "$WORK_DIR/home"
    fake_session_script /etc/xrdp/startwm.sh debian-startwm
    printf 'ORIGINAL_WM=/etc/xrdp/startwm.sh\n' > "$STATE_FILE"
    printf '#!/bin/sh\nexit 0\n' > "$SHIM_DIR/gnome-session"
    chmod 755 "$SHIM_DIR/gnome-session"
    : > /usr/share/gnome-session/sessions/ubuntu.session
    printf 'LBTEST_PROFILE=sourced\nexport LBTEST_PROFILE\n' > "$WORK_DIR/home/.profile"
}

# Starts a session the way xrdp-sesman does: as the user, in their home, with no arguments.
run_session() {
    rm -f "$WORK_DIR/session.out"
    (cd "$WORK_DIR/home" && env -i PATH="$SHIM_DIR:/usr/bin:/bin" HOME="$WORK_DIR/home" FAKE_CALLS="$FAKE_CALLS" \
        LBTEST_SESSION_OUT="$WORK_DIR/session.out" bash "$LAUNCHER")
    [ -f "$WORK_DIR/session.out" ] || fail "no session script ran"
}

session_value() {
    sed -n "s/^$1=//p" "$WORK_DIR/session.out"
}

test_ubuntu_on_xorg() {
    setup_case
    setup_debian_session
    printf 'DESKTOP=gnome\n' > "$DESKTOP_FILE"

    run_session
    assert_eq "$(session_value ran)" "xsession"
    assert_eq "$(session_value args)" "gnome-session --session=ubuntu"
    assert_eq "$(session_value DESKTOP_SESSION)" "ubuntu"
    assert_eq "$(session_value XDG_SESSION_DESKTOP)" "ubuntu"
    assert_eq "$(session_value XDG_CURRENT_DESKTOP)" "ubuntu:GNOME"
    assert_eq "$(session_value GNOME_SHELL_SESSION_MODE)" "ubuntu"
    assert_eq "$(session_value XDG_SESSION_TYPE)" "x11"
    assert_eq "$(session_value LBTEST_PROFILE)" "sourced" "the profiles are read first, as xrdp's script does"
    assert_file_contains "$FAKE_CALLS" "logger -t linuxbroker-startwm -- Starting gnome"

    # Quotes and case do not matter.
    printf '# Written by the bootstrap.\nDESKTOP="GNOME"\n' > "$DESKTOP_FILE"
    run_session
    assert_eq "$(session_value args)" "gnome-session --session=ubuntu"

    # Without Ubuntu's session, upstream GNOME.
    rm -f /usr/share/gnome-session/sessions/ubuntu.session
    run_session
    assert_eq "$(session_value ran)" "xsession"
    assert_eq "$(session_value args)" "gnome-session"
    assert_eq "$(session_value DESKTOP_SESSION)" "gnome"
    assert_eq "$(session_value XDG_CURRENT_DESKTOP)" "GNOME"
    assert_eq "$(session_value GNOME_SHELL_SESSION_MODE)" ""
    assert_eq "$(session_value XDG_SESSION_TYPE)" "x11"
}

test_otherwise_the_distribution_script_runs() {
    setup_case
    setup_debian_session

    # Without desktop.conf, exactly what xrdp ran before.
    run_session
    assert_eq "$(session_value ran)" "debian-startwm"
    assert_eq "$(session_value args)" ""
    assert_eq "$(session_value DESKTOP_SESSION)" ""
    assert_eq "$(session_value XDG_SESSION_TYPE)" ""

    printf 'DESKTOP=kde\n' > "$DESKTOP_FILE"
    run_session
    assert_eq "$(session_value ran)" "debian-startwm" "a desktop it does not start"
    assert_file_contains "$FAKE_CALLS" "Ignoring DESKTOP=kde"

    # shellcheck disable=SC2016 # the command must reach the file unexpanded
    printf 'DESKTOP=$(touch %s/pwned)\n' "$WORK_DIR" > "$DESKTOP_FILE"
    run_session
    assert_eq "$(session_value ran)" "debian-startwm" "desktop.conf is never sourced"
    assert_not_exists "$WORK_DIR/pwned"

    printf 'DESKTOP=gnome\n' > "$DESKTOP_FILE"
    rm -f "$SHIM_DIR/gnome-session"
    run_session
    assert_eq "$(session_value ran)" "debian-startwm" "GNOME is not installed"
    assert_file_contains "$FAKE_CALLS" "gnome is not installed"
}

test_rhel_runs_its_own_script() {
    setup_case
    fake_session_script /etc/X11/xinit/Xsession rhel-xsession
    fake_session_script /usr/libexec/xrdp/startwm-bash.sh rhel-startwm
    mkdir -p /etc/linuxbroker "$WORK_DIR/home"
    printf 'ORIGINAL_WM=/usr/libexec/xrdp/startwm-bash.sh\n' > "$STATE_FILE"
    printf 'DESKTOP=gnome\n' > "$DESKTOP_FILE"
    printf '#!/bin/sh\nexit 0\n' > "$SHIM_DIR/gnome-session"
    chmod 755 "$SHIM_DIR/gnome-session"

    run_session
    assert_eq "$(session_value ran)" "rhel-startwm"
}

test_an_unusable_record_falls_back() {
    local record
    setup_case
    setup_debian_session
    fake_session_script /usr/libexec/xrdp/startwm-bash.sh fallback
    # Each would run if only the path were checked: a relative one resolves in the user's home.
    fake_session_script "$WORK_DIR/home/startwm.sh" users-own
    fake_session_script "/etc/xrdp/start wm.sh" space
    fake_session_script "/etc/xrdp/startwm.sh;reboot" semicolon

    for record in /etc/xrdp/missing.sh startwm.sh "$LAUNCHER" "/etc/xrdp/start wm.sh" "/etc/xrdp/startwm.sh;reboot"; do
        printf 'ORIGINAL_WM=%s\n' "$record" > "$STATE_FILE"
        run_session
        assert_eq "$(session_value ran)" "fallback" "record $record"
    done

    # With no xrdp script at all, the X session starts directly.
    rm -f /usr/libexec/xrdp/startwm-bash.sh /etc/xrdp/startwm.sh
    run_session
    assert_eq "$(session_value ran)" "xsession"
    assert_eq "$(session_value args)" ""
}

test_install_on_ubuntu
test_install_on_rhel
test_install_reads_sesman_ini_as_xrdp_does
test_install_refusals
test_ubuntu_on_xorg
test_otherwise_the_distribution_script_runs
test_rhel_runs_its_own_script
test_an_unusable_record_falls_back

echo "xrdp-startwm.sh tests passed"
