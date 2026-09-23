#!/bin/bash

# Usage: ./manage-lease.sh read <USERNAME>
#        ./manage-lease.sh clear <USERNAME> <EXPECTED_LEASE_ID>
#        ./manage-lease.sh clear-any <USERNAME>
#
# Exists so the broker API never needs blanket sudo rights on cat, rm or umount.
#
# Clearing a lease also unmounts the user's NFS-backed home. The broker deletes the account
# with userdel -r straight afterwards, which would otherwise delete the profile on the share
# instead of the empty local mount point.

set -u

LEASE_DIRECTORY="/var/lib/linuxbroker-release-session/leases"
HOME_ROOT="/home"

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

user_is_signed_in() {
    local state

    state=$(loginctl show-user "$USERNAME" --property=State 2>/dev/null)
    state="${state#State=}"

    [ "$state" = "active" ] || [ "$state" = "online" ]
}

# A lazy unmount matches the release agent, and the loop covers more than one mount stacked
# on the same path.
unmount_user_home() {
    local home_directory="$HOME_ROOT/$USERNAME"
    local attempts=0

    while mountpoint -q "$home_directory"; do
        if [ "$attempts" -ge 5 ]; then
            echo "Unable to unmount $home_directory." >&2
            return 1
        fi

        umount -l "$home_directory" || true
        attempts=$((attempts + 1))
    done
}

release_lease() {
    if user_is_signed_in; then
        # Unmounting or deleting the account would pull the home out from under a live
        # session, so leave both. Without the lease, the RHEL release agent unmounts the
        # home once the user signs out. The Ubuntu agent never unmounts homes.
        rm -f "$LEASE_FILE"
        echo "__LEASE_ACTION=cleared-in-use__"
        return
    fi

    # Keep the lease on failure, so the release agent leaves the home alone and the broker
    # does not run userdel -r against it.
    unmount_user_home || exit 1

    rm -f "$LEASE_FILE"
    echo "__LEASE_ACTION=cleared__"
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

        release_lease
        ;;
    clear-any)
        [ $# -eq 2 ] || usage
        release_lease
        ;;
    *)
        usage
        ;;
esac
