#!/bin/bash
set -uo pipefail
# shellcheck source=linux_host/tests/common.sh
. "$(dirname "$0")/common.sh"

LEASE="bbbbbbbb-1111-2222-3333-cccccccccccc"

run_for_script() {
    local script="$1"
    local label="$2"

    reset_work
    install_basic_shims
    install_loginctl_shim
    install_ps_shim
    install_curl_shim
    export FAKE_CALLS="$WORK_DIR/calls.log"
    export FAKE_PS_XORG="$WORK_DIR/ps_xorg"
    export FAKE_LOGINCTL_SESSIONS="$WORK_DIR/sessions"
    export FAKE_LOGINCTL_TERMINATED="$WORK_DIR/terminated"
    : > "$FAKE_CALLS"
    : > "$FAKE_PS_XORG"
    : > "$FAKE_LOGINCTL_SESSIONS"
    : > "$FAKE_LOGINCTL_TERMINATED"

    # shellcheck source=/dev/null
    . "$script"
    STATE_DIRECTORY="$WORK_DIR/state-$label"
    LEASE_DIRECTORY="$STATE_DIRECTORY/leases"
    CURRENT_USERS_DETAILS="$STATE_DIRECTORY/current_users.txt"
    PREVIOUS_USERS_FILE="$STATE_DIRECTORY/previous_users.txt"
    DISCONNECTED_USERS_FILE="$STATE_DIRECTORY/disconnected_users.tsv"
    IDLE_WARNED_USERS_FILE="$STATE_DIRECTORY/idle_warned_users.tsv"
    ACKED_VERSION_FILE="$STATE_DIRECTORY/acked_settings_version"
    LOG_FILE="$WORK_DIR/release-$label.log"
    SETTINGS_FILE="$WORK_DIR/no-settings.conf"
    hostname="testhost"
    mkdir -p "$LEASE_DIRECTORY"
    printf '%s\n' "$LEASE" > "$LEASE_DIRECTORY/bob.lease"
    export FAKE_RELEASE_BODY="{\"Hostname\":\"testhost\",\"LeaseId\":\"$LEASE\"}"
    export FAKE_HTTP_STATUS=200

    kill() {
        local pid="${*: -1}"
        echo "$pid" >> "$WORK_DIR/killed-$label"
        if [ "${FAKE_KILL_SURVIVES:-0}" != "1" ]; then
            grep -v "^$pid " "$FAKE_PS_XORG" > "$FAKE_PS_XORG.new" || true
            mv "$FAKE_PS_XORG.new" "$FAKE_PS_XORG"
        fi
        return 0
    }

    printf '333 bob Xorg\n' > "$FAKE_PS_XORG"
    PRESERVE_SESSIONS_ON_DISCONNECT=false
    : > "$WORK_DIR/killed-$label"
    release_vm bob >/dev/null
    assert_file_contains "$WORK_DIR/killed-$label" "333"

    printf '444 bob Xorg\n' > "$FAKE_PS_XORG"
    PRESERVE_SESSIONS_ON_DISCONNECT=true
    : > "$WORK_DIR/killed-$label"
    release_vm bob >/dev/null
    assert_eq "$(cat "$WORK_DIR/killed-$label")" "" "preserve on should not kill during release"

    printf '555 bob Xorg\n' > "$FAKE_PS_XORG"
    printf '42 1000 bob seat0\n' > "$FAKE_LOGINCTL_SESSIONS"
    printf 'bob\t0\n' > "$DISCONNECTED_USERS_FILE"
    GRACE_PERIOD_SECONDS=1
    : > "$WORK_DIR/killed-$label"
    reconcile_disconnected_user bob 0 2
    assert_file_contains "$WORK_DIR/killed-$label" "555"
    assert_file_contains "$FAKE_LOGINCTL_TERMINATED" "42"
    [ -z "$(get_disconnect_timestamp bob)" ] || fail "$label timestamp should be cleared when Xorg is gone"

    printf '666 bob Xorg\n' > "$FAKE_PS_XORG"
    printf 'bob\t0\n' > "$DISCONNECTED_USERS_FILE"
    export FAKE_KILL_SURVIVES=1
    # A killed Xorg that exits while the agent waits for it counts as gone.
    sleep() { : > "$FAKE_PS_XORG"; }
    reconcile_disconnected_user bob 0 2
    [ -z "$(get_disconnect_timestamp bob)" ] || fail "$label timestamp should be cleared when Xorg exits during the wait"
    assert_not_contains_file "$LOG_FILE" "Xorg processes remain"

    printf '666 bob Xorg\n' > "$FAKE_PS_XORG"
    printf 'bob\t0\n' > "$DISCONNECTED_USERS_FILE"
    sleep() { :; }
    reconcile_disconnected_user bob 0 2
    unset -f sleep
    unset FAKE_KILL_SURVIVES
    assert_eq "$(get_disconnect_timestamp bob)" "0" "$label timestamp should remain when Xorg survives"
    assert_file_contains "$LOG_FILE" "Xorg processes remain for user bob"
}

aggregation_for_script() {
    local script="$1"
    local label="$2"
    local info_script

    reset_work
    install_basic_shims
    install_loginctl_shim
    install_ps_shim
    export FAKE_CALLS="$WORK_DIR/calls.log"
    : > "$FAKE_CALLS"

    # shellcheck source=/dev/null
    . "$script"
    STATE_DIRECTORY="$WORK_DIR/agg-state-$label"
    LEASE_DIRECTORY="$STATE_DIRECTORY/leases"
    CURRENT_USERS_DETAILS="$STATE_DIRECTORY/current_users.txt"
    PREVIOUS_USERS_FILE="$STATE_DIRECTORY/previous_users.txt"
    DISCONNECTED_USERS_FILE="$STATE_DIRECTORY/disconnected_users.tsv"
    IDLE_WARNED_USERS_FILE="$STATE_DIRECTORY/idle_warned_users.tsv"
    ACKED_VERSION_FILE="$STATE_DIRECTORY/acked_settings_version"
    LOG_FILE="$WORK_DIR/agg-$label.log"
    SETTINGS_FILE="$WORK_DIR/no-settings.conf"
    info_script="$WORK_DIR/xrdp-info-$label.sh"
    XORG_USERS_INFO_SCRIPT="$info_script"
    mkdir -p "$STATE_DIRECTORY"
    cat > "$info_script" <<'INFO'
#!/bin/bash
printf '\n    PID USERNAME             START_TIME          STATUS      \n'
printf '   101 alice                2026-01-01 00:00   disconnected\n'
printf '   102 alice                2026-01-01 00:01   active\n'
INFO
    chmod +x "$info_script"
    refresh_settings() { return 0; }
    ensure_jq_installed() { return 0; }
    release_vm() { echo "$1" >> "$WORK_DIR/agg-releases-$label"; return 0; }
    enforce_idle_session() { echo "$1:$2" >> "$WORK_DIR/agg-idle-$label"; return 0; }
    send_heartbeat() { printf '%s' "$1" > "$WORK_DIR/agg-heartbeat-$label"; return 0; }

    main
    assert_not_exists "$WORK_DIR/agg-releases-$label"
    assert_file_contains "$WORK_DIR/agg-idle-$label" "alice:102"
    # The heartbeat reports one session per user, active when any of their sessions is.
    jq -e 'length == 1 and .[0].username == "alice" and .[0].state == "active" and (.[0].sessionStart | type) == "number"' \
        "$WORK_DIR/agg-heartbeat-$label" >/dev/null || fail "$label heartbeat sessions: $(cat "$WORK_DIR/agg-heartbeat-$label")"

    # Building the session list reads each active session's idle time from its X server, so a
    # run that sends no heartbeat never builds it: a watcher run, or one during the back-off.
    session_json() { echo "$1" >> "$WORK_DIR/agg-sessions-$label"; echo '{}'; }
    rm -f "$WORK_DIR/agg-heartbeat-$label"
    RUN_MODE="logind-watcher"
    main
    assert_not_exists "$WORK_DIR/agg-sessions-$label"
    assert_not_exists "$WORK_DIR/agg-heartbeat-$label"

    RUN_MODE="systemd-timer"
    printf '%s\n' "$(( $(date +%s) + 600 ))" > "$STATE_DIRECTORY/heartbeat_unsupported_until"
    main
    assert_not_exists "$WORK_DIR/agg-sessions-$label"
    assert_not_exists "$WORK_DIR/agg-heartbeat-$label"

    rm -f "$STATE_DIRECTORY/heartbeat_unsupported_until"
    main
    assert_file_contains "$WORK_DIR/agg-sessions-$label" "alice"
    assert_file_exists "$WORK_DIR/agg-heartbeat-$label"
}

run_for_script "$ROOT_DIR/linux_host/session_release_buffer/release-session.sh" agent
aggregation_for_script "$ROOT_DIR/linux_host/session_release_buffer/release-session.sh" agent

# ss prints a Unix socket's path only on the listening end, which is Xorg's, so an idle
# disconnect finds the xrdp end of the display connection by its inode. The ss lines are
# trimmed from RHEL 8 with xrdp 0.10; Ubuntu with xrdp 0.9 prints the same shape.
idle_disconnect_for_script() {
    local script="$1"
    local label="$2"
    local signalled="$WORK_DIR/signalled-$label"
    local forked
    local unforked

    reset_work
    # shellcheck source=/dev/null
    . "$script"
    LOG_FILE="$WORK_DIR/idle-$label.log"
    STATE_DIRECTORY="$WORK_DIR"
    IDLE_WARNED_USERS_FILE="$WORK_DIR/idle-warned-$label.tsv"
    : > "$signalled"

    get_session_display() { echo ":12"; }
    # 100 is the xrdp daemon. 200 and 300 are the connection processes it forked for this
    # session and for the one on display :120, and the daemon shares its stdout with 200.
    forked=$(cat <<'SS'
Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
u_str ESTAB 0 0 /run/xrdp/2008/xrdp_display_12 669282 * 669904 users:(("Xorg",pid=500,fd=7))
u_str ESTAB 0 0 * 669904 * 669282 users:(("xrdp",pid=200,fd=27))
u_str ESTAB 0 0 * 165288 * 165899 users:(("xrdp",pid=200,fd=2),("xrdp",pid=100,fd=2))
u_str ESTAB 0 0 /run/xrdp/2009/xrdp_display_120 700001 * 700002 users:(("Xorg",pid=600,fd=7))
u_str ESTAB 0 0 * 700002 * 700001 users:(("xrdp",pid=300,fd=27))
SS
)
    # With fork=false the daemon carries every connection itself.
    unforked=$(printf '%s\n' \
        'u_str ESTAB 0 0 /run/xrdp/2008/xrdp_display_12 669282 * 669904 users:(("Xorg",pid=500,fd=7))' \
        'u_str ESTAB 0 0 * 669904 * 669282 users:(("xrdp",pid=100,fd=27))')
    FAKE_SS="$forked"
    ss() { printf '%s\n' "$FAKE_SS"; }
    # Answers "ps -p PID -o comm=", "-o ppid=" and "-o etimes=". Connection 200 has been open
    # for FAKE_CONNECTED_SECONDS.
    FAKE_CONNECTED_SECONDS=5000
    ps() {
        case "$2:$4" in
            100:comm=|200:comm=|300:comm=) echo xrdp ;;
            500:comm=|600:comm=) echo Xorg ;;
            1:comm=) echo systemd ;;
            100:ppid=) echo 1 ;;
            200:ppid=|300:ppid=) echo 100 ;;
            100:etimes=) echo 90000 ;;
            200:etimes=) echo "$FAKE_CONNECTED_SECONDS" ;;
            300:etimes=) echo 5 ;;
            *) return 1 ;;
        esac
    }
    kill() { echo "${*: -1}" >> "$signalled"; }

    disconnect_session bob 500 || fail "$label found no xrdp connection for display :12"
    assert_eq "$(cat "$signalled")" "200" "$label signals only the connection process of display :12"
    assert_file_contains "$LOG_FILE" "Disconnected idle xrdp connection 200 for user bob."

    # With fork=false the daemon carries every session on the host, so it is left alone.
    FAKE_SS="$unforked"
    : > "$signalled"
    if disconnect_session bob 500; then
        fail "$label disconnected through the xrdp daemon"
    fi
    assert_eq "$(cat "$signalled")" "" "$label leaves the xrdp daemon alone"
    assert_file_contains "$LOG_FILE" "No xrdp connection process was found for user bob on display :12."

    # The idle warning goes to the session's display as its owner, under the same name as the
    # other broker notifications.
    printf '#!/bin/bash\nexit 0\n' > "$SHIM_DIR/notify-send"
    chmod +x "$SHIM_DIR/notify-send"
    id() { echo 3102; }
    get_session_xauthority() { echo /home/bob/.Xauthority; }
    runuser() { printf '%s DISPLAY=%s DBUS=%s\n' "$*" "$DISPLAY" "$DBUS_SESSION_BUS_ADDRESS" >> "$WORK_DIR/runuser-$label"; }
    warn_idle_user bob 500 90 || fail "$label idle warning was not delivered"
    assert_file_contains "$WORK_DIR/runuser-$label" "bob -- notify-send --app-name=Linux Broker Idle session warning Your session has been idle and will be disconnected in 90 seconds."
    assert_file_contains "$WORK_DIR/runuser-$label" "DISPLAY=:12 DBUS=unix:path=/run/user/3102/bus"

    # X keeps counting while a session sits disconnected, and reconnecting sends it no input,
    # so the idle time is capped at how long the current connection has been open.
    printf '#!/bin/bash\necho 2900000\n' > "$SHIM_DIR/xprintidle"
    chmod +x "$SHIM_DIR/xprintidle"
    FAKE_SS="$forked"
    FAKE_CONNECTED_SECONDS=40
    assert_eq "$(get_session_idle_seconds 500)" "40" "$label idle time of a connection opened 40 seconds ago"
    FAKE_CONNECTED_SECONDS=5000
    assert_eq "$(get_session_idle_seconds 500)" "2900" "$label idle time of a connection open for longer"
    FAKE_SS="$unforked"
    assert_eq "$(get_session_idle_seconds 500)" "2900" "$label idle time without a connection process"

    # A user who reconnects after an idle disconnect is not disconnected again straight away.
    # The new connection is warned and then disconnected on the usual schedule.
    IDLE_TIMEOUT_SECONDS=300
    IDLE_WARNING_SECONDS=120
    FAKE_SS="$forked"
    : > "$signalled"
    : > "$WORK_DIR/runuser-$label"
    FAKE_CONNECTED_SECONDS=40
    enforce_idle_session bob 500
    assert_eq "$(cat "$signalled")" "" "$label disconnected a user who had just reconnected"
    assert_eq "$(cat "$WORK_DIR/runuser-$label")" "" "$label warned a user who had just reconnected"
    FAKE_CONNECTED_SECONDS=200
    enforce_idle_session bob 500
    assert_file_contains "$WORK_DIR/runuser-$label" "will be disconnected in 100 seconds."
    assert_eq "$(cat "$signalled")" "" "$label disconnected a user inside the warning window"
    FAKE_CONNECTED_SECONDS=400
    enforce_idle_session bob 500
    assert_eq "$(cat "$signalled")" "200" "$label idle disconnect after reconnecting"
    assert_file_contains "$LOG_FILE" "User bob has been idle for 400 seconds."
    rm -f "$SHIM_DIR/notify-send" "$SHIM_DIR/xprintidle"

    unset -f get_session_display get_session_xauthority ss ps kill id runuser
    unset FAKE_SS FAKE_CONNECTED_SECONDS
}

idle_disconnect_for_script "$ROOT_DIR/linux_host/session_release_buffer/release-session.sh" agent

# The agent runs on every distribution. jq is put back when it is missing, with the
# distribution's package manager.
jq_install_for() {
    local manager="$1"

    reset_work
    install_basic_shims
    # shellcheck source=/dev/null
    . "$ROOT_DIR/linux_host/session_release_buffer/release-session.sh"
    LOG_FILE="$WORK_DIR/jq-$manager.log"
    export FAKE_JQ_CALLS="$WORK_DIR/jq-calls-$manager"
    : > "$FAKE_JQ_CALLS"

    command() {
        if [ "$1" = "-v" ]; then
            case "$2" in
                jq) [ -e "$WORK_DIR/jq-installed" ] ;;
                "$manager") return 0 ;;
                apt-get|dnf|yum) return 1 ;;
                *) builtin command "$@" ;;
            esac
            return
        fi
        builtin command "$@"
    }
    apt-get() { echo "apt-get $*" >> "$FAKE_JQ_CALLS"; [[ " $* " == *" install "* ]] && : > "$WORK_DIR/jq-installed"; return 0; }
    dnf() { echo "dnf $*" >> "$FAKE_JQ_CALLS"; : > "$WORK_DIR/jq-installed"; return 0; }
    yum() { echo "yum $*" >> "$FAKE_JQ_CALLS"; : > "$WORK_DIR/jq-installed"; return 0; }

    ensure_jq_installed
    assert_file_contains "$FAKE_JQ_CALLS" "$manager"
    assert_file_contains "$FAKE_JQ_CALLS" "install -y jq"
    unset -f command apt-get dnf yum
}

jq_install_for apt-get
jq_install_for dnf
jq_install_for yum