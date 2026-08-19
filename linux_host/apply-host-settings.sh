#!/bin/bash
#
# Applies the fleet-wide Linux Broker host settings profile to this host.
#
# Usage:
#   apply-host-settings.sh            # read the settings JSON document from stdin
#   apply-host-settings.sh --defaults # write the built-in defaults (used at provisioning)
#
# This script is in the avdadmin sudoers allowlist, so it is the only way the broker API can
# change host configuration. It therefore accepts a JSON document on stdin and nothing that
# is interpreted as a command: no argument is ever evaluated, every value is validated
# against a fixed range, and unknown keys are rejected outright.
#
# It is also invoked directly (without sudo) by release-session.sh, which already runs as
# root, so that push and pull share exactly one implementation.
#
# The script is idempotent. systemd units are only reloaded when their generated drop-in
# content actually changed.

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="/var/log/linuxbroker-host-settings.log"
SETTINGS_DIRECTORY="/etc/linuxbroker"
SETTINGS_FILE="$SETTINGS_DIRECTORY/host-settings.conf"

DCONF_PROFILE_DIRECTORY="/etc/dconf/profile"
DCONF_PROFILE_FILE="$DCONF_PROFILE_DIRECTORY/user"
DCONF_LOCAL_DIRECTORY="/etc/dconf/db/local.d"
DCONF_LOCKS_DIRECTORY="$DCONF_LOCAL_DIRECTORY/locks"
DCONF_SCREENSAVER_FILE="$DCONF_LOCAL_DIRECTORY/00-screensaver"
DCONF_SCREENSAVER_LOCKS_FILE="$DCONF_LOCKS_DIRECTORY/screensaver"

RELEASE_TIMER_NAME="linuxbroker-release-session.timer"
WATCHER_SERVICE_NAME="linuxbroker-release-session-watcher.service"
RELEASE_TIMER_DROPIN_DIRECTORY="/etc/systemd/system/$RELEASE_TIMER_NAME.d"
WATCHER_DROPIN_DIRECTORY="/etc/systemd/system/$WATCHER_SERVICE_NAME.d"
RELEASE_TIMER_DROPIN="$RELEASE_TIMER_DROPIN_DIRECTORY/10-linuxbroker-settings.conf"
WATCHER_DROPIN="$WATCHER_DROPIN_DIRECTORY/10-linuxbroker-settings.conf"

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [apply-host-settings] - $1" >> "$LOG_FILE"
}

fail() {
    log "ERROR: $1"
    echo "$1" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    fail "This script must run as root."
fi

# ---------------------------------------------------------------------------
# Setting definitions
#
# name|minimum|maximum|default. These bounds intentionally duplicate the CHECK constraints
# in sql_queries/028_create_table-linux_host_settings.sql and LINUX_HOST_SETTING_BOUNDS in
# api/config.py. A value that lands here governs whether user sessions get reclaimed, so it
# is re-checked at the edge rather than trusted from the caller. All three must agree.
# ---------------------------------------------------------------------------
INTEGER_SETTINGS=(
    "GracePeriodSeconds|60|86400|1200"
    "ReconcileIntervalSeconds|30|900|60"
    "WatcherDebounceSeconds|1|300|10"
    "WatcherSettleSeconds|0|60|2"
    "IdleTimeoutSeconds|0|86400|0"
    "IdleWarningSeconds|0|900|120"
    "ScreenIdleDelaySeconds|0|86400|0"
    "ScreenLockDelaySeconds|0|86400|0"
)

BOOLEAN_SETTINGS=(
    "ScreenLockEnabled|true"
    "ScreenLockSettingsLocked|true"
)

# IdleTimeoutSeconds treats 0 as "disabled"; any other value must clear this floor so a bad
# value cannot start disconnecting active users almost immediately.
IDLE_TIMEOUT_MINIMUM_SECONDS=300

declare -A SETTING_VALUES=()
SETTINGS_VERSION=1

setting_name_to_variable() {
    # GracePeriodSeconds -> LINUXBROKER_GRACE_PERIOD_SECONDS
    local name="$1"
    local snake

    snake=$(echo "$name" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' | tr '[:lower:]' '[:upper:]')
    echo "LINUXBROKER_$snake"
}

load_defaults() {
    local entry name default

    for entry in "${INTEGER_SETTINGS[@]}"; do
        IFS='|' read -r name _min _max default <<< "$entry"
        SETTING_VALUES["$name"]="$default"
    done

    for entry in "${BOOLEAN_SETTINGS[@]}"; do
        IFS='|' read -r name default <<< "$entry"
        SETTING_VALUES["$name"]="$default"
    done

    SETTINGS_VERSION=1
}

clamp_integer() {
    local name="$1" value="$2" minimum="$3" maximum="$4" default="$5"

    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        log "WARNING: $name value '$value' is not an integer. Falling back to $default."
        echo "$default"
        return
    fi

    if [ "$name" = "IdleTimeoutSeconds" ]; then
        if [ "$value" -eq 0 ]; then
            echo 0
            return
        fi

        if [ "$value" -lt "$IDLE_TIMEOUT_MINIMUM_SECONDS" ]; then
            log "WARNING: $name value $value is below the $IDLE_TIMEOUT_MINIMUM_SECONDS second floor. Clamping."
            echo "$IDLE_TIMEOUT_MINIMUM_SECONDS"
            return
        fi
    fi

    if [ "$value" -lt "$minimum" ]; then
        log "WARNING: $name value $value is below the supported minimum $minimum. Clamping."
        echo "$minimum"
        return
    fi

    if [ "$value" -gt "$maximum" ]; then
        log "WARNING: $name value $value is above the supported maximum $maximum. Clamping."
        echo "$maximum"
        return
    fi

    echo "$value"
}

normalize_boolean() {
    local name="$1" value="$2" default="$3"

    case "$(echo "$value" | tr '[:upper:]' '[:lower:]')" in
        true|1) echo 'true' ;;
        false|0) echo 'false' ;;
        *)
            log "WARNING: $name value '$value' is not a boolean. Falling back to $default."
            echo "$default"
            ;;
    esac
}

parse_settings_document() {
    local document="$1"
    local entry name minimum maximum default raw known_keys unknown_keys

    if ! command -v jq >/dev/null 2>&1; then
        fail "jq is required to parse the settings document."
    fi

    if ! echo "$document" | jq -e 'type == "object"' >/dev/null 2>&1; then
        fail "The settings document must be a JSON object."
    fi

    known_keys=$(
        {
            for entry in "${INTEGER_SETTINGS[@]}"; do echo "${entry%%|*}"; done
            for entry in "${BOOLEAN_SETTINGS[@]}"; do echo "${entry%%|*}"; done
            echo "SettingsVersion"
        } | sort
    )

    unknown_keys=$(echo "$document" | jq -r 'keys[]' | sort | comm -23 - <(echo "$known_keys"))

    if [ -n "$unknown_keys" ]; then
        fail "Unknown settings key(s): $(echo "$unknown_keys" | tr '\n' ' ')"
    fi

    for entry in "${INTEGER_SETTINGS[@]}"; do
        IFS='|' read -r name minimum maximum default <<< "$entry"
        raw=$(echo "$document" | jq -r --arg key "$name" '.[$key] // empty')

        if [ -z "$raw" ]; then
            SETTING_VALUES["$name"]="$default"
        else
            SETTING_VALUES["$name"]=$(clamp_integer "$name" "$raw" "$minimum" "$maximum" "$default")
        fi
    done

    for entry in "${BOOLEAN_SETTINGS[@]}"; do
        IFS='|' read -r name default <<< "$entry"
        raw=$(echo "$document" | jq -r --arg key "$name" 'if has($key) then .[$key] else empty end')

        if [ -z "$raw" ]; then
            SETTING_VALUES["$name"]="$default"
        else
            SETTING_VALUES["$name"]=$(normalize_boolean "$name" "$raw" "$default")
        fi
    done

    raw=$(echo "$document" | jq -r '.SettingsVersion // empty')
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 1 ]; then
        SETTINGS_VERSION="$raw"
    else
        SETTINGS_VERSION=1
    fi

    # The warning must land before the disconnect, otherwise users get no notice at all.
    if [ "${SETTING_VALUES[IdleTimeoutSeconds]}" -ne 0 ] && \
       [ "${SETTING_VALUES[IdleWarningSeconds]}" -ge "${SETTING_VALUES[IdleTimeoutSeconds]}" ]; then
        log "WARNING: IdleWarningSeconds is not less than IdleTimeoutSeconds. Disabling the warning."
        SETTING_VALUES[IdleWarningSeconds]=0
    fi
}

# Writes content to a path only when it differs, and reports whether it changed. This is
# what keeps the script idempotent and avoids needless systemd reloads.
write_if_changed() {
    local path="$1" content="$2" mode="$3"
    local directory

    directory=$(dirname "$path")
    mkdir -p "$directory"

    if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
        chmod "$mode" "$path"
        return 1
    fi

    printf '%s\n' "$content" > "$path.tmp"
    chmod "$mode" "$path.tmp"
    mv -f "$path.tmp" "$path"
    return 0
}

remove_if_present() {
    local path="$1"

    if [ -e "$path" ]; then
        rm -f "$path"
        return 0
    fi

    return 1
}

write_settings_file() {
    local content="" entry name variable

    content+="# Managed by apply-host-settings.sh. Manual edits are overwritten."$'\n'
    content+="LINUXBROKER_SETTINGS_VERSION=$SETTINGS_VERSION"$'\n'

    for entry in "${INTEGER_SETTINGS[@]}" "${BOOLEAN_SETTINGS[@]}"; do
        name="${entry%%|*}"
        variable=$(setting_name_to_variable "$name")
        content+="$variable=${SETTING_VALUES[$name]}"$'\n'
    done

    # Trailing newline is added by printf in write_if_changed.
    content="${content%$'\n'}"

    mkdir -p "$SETTINGS_DIRECTORY"
    chmod 755 "$SETTINGS_DIRECTORY"

    if write_if_changed "$SETTINGS_FILE" "$content" 644; then
        log "Updated $SETTINGS_FILE to settings version $SETTINGS_VERSION."
    fi
}

apply_dconf_settings() {
    local content locks_content dconf_changed=1

    if [ ! -d /etc/dconf ]; then
        log "dconf is not present on this host. Skipping screen lock policy."
        return 0
    fi

    # Without a profile that references the local system database, the keyfile below is
    # never consulted. Earlier revisions installed the keyfile but not the profile.
    content="user-db:user"$'\n'"system-db:local"
    mkdir -p "$DCONF_PROFILE_DIRECTORY"
    if write_if_changed "$DCONF_PROFILE_FILE" "$content" 644; then
        log "Wrote dconf profile $DCONF_PROFILE_FILE."
        dconf_changed=0
    fi

    mkdir -p "$DCONF_LOCAL_DIRECTORY" "$DCONF_LOCKS_DIRECTORY"

    content="# Managed by apply-host-settings.sh. Manual edits are overwritten."$'\n'
    content+="[org/gnome/desktop/session]"$'\n'
    content+="idle-delay=uint32 ${SETTING_VALUES[ScreenIdleDelaySeconds]}"$'\n'
    content+=$'\n'
    content+="[org/gnome/desktop/screensaver]"$'\n'
    content+="lock-enabled=${SETTING_VALUES[ScreenLockEnabled]}"$'\n'
    content+="lock-delay=uint32 ${SETTING_VALUES[ScreenLockDelaySeconds]}"
    if write_if_changed "$DCONF_SCREENSAVER_FILE" "$content" 644; then
        log "Updated screen lock policy in $DCONF_SCREENSAVER_FILE."
        dconf_changed=0
    fi

    if [ "${SETTING_VALUES[ScreenLockSettingsLocked]}" = "true" ]; then
        locks_content="# Managed by apply-host-settings.sh. Manual edits are overwritten."$'\n'
        locks_content+="/org/gnome/desktop/session/idle-delay"$'\n'
        locks_content+="/org/gnome/desktop/screensaver/lock-enabled"$'\n'
        locks_content+="/org/gnome/desktop/screensaver/lock-delay"
        if write_if_changed "$DCONF_SCREENSAVER_LOCKS_FILE" "$locks_content" 644; then
            log "Locked screen lock keys so users cannot override them."
            dconf_changed=0
        fi
    else
        if remove_if_present "$DCONF_SCREENSAVER_LOCKS_FILE"; then
            log "Removed screen lock key locks so users can override them."
            dconf_changed=0
        fi
    fi

    if [ "$dconf_changed" -eq 0 ]; then
        if command -v dconf >/dev/null 2>&1; then
            if dconf update >/dev/null 2>&1; then
                log "Compiled the dconf system database."
            else
                log "WARNING: 'dconf update' failed. Screen lock policy may not be active."
            fi
        else
            log "WARNING: the dconf CLI is unavailable, so the policy was written but not compiled."
        fi
    fi
}

apply_systemd_settings() {
    local content units_changed=1

    if ! command -v systemctl >/dev/null 2>&1; then
        log "systemd is unavailable. Skipping timer and watcher configuration."
        return 0
    fi

    # Drop-ins rather than edits to the unit files, so a later CSE or migration run that
    # rewrites the units does not silently discard these values. Both OnUnitActiveSec and
    # Environment are list-valued, so each must be cleared before being set.
    #
    # The empty OnUnitActiveSec= assignment resets the timer's ENTIRE value list, not just
    # that one directive, so OnBootSec must be restated here or it is lost. Without it the
    # timer has only OnUnitActiveSec, which is relative to the triggered unit's last
    # activation; after a reboot that base is zero, the value is skipped, and the timer would
    # never fire again. The value matches the base units created by the CSEs.
    content="# Managed by apply-host-settings.sh. Manual edits are overwritten."$'\n'
    content+="[Timer]"$'\n'
    content+="OnUnitActiveSec="$'\n'
    content+="OnBootSec=1min"$'\n'
    content+="OnUnitActiveSec=${SETTING_VALUES[ReconcileIntervalSeconds]}s"
    mkdir -p "$RELEASE_TIMER_DROPIN_DIRECTORY"
    if write_if_changed "$RELEASE_TIMER_DROPIN" "$content" 644; then
        log "Set the reconcile interval to ${SETTING_VALUES[ReconcileIntervalSeconds]} seconds."
        units_changed=0
    fi

    content="# Managed by apply-host-settings.sh. Manual edits are overwritten."$'\n'
    content+="[Service]"$'\n'
    content+="Environment="$'\n'
    content+="Environment=LINUXBROKER_LOGIND_WATCHER_DEBOUNCE_SECONDS=${SETTING_VALUES[WatcherDebounceSeconds]}"$'\n'
    content+="Environment=LINUXBROKER_LOGIND_WATCHER_SETTLE_SECONDS=${SETTING_VALUES[WatcherSettleSeconds]}"
    mkdir -p "$WATCHER_DROPIN_DIRECTORY"
    if write_if_changed "$WATCHER_DROPIN" "$content" 644; then
        log "Set watcher debounce to ${SETTING_VALUES[WatcherDebounceSeconds]}s and settle to ${SETTING_VALUES[WatcherSettleSeconds]}s."
        units_changed=0
    fi

    if [ "$units_changed" -ne 0 ]; then
        return 0
    fi

    if ! systemctl daemon-reload; then
        log "WARNING: 'systemctl daemon-reload' failed. Timer and watcher changes are written but not loaded."
        return 0
    fi

    # --no-block matters here. This script can be invoked by release-session.sh, which may
    # itself have been started by the watcher service, so a blocking restart could wait on a
    # unit that is in the middle of terminating this very process. Everything durable has
    # already been written by this point, and the watcher has Restart=always.
    if systemctl is-enabled "$RELEASE_TIMER_NAME" >/dev/null 2>&1; then
        systemctl restart --no-block "$RELEASE_TIMER_NAME" || log "WARNING: failed to restart $RELEASE_TIMER_NAME."
    fi

    if systemctl is-enabled "$WATCHER_SERVICE_NAME" >/dev/null 2>&1; then
        systemctl restart --no-block "$WATCHER_SERVICE_NAME" || log "WARNING: failed to restart $WATCHER_SERVICE_NAME."
    fi
}

main() {
    local mode="stdin"
    local document=""
    local argument

    for argument in "$@"; do
        case "$argument" in
            --defaults)
                mode="defaults"
                ;;
            *)
                fail "Unsupported argument: $argument"
                ;;
        esac
    done

    if [ "$mode" = "defaults" ]; then
        load_defaults
        log "Applying built-in default settings."
    else
        document=$(cat)

        if [ -z "${document//[[:space:]]/}" ]; then
            fail "No settings document was supplied on stdin."
        fi

        load_defaults
        parse_settings_document "$document"
    fi

    write_settings_file
    apply_dconf_settings
    apply_systemd_settings

    log "Applied settings version $SETTINGS_VERSION."
    printf 'Applied Linux Broker host settings version %s on %s\n' "$SETTINGS_VERSION" "$(hostname)"
}

main "$@"
