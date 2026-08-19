#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WATCHER_LOG_FILE="/var/log/release-session-watcher.log"
STATE_DIRECTORY="/var/lib/linuxbroker-release-session"
RECONCILE_SCRIPT="/usr/local/bin/release-session.sh"
LAST_TRIGGER_FILE="$STATE_DIRECTORY/logind-watcher.last_trigger"
TRIGGER_LOCK_FILE="$STATE_DIRECTORY/logind-watcher.trigger.lock"
DEBOUNCE_SECONDS="${LINUXBROKER_LOGIND_WATCHER_DEBOUNCE_SECONDS:-10}"
SETTLE_SECONDS="${LINUXBROKER_LOGIND_WATCHER_SETTLE_SECONDS:-2}"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [logind-watcher] - $1" | tee -a "$WATCHER_LOG_FILE"
}

ensure_state_files() {
    mkdir -p "$STATE_DIRECTORY"
    touch "$WATCHER_LOG_FILE"
    chmod 600 "$WATCHER_LOG_FILE"
}

read_last_trigger() {
    if [ -s "$LAST_TRIGGER_FILE" ]; then
        tr -d '\r\n' < "$LAST_TRIGGER_FILE"
    fi
}

write_last_trigger() {
    printf '%s\n' "$1" > "$LAST_TRIGGER_FILE"
    chmod 600 "$LAST_TRIGGER_FILE"
}

close_trigger_lock() {
    local trigger_fd="$1"

    flock -u "$trigger_fd" 2>/dev/null || true
    eval "exec ${trigger_fd}>&-"
}

trigger_reconciliation() {
    local reason="$1"
    local trigger_fd
    local now
    local last_trigger
    local elapsed

    if [ ! -x "$RECONCILE_SCRIPT" ]; then
        log "ERROR: Reconciliation script $RECONCILE_SCRIPT was not found or is not executable."
        return 1
    fi

    exec {trigger_fd}> "$TRIGGER_LOCK_FILE"

    if ! flock -n "$trigger_fd"; then
        log "A prior logind wake-up is still being processed. Skipping $reason."
        close_trigger_lock "$trigger_fd"
        return 0
    fi

    now=$(date +%s)
    last_trigger=$(read_last_trigger)

    if [[ "$last_trigger" =~ ^[0-9]+$ ]]; then
        elapsed=$((now - last_trigger))

        if [ "$elapsed" -lt "$DEBOUNCE_SECONDS" ]; then
            log "Debouncing $reason after $elapsed seconds."
            close_trigger_lock "$trigger_fd"
            return 0
        fi
    fi

    write_last_trigger "$now"
    log "Received $reason from logind. Waiting $SETTLE_SECONDS seconds before reconciliation."
    sleep "$SETTLE_SECONDS"

    if "$RECONCILE_SCRIPT" --logind-watcher; then
        log "Reconciliation completed for $reason."
    else
        local status=$?
        log "ERROR: Reconciliation failed for $reason with exit code $status."
        close_trigger_lock "$trigger_fd"
        return "$status"
    fi

    close_trigger_lock "$trigger_fd"
    return 0
}

process_monitor_line() {
    local line="$1"

    case "$line" in
        *"member=SessionNew"*)
            trigger_reconciliation "SessionNew"
            ;;
        *"member=SessionRemoved"*)
            trigger_reconciliation "SessionRemoved"
            ;;
        *"member=UserNew"*)
            trigger_reconciliation "UserNew"
            ;;
        *"member=UserRemoved"*)
            trigger_reconciliation "UserRemoved"
            ;;
        *"member=PropertiesChanged"*)
            trigger_reconciliation "PropertiesChanged"
            ;;
    esac
}

start_monitor_command() {
    if command -v dbus-monitor >/dev/null 2>&1; then
        log "Watching logind via dbus-monitor."
        dbus-monitor --system "type='signal',sender='org.freedesktop.login1'"
        return
    fi

    if command -v busctl >/dev/null 2>&1; then
        log "Watching logind via busctl monitor."
        busctl monitor org.freedesktop.login1
        return
    fi

    log "ERROR: Neither dbus-monitor nor busctl is available on this host."
    return 1
}

main() {
    local monitor_status

    ensure_state_files
    log "Starting logind session watcher."

    start_monitor_command 2>/dev/null | while IFS= read -r line; do
        process_monitor_line "$line"
    done

    monitor_status=${PIPESTATUS[0]}
    log "ERROR: logind session monitor exited with status $monitor_status."
    exit 1
}

main