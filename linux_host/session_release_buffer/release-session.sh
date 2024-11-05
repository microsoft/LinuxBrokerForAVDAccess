#!/bin/bash

# Lock file to prevent overlapping script runs
LOCK_FILE="/tmp/release-session.lock"

# Check if the lock file exists
if [ -e "$LOCK_FILE" ]; then
    echo "Another instance of the script is already running. Exiting."
    exit 1
fi

# Create the lock file
touch "$LOCK_FILE"

# Ensure the lock file is removed when the script exits or crashes (except for kill -9)
trap "rm -f $LOCK_FILE" EXIT INT TERM

# Monitors the status of XRDP sessions and calls an API when a user disconnects

# Path to the script that checks xrdp users and the file for output
SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO="xrdp-who-xnc.sh"
CURRENT_USERS_DETAILS="xrdp-loggedin-users.txt"

# Get the current Linux hostname
hostname=$(hostname)

# Function to check Azure login status and obtain access token using Managed Identity
get_access_token() {
    local resource=$1
    local imds_endpoint="http://169.254.169.254/metadata/identity/oauth2/token"
    local api_version="2018-02-01"
    local uri="$imds_endpoint?api-version=$api_version&resource=$resource"

    local headers="Metadata:true"
    local access_token=$(curl -s --header "$headers" "$uri" | jq -r '.access_token')

    if [ "$access_token" == "null" ]; then
        echo "ERROR: Failed to obtain access token."
        exit 1
    fi

    echo "$access_token"
}

# Function to call the API to release a VM
release_vm() {
    local api_base_url="https://linuxbroker-api2.azurewebsites.net/api"
    local release_vm_url="$api_base_url/vms/$hostname/release"

    # Obtain the access token
    local access_token=$(get_access_token "api://4c1b2eb9-92bd-49c4-bee2-c007f1908d96")

    if [ -z "$access_token" ]; then
        echo "ERROR: Unable to obtain access token."
        exit 1
    fi

    # Call the API using the access token
    local response=$(curl -s -w "%{http_code}" -o response.json -X POST "$release_vm_url" \
        -H "Authorization: Bearer $access_token" \
        -H "Content-Type: application/json")

    local http_status=$(tail -n1 response.json)

    if [ "$http_status" -eq 200 ]; then
        echo "INFO: Successfully released VM with Hostname: $hostname"
        cat response.json
    else
        echo "ERROR: Failed to release VM with Hostname: $hostname (HTTP Status: $http_status)"
        cat response.json
    fi

    rm -f response.json
}

# Function to log off the user with a re-check mechanism
logoff_user() {
    local username=$1

    # Execute the logoff in a background subshell
    (
        # Wait for 20 minutes
        echo "User $username disconnected. Scheduling logoff in 20 minutes."
        sleep 1200

        # Re-check if the user is logged in
        local is_logged_in=$(loginctl list-users | awk -v user="$username" '$2 == user {print $2}')

        if [ -z "$is_logged_in" ]; then
            # User is still logged off, proceed to log them off
            local session_ids=$(loginctl list-sessions | grep $username | awk '{print $1}')

            for session_id in $session_ids; do
                loginctl terminate-session $session_id
                echo "Logged off user $username session $session_id after 20 minutes delay."
            done
        else
            # User has logged back in, cancel logoff
            echo "User $username is now logged in. Cancelling scheduled logoff."
        fi
    ) &
}

# Main loop to monitor XRDP sessions and take action on disconnections
while true; do
    # Execute the script to check xrdp logged-in users and redirect output
    if ! . $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO > $CURRENT_USERS_DETAILS; then
        echo "ERROR: Failed to execute $SCRIPT_PATH_TO_CHECK_XRDP_USERS_INFO"
        sleep 60
        continue
    fi

    # Read the output file line by line
    while IFS=, read -r pid username start_time status; do
        # Trim potential leading/trailing whitespace from status
        status=$(echo $status | xargs)

        # Check if the user is disconnected and take action
        if [[ "$status" == "disconnected" ]]; then
            # Call `release_vm` using the current hostname
            release_vm

            # Log off the user after scheduling
            logoff_user "$username"
        fi
    done < "$CURRENT_USERS_DETAILS"

    sleep 60 # Check every 60 seconds
done
