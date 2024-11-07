#!/bin/bash

LOG_FILE="/var/log/release-session.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

LOCK_FILE="/tmp/release-session.lock"

if [ -e "$LOCK_FILE" ]; then
    log "Another instance of the script is already running. Exiting."
    exit 1
fi

touch "$LOCK_FILE"
log "Script started, lock file created."

trap "rm -f $LOCK_FILE; log 'Script exiting, lock file removed.'" EXIT INT TERM

LOCATION_PATH="/usr/local/bin"
SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO="$LOCATION_PATH/xrdp-who-xnc.sh"
CURRENT_USERS_DETAILS="$LOCATION_PATH/xrdp-loggedin-users.txt"

hostname=$(hostname)

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

    if [ "$http_status" -eq 200 ]; then
        log "INFO: Successfully released VM with Hostname: $hostname"
        cat response.json >> "$LOG_FILE"
    else
        log "ERROR: Failed to release VM with Hostname: $hostname (HTTP Status: $http_status)"
        cat response.json >> "$LOG_FILE"
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

            local xvnc_pid=$(ps h -C Xvnc -o pid,user | awk -v user="$username" '$2 == user {print $1}')
            if [ -n "$xvnc_pid" ]; then
                sudo kill -9 $xvnc_pid
                log "Terminated Xvnc process $xvnc_pid for user $username."
            fi

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

    while IFS= read -r line; do
        log "Processing line: $line"
        pid=$(echo $line | awk '{print $1}')
        username=$(echo $line | awk '{print $2}')
        start_time=$(echo $line | awk '{print $3}')
        status=$(echo $line | awk '{print $NF}' | xargs)

        log "PID: $pid, Username: $username, Start Time: $start_time, Status: $status"

        if [[ "$status" == *"disconnected"* ]]; then
            log "User $username is disconnected. Calling release_vm and scheduling logoff."
            
            release_vm

            logoff_user "$username"
        fi
    done < "$CURRENT_USERS_DETAILS"

    > $CURRENT_USERS_DETAILS

    log "Sleeping for 60 seconds before next check."
    sleep 60
done

