#!/bin/bash

# Usage: ./manage-lease.sh read <USERNAME>
#        ./manage-lease.sh clear <USERNAME> <EXPECTED_LEASE_ID>
#        ./manage-lease.sh clear-any <USERNAME>
#
# Exists so the broker API never needs blanket sudo rights on cat or rm.

set -u

LEASE_DIRECTORY="/var/lib/linuxbroker-release-session/leases"

usage() {
    echo "Usage: $0 read <USERNAME>" >&2
    echo "       $0 clear <USERNAME> <EXPECTED_LEASE_ID>" >&2
    echo "       $0 clear-any <USERNAME>" >&2
    exit 2
}

# Rejects path traversal and any username the broker would never have created.
validate_username() {
    local username="$1"

    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "Invalid username." >&2
        exit 2
    fi
}

validate_lease_id() {
    local lease_id="$1"

    if [[ ! "$lease_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        echo "Invalid lease id." >&2
        exit 2
    fi
}

read_lease() {
    local lease_file="$1"

    if [ ! -f "$lease_file" ]; then
        return 1
    fi

    tr -d '\r\n' < "$lease_file"
    echo
}

[ $# -ge 2 ] || usage

ACTION="$1"
USERNAME="$2"
validate_username "$USERNAME"
LEASE_FILE="$LEASE_DIRECTORY/$USERNAME.lease"

case "$ACTION" in
    read)
        [ $# -eq 2 ] || usage
        read_lease "$LEASE_FILE"
        ;;
    clear)
        [ $# -eq 3 ] || usage
        EXPECTED_LEASE_ID="$3"
        validate_lease_id "$EXPECTED_LEASE_ID"

        CURRENT_LEASE_ID=$(read_lease "$LEASE_FILE" || true)
        CURRENT_LEASE_ID="${CURRENT_LEASE_ID//[$'\r\n']/}"

        if [ -z "$CURRENT_LEASE_ID" ]; then
            echo "__LEASE_ACTION=missing__"
            exit 0
        fi

        if [ "$CURRENT_LEASE_ID" != "$EXPECTED_LEASE_ID" ]; then
            echo "__LEASE_ACTION=mismatch__"
            exit 0
        fi

        rm -f "$LEASE_FILE"
        echo "__LEASE_ACTION=cleared__"
        ;;
    clear-any)
        [ $# -eq 2 ] || usage
        rm -f "$LEASE_FILE"
        echo "__LEASE_ACTION=cleared__"
        ;;
    *)
        usage
        ;;
esac
