#!/bin/bash

# Support for RHEL systems

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="/var/log/release-session.log"
LOCATION_PATH="/usr/local/bin"
XORG_USERS_INFO_SCRIPT="$LOCATION_PATH/xrdp-who-xorg.sh"
STATE_DIRECTORY="/var/lib/linuxbroker-release-session"
LEASE_DIRECTORY="$STATE_DIRECTORY/leases"
CURRENT_USERS_DETAILS="$STATE_DIRECTORY/current_users.txt"
PREVIOUS_USERS_FILE="$STATE_DIRECTORY/previous_users.txt"
DISCONNECTED_USERS_FILE="$STATE_DIRECTORY/disconnected_users.tsv"
LOCK_FILE="$STATE_DIRECTORY/reconcile.lock"
hostname=$(hostname)
GRACE_PERIOD_SECONDS=1200
LOCK_FD=""

RUN_MODE="manual"

for arg in "$@"; do
    case "$arg" in
        --systemd-timer)
            RUN_MODE="systemd-timer"
            ;;
        --logind-watcher)
            RUN_MODE="logind-watcher"
            ;;
        --cron)
            RUN_MODE="cron"
            ;;
    esac
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [$RUN_MODE] - $1" | tee -a "$LOG_FILE"
}

ensure_state_files() {
    mkdir -p "$STATE_DIRECTORY"
    touch "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
    chmod 600 "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
}

acquire_reconcile_lock() {
    mkdir -p "$STATE_DIRECTORY"
    exec {LOCK_FD}> "$LOCK_FILE"

    if ! flock -n "$LOCK_FD"; then
        log "Another reconciliation run is already in progress. Skipping this invocation."
        eval "exec ${LOCK_FD}>&-"
        LOCK_FD=""
        exit 0
    fi
}

release_reconcile_lock() {
    if [ -n "$LOCK_FD" ]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-"
        LOCK_FD=""
    fi
}

resolve_xrdp_users_info_script() {
    if [ -x "$XORG_USERS_INFO_SCRIPT" ]; then
        echo "$XORG_USERS_INFO_SCRIPT"
        return 0
    fi

    return 1
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

get_disconnect_timestamp() {
    local username="$1"

    awk -F '\t' -v user="$username" '$1 == user {print $2; exit}' "$DISCONNECTED_USERS_FILE"
}

upsert_disconnect_timestamp() {
    local username="$1"
    local timestamp="$2"
    local tmp_file

    tmp_file=$(mktemp)
    awk -F '\t' -v user="$username" '$1 != user' "$DISCONNECTED_USERS_FILE" > "$tmp_file"
    printf '%s\t%s\n' "$username" "$timestamp" >> "$tmp_file"
    mv "$tmp_file" "$DISCONNECTED_USERS_FILE"
    chmod 600 "$DISCONNECTED_USERS_FILE"
}

clear_disconnect_timestamp() {
    local username="$1"
    local tmp_file

    tmp_file=$(mktemp)
    awk -F '\t' -v user="$username" '$1 != user' "$DISCONNECTED_USERS_FILE" > "$tmp_file"
    mv "$tmp_file" "$DISCONNECTED_USERS_FILE"
    chmod 600 "$DISCONNECTED_USERS_FILE"
}

terminate_session_processes() {
    local username="$1"
    local found_process="false"

    while IFS=: read -r pid process_name; do
        [ -z "$pid" ] && continue

        found_process="true"
        log "$process_name PID for user $username: $pid"

        if kill -9 "$pid" 2>/dev/null; then
            log "Terminated $process_name process $pid for user $username."
        else
            log "ERROR: Failed to terminate $process_name process $pid for user $username."
        fi
    done < <(
        ps h -C Xorg -o pid=,user=,comm= 2>/dev/null | awk -v user="$username" '$2 == user {print $1 ":" $3}'
    )

    if [ "$found_process" != "true" ]; then
        log "No XRDP session process found for user $username."
    fi
}

get_access_token() {
    local resource="api://YOUR_LINUX_BROKER_API_CLIENT_ID"
    local imds_endpoint="http://169.254.169.254/metadata/identity/oauth2/token"
    local api_version="2018-02-01"
    local uri="$imds_endpoint?api-version=$api_version&resource=$resource"

    local headers="Metadata:true"
    local access_token=$(/usr/bin/curl -s --header "$headers" "$uri" | /usr/bin/jq -r '.access_token')

    if [ "$access_token" == "null" ] || [ -z "$access_token" ]; then
        log "ERROR: Failed to obtain access token."
        exit 1
    fi

    echo "$access_token"
}

get_current_lease_id() {
    local username="$1"
    local lease_file="$LEASE_DIRECTORY/$username.lease"

    if [ ! -f "$lease_file" ]; then
        return 1
    fi

    tr -d '\r\n' < "$lease_file"
}

release_vm() {
    local username="$1"
    local api_base_url="YOUR_LINUX_BROKER_API_BASE_URL"
    local release_vm_url="$api_base_url/vms/$hostname/release"
    local access_token
    local lease_id=""
    local request_body
    local response_file
    local http_status
    local json_hostname
    local json_lease_id
    local release_status
    local release_succeeded=1

    access_token=$(get_access_token)

    if [ -z "$access_token" ]; then
        log "ERROR: Unable to obtain access token."
        exit 1
    fi

    if lease_id=$(get_current_lease_id "$username"); then
        request_body=$(/usr/bin/jq -cn --arg username "$username" --arg leaseId "$lease_id" '{username: $username, leaseId: $leaseId}')
    else
        log "No lease marker found for user $username. Falling back to username-only release."
        request_body=$(/usr/bin/jq -cn --arg username "$username" '{username: $username}')
    fi

    response_file=$(mktemp)

    http_status=$(/usr/bin/curl -s -w "%{http_code}" -o "$response_file" -X POST "$release_vm_url" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json" \
        -d "$request_body")

    json_hostname=$(/usr/bin/jq -r '.Hostname // empty' "$response_file" 2>/dev/null)
    json_lease_id=$(/usr/bin/jq -r '.LeaseId // empty' "$response_file" 2>/dev/null)
    release_status=$(/usr/bin/jq -r '.ReleaseStatus // empty' "$response_file" 2>/dev/null)

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        if [ "$release_status" == "NoActiveAssignment" ]; then
            log "INFO: VM $hostname already has no active assignment. Nothing to release for user $username."
            release_succeeded=0
        elif [ "$json_hostname" != "$hostname" ]; then
            log "ERROR: Release response returned Hostname '$json_hostname' but expected '$hostname'."
        elif [ -n "$lease_id" ] && [ "$json_lease_id" != "$lease_id" ]; then
            log "ERROR: Release response for $hostname returned LeaseId '$json_lease_id' but expected '$lease_id'."
        else
            log "INFO: Successfully released VM with Hostname: $hostname"
            release_succeeded=0
        fi
    elif [ "$http_status" == "409" ]; then
        # The broker reassigned this host, so retrying cannot succeed.
        log "INFO: Lease for user $username on $hostname is stale. Skipping further release attempts."
        release_succeeded=0
    elif [ "$http_status" == "404" ]; then
        log "ERROR: The broker does not recognize Hostname $hostname. Skipping further release attempts."
        release_succeeded=0
    else
        log "ERROR: Failed to release VM with Hostname: $hostname (HTTP Status: $http_status)"
    fi

    cat "$response_file" >> "$LOG_FILE"

    terminate_session_processes "$username"

    rm -f "$response_file"

    return "$release_succeeded"
}

terminate_logind_sessions() {
    local username="$1"
    local session_ids
    local session_id

    session_ids=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$username" '$3 == user {print $1}')

    if [ -z "$session_ids" ]; then
        log "No logind sessions found for user $username."
        return 0
    fi

    for session_id in $session_ids; do
        if loginctl terminate-session "$session_id"; then
            log "Logged off user $username session $session_id after grace period."
        else
            log "ERROR: Failed to log off user $username session $session_id."
        fi
    done
}

reconcile_disconnected_user() {
    local username="$1"
    local disconnected_at="$2"
    local now="$3"
    local elapsed=$((now - disconnected_at))
    local remaining

    if [ "$elapsed" -ge "$GRACE_PERIOD_SECONDS" ]; then
        log "User $username remained disconnected for $elapsed seconds. Terminating remaining sessions."
        terminate_logind_sessions "$username"
        clear_disconnect_timestamp "$username"
        return
    fi

    remaining=$((GRACE_PERIOD_SECONDS - elapsed))
    log "User $username is still disconnected. Grace period expires in $remaining seconds."
}

check_unmount_user_homes() {
    local username

    log "Scanning for orphaned mounted user home directories."

    mapfile -t logged_in_users < <(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}')

    while read -r device mountpoint fstype rest; do
        if [[ "$mountpoint" =~ ^/home/[^/]+$ ]]; then
            username=$(basename "$mountpoint")

            if ! array_contains "$username" "${logged_in_users[@]}"; then
                log "User $username is not logged in. Attempting to unmount $mountpoint"

                if umount -l "$mountpoint"; then
                    log "Successfully unmounted $mountpoint for user $username."
                else
                    log "Failed to unmount $mountpoint for user $username."
                fi
            else
                log "User $username is still logged in. Skipping unmount."
            fi
        fi
    done < <(mount | awk '$5 ~ /^nfs/ {print $1, $3, $5, $6}')
}

main() {
    local session_info_script
    local now
    local line
    local pid
    local username
    local start_time
    local status
    local disconnected_at
    local prev_user
    local current_users=()
    local previous_users=()

    ensure_state_files

    if ! session_info_script=$(resolve_xrdp_users_info_script); then
        log "ERROR: Failed to find an XRDP session inspection script."
        exit 1
    fi

    if ! "$session_info_script" > "$CURRENT_USERS_DETAILS"; then
        log "ERROR: Failed to execute $session_info_script"
        exit 1
    fi

    log "Contents of $CURRENT_USERS_DETAILS:"
    cat "$CURRENT_USERS_DETAILS" | tee -a "$LOG_FILE"

    mapfile -t previous_users < "$PREVIOUS_USERS_FILE"
    now=$(date +%s)

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        pid=$(echo "$line" | awk '{print $1}')
        username=$(echo "$line" | awk '{print $2}')
        start_time=$(echo "$line" | awk '{print $3}')
        status=$(echo "$line" | awk '{print $NF}' | xargs)

        if [ -z "$username" ] || [ "$pid" = "PID" ]; then
            continue
        fi

        current_users+=("$username")

        if ! [[ -z "$start_time" || "$start_time" == *"START_TIME"* ]]; then
            log "PID: $pid, Username: $username, Start Time: $start_time, Status: $status"
        fi

        disconnected_at=$(get_disconnect_timestamp "$username")

        if [[ "$status" == *"active"* ]]; then
            if [ -n "$disconnected_at" ]; then
                log "User $username reconnected. Clearing pending grace period."
                clear_disconnect_timestamp "$username"
            else
                log "User $username is active. No action to perform."
            fi
        elif [[ "$status" == *"disconnected"* ]]; then
            if [ -z "$disconnected_at" ]; then
                log "User $username is disconnected. Releasing VM and starting grace period."

                if release_vm "$username"; then
                    upsert_disconnect_timestamp "$username" "$now"
                else
                    log "ERROR: Release request failed for user $username. The agent will retry on the next run."
                fi
            else
                reconcile_disconnected_user "$username" "$disconnected_at" "$now"
            fi
        else
            log "User $username reported unexpected session status '$status'."
        fi
    done < "$CURRENT_USERS_DETAILS"

    for prev_user in "${previous_users[@]}"; do
        [ -z "$prev_user" ] && continue

        if ! array_contains "$prev_user" "${current_users[@]}"; then
            log "User $prev_user has no session record. Releasing VM for user $prev_user."
            release_vm "$prev_user" || true
            clear_disconnect_timestamp "$prev_user"
        fi
    done

    if [ "${#current_users[@]}" -gt 0 ]; then
        printf "%s\n" "${current_users[@]}" > "$PREVIOUS_USERS_FILE"
    else
        : > "$PREVIOUS_USERS_FILE"
    fi

    chmod 600 "$PREVIOUS_USERS_FILE"

    check_unmount_user_homes

    log "Script completed."
}

acquire_reconcile_lock
log "Script started."
trap "release_reconcile_lock; log 'Script exiting.'" EXIT INT TERM

main

