#!/bin/bash

LOG_FILE="/var/log/release-session.log"
LOCK_FILE="/tmp/release-session.lockfile"
LOCATION_PATH="/usr/local/bin"
SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO="$LOCATION_PATH/xrdp-who-xnc.sh"
CURRENT_USERS_DETAILS="$LOCATION_PATH/xrdp-loggedin-users.txt"
PREVIOUS_USERS_FILE="/tmp/previous_users.txt"
hostname=$(hostname)

parent_cmd=$(ps -p $PPID -o cmd=)
if echo "$parent_cmd" | grep -q "cron"; then
    RUN_MODE="cron"
else
    RUN_MODE="manual"
fi

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [$RUN_MODE] - $1" | tee -a "$LOG_FILE"
}

# Use flock for locking
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "Another instance of the script is already running. Exiting."
    exit 1
fi

log "Script started, lock acquired."

trap "log 'Script exiting.'" EXIT INT TERM

get_access_token() {
    local resource="api://YOUR_LINUX_BROKER_API_CLIENT_ID"
    local imds_endpoint="http://169.254.169.254/metadata/identity/oauth2/token"
    local api_version="2018-02-01"
    local uri="$imds_endpoint?api-version=$api_version&resource=$resource"

    local headers="Metadata:true"
    local access_token=$(curl -s --header "$headers" "$uri" | jq -r '.access_token')

    if [ "$access_token" == "null" ]; then
        log "ERROR: Failed to obtain access token."
        exit 1
    fi

    echo "$access_token"
}

release_vm() {
    local api_base_url="https://YOUR_LINUX_BROKER_API_URL/api"
    local release_vm_url="$api_base_url/vms/$hostname/release"
    local access_token=$(get_access_token)

    if [ -z "$access_token" ]; then
        log "ERROR: Unable to obtain access token."
        exit 1
    fi

    local response=$(curl -s -w "%{http_code}" -o response.json -X POST "$release_vm_url" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json")

    local http_status=$(tail -n1 response.json)
    local json_hostname=$(echo "$http_status" | jq -r '.Hostname')

    if [ "$json_hostname" == "$hostname" ]; then
        log "INFO: Successfully released VM with Hostname: $hostname"
        cat response.json >> "$LOG_FILE"
    else
        log "ERROR: Failed to release VM with Hostname: $hostname (HTTP Status: $http_status)"
        cat response.json >> "$LOG_FILE"
    fi

    local xvnc_pid=$(ps h -C Xvnc -o pid,user | awk -v user="$username" '$2 == user {print $1}')
    log "Xvnc PID for user $username: $xvnc_pid"
    if [ -n "$xvnc_pid" ]; then
        sudo kill -9 $xvnc_pid
        log "Terminated Xvnc process $xvnc_pid for user $username."
    fi

    rm -f response.json
}

logoff_user() {
    local username=$1

    (
        log "User $username disconnected. Scheduling logoff in 20 minutes."
        sleep 1200

        local is_logged_in=$(loginctl list-users | awk -v user="$username" '$2 == user {print $2}')

        if [ -z "$is_logged_in" ]; then
            local session_ids=$(loginctl list-sessions | grep $username | awk '{print $1}')

            for session_id in $session_ids; do
                loginctl terminate-session $session_id
                log "Logged off user $username session $session_id after 20 minutes delay."
            done

        else
            log "User $username is now logged in. Cancelling scheduled logoff."
        fi
    ) &
}

while true; do
    log "Checking XRDP session status."

    if ! . $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO > $CURRENT_USERS_DETAILS; then
        log "ERROR: Failed to execute $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO"
        sleep 60
        continue
    fi

    log "Contents of $CURRENT_USERS_DETAILS:"
    cat $CURRENT_USERS_DETAILS | tee -a "$LOG_FILE"

    current_users=()

    while IFS= read -r line; do
        pid=$(echo $line | awk '{print $1}')
        username=$(echo $line | awk '{print $2}')
        start_time=$(echo $line | awk '{print $3}')
        status=$(echo $line | awk '{print $NF}' | xargs)
        current_users+=("$username")

        if ! [[ -z "$start_time" || "$start_time" == *"START_TIME"* ]]; then
            log "PID: $pid, Username: $username, Start Time: $start_time, Status: $status"
        fi

        if [[ "$status" == *"disconnected"* ]]; then
            log "User $username is disconnected. Calling release_vm and scheduling logoff."
            release_vm
            logoff_user "$username"

            current_users=("${current_users[@]/$username}")
            
            break
        elif [[ "$status" == *"active"* ]]; then
            log "User $username is active. No action to perform."
            break
        fi
    done < "$CURRENT_USERS_DETAILS"

    > $CURRENT_USERS_DETAILS

    if [ -e "$PREVIOUS_USERS_FILE" ]; then
        while IFS= read -r prev_user; do
            if [[ ! " ${current_users[@]} " =~ " ${prev_user} " ]]; then
                log "User $prev_user has no session record. Releasing VM for user $prev_user."
                release_vm
            fi
        done < "$PREVIOUS_USERS_FILE"
    fi

    printf "%s\n" "${current_users[@]}" > "$PREVIOUS_USERS_FILE"

    log "Sleeping for 60 seconds before next check."
    sleep 60
done

