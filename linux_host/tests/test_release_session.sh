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
    reconcile_disconnected_user bob 0 2
    unset FAKE_KILL_SURVIVES
    assert_eq "$(get_disconnect_timestamp bob)" "0" "$label timestamp should remain when Xorg survives"
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