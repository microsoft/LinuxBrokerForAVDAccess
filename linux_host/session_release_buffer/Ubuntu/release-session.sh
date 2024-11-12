#!/bin/bash

# Support for Ubuntu systems

# Set PATH variable
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG_FILE="/var/log/release-session.log"
LOCK_FILE="/tmp/release-session.lockfile"
LOCATION_PATH="/usr/local/bin"
SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO="$LOCATION_PATH/xrdp-who-xnc.sh"
CURRENT_USERS_DETAILS="$LOCATION_PATH/xrdp-loggedin-users.txt"
PREVIOUS_USERS_FILE="/tmp/previous_users.txt"
hostname=$(hostname)

# Default run mode
RUN_MODE="manual"

# Check for '--cron' argument
for arg in "$@"; do
    if [ "$arg" == "--cron" ]; then
        RUN_MODE="cron"
        break
    fi
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [$RUN_MODE] - $1" | tee -a "$LOG_FILE"
}

log "Script started, lock acquired."

trap "log 'Script exiting.'" EXIT INT TERM

get_access_token() {
    local resource="api://YOUR_LINUX_BROKER_API_CLIENT_ID"  # Replace with actual client ID
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

release_vm() {
    local api_base_url="https://YOUR_LINUX_BROKER_API_URL/api"  # Replace with actual API URL
    local release_vm_url="$api_base_url/vms/$hostname/release"
    local access_token=$(get_access_token)

    if [ -z "$access_token" ]; then
        log "ERROR: Unable to obtain access token."
        exit 1
    fi

    local response=$(/usr/bin/curl -s -w "%{http_code}" -o response.json -X POST "$release_vm_url" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json")

    local http_status=$(tail -n1 response.json)
    local json_hostname=$(echo "$http_status" | /usr/bin/jq -r '.Hostname')

    if [ "$json_hostname" == "$hostname" ]; then
        log "INFO: Successfully released VM with Hostname: $hostname"
        cat response.json >> "$LOG_FILE"
    else
        log "ERROR: Failed to release VM with Hostname: $hostname (HTTP Status: $http_status)"
        cat response.json >> "$LOG_FILE"
    fi

    # Adjusted to account for possible case differences in process name
    local xvnc_pid=$(ps h -C Xvnc -o pid,user 2>/dev/null | awk -v user="$username" '$2 == user {print $1}')
    if [ -z "$xvnc_pid" ]; then
        # Try lowercase 'xvnc' if 'Xvnc' didn't yield results
        xvnc_pid=$(ps h -C xvnc -o pid,user 2>/dev/null | awk -v user="$username" '$2 == user {print $1}')
    fi

    log "Xvnc PID for user $username: $xvnc_pid"
    if [ -n "$xvnc_pid" ]; then
        kill -9 "$xvnc_pid" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "Terminated Xvnc process $xvnc_pid for user $username."
        else
            log "ERROR: Failed to terminate Xvnc process $xvnc_pid for user $username."
        fi
    else
        log "No Xvnc process found for user $username."
    fi

    rm -f response.json
}

logoff_user() {
    local username=$1

    (
        log "User $username disconnected. Scheduling logoff in 20 minutes."
        sleep 1200  # 20 minutes

        local is_logged_in=$(loginctl list-users | awk -v user="$username" '$2 == user {print $2}')

        if [ -z "$is_logged_in" ]; then
            local session_ids=$(loginctl list-sessions | grep "$username" | awk '{print $1}')

            for session_id in $session_ids; do
                loginctl terminate-session "$session_id"
                if [ $? -eq 0 ]; then
                    log "Logged off user $username session $session_id after 20 minutes delay."
                else
                    log "ERROR: Failed to log off user $username session $session_id."
                fi
            done

        else
            log "User $username is now logged in. Cancelling scheduled logoff."
        fi
    ) &
}

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    log "jq not found. Installing jq..."
    sudo apt update -y && sudo apt install -y jq
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to install jq."
        exit 1
    fi
    log "jq installed successfully."
fi

while true; do
    log "Checking XRDP session status."

    if ! . "$SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO" > "$CURRENT_USERS_DETAILS"; then
        log "ERROR: Failed to execute $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO"
        sleep 60
        continue
    fi

    log "Contents of $CURRENT_USERS_DETAILS:"
    cat "$CURRENT_USERS_DETAILS" | tee -a "$LOG_FILE"

    current_users=()

    while IFS= read -r line; do
        pid=$(echo "$line" | awk '{print $1}')
        username=$(echo "$line" | awk '{print $2}')
        start_time=$(echo "$line" | awk '{print $3}')
        status=$(echo "$line" | awk '{print $NF}' | xargs)
        current_users+=("$username")

        if [[ -n "$start_time" && "$start_time" != *"START_TIME"* ]]; then
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

    > "$CURRENT_USERS_DETAILS"

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
