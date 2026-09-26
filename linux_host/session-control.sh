#!/bin/bash

# Usage: ./session-control.sh signout <USERNAME>
#        ./session-control.sh message <USERNAME>        (the message text on stdin)
#        ./session-control.sh message-all               (the message text on stdin)
#        ./session-control.sh reset-profile <NFS_SHARE> <USERNAME>
#
# Lets the broker API sign a user out, show a message in xrdp sessions and reset a user's
# profile, without broader sudo rights. It follows manage-lease.sh: every argument is
# validated here, and the API reads the result from the __SESSION_CONTROL_*= lines.
#
# Only accounts the broker created are ever acted on: a UID of at least 1000 and membership of
# tsusers, which provisioning always adds. root and the management account are refused
# whatever the caller sends.

set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The Linux Broker host agent version. Every script in linux_host/ declares the same value
# and the heartbeat reports it; bump them together with HOST_AGENT_VERSION in api/config.py.
LINUXBROKER_AGENT_VERSION="1.2.0"

LEASE_DIRECTORY="/var/lib/linuxbroker-release-session/leases"
HOME_ROOT="/home"
BROKER_GROUP="tsusers"
MANAGEMENT_ACCOUNT="avdadmin"
MINIMUM_UID=1000
# The API sends at most 500 characters; this bounds the bytes that reach a session.
MESSAGE_MAX_BYTES=2000
MESSAGE_TITLE="Message from your administrator"
# The options create-user.sh mounts the share with.
NFS_OPTIONS="vers=4,minorversion=1,sec=sys,nconnect=4"
RESET_MOUNT_PARENT="/run/linuxbroker"
LOG_FILE="/var/log/linuxbroker-session-control.log"
# A wedged X server or a hung NFS home must not hold the broker's SSH call open.
PROBE_TIMEOUT_SECONDS=5
NOTIFY_TIMEOUT_SECONDS=10

usage() {
    echo "Usage: $0 signout <USERNAME>" >&2
    echo "       $0 message <USERNAME>" >&2
    echo "       $0 message-all" >&2
    echo "       $0 reset-profile <NFS_SHARE> <USERNAME>" >&2
    exit 2
}

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

result() {
    printf '__SESSION_CONTROL_%s=%s\n' "$1" "$2"
}

refuse() {
    log "Refused: $1"
    echo "$1" >&2
    result RESULT refused
    exit 3
}

validate_username() {
    if [[ ! "$1" =~ ^[a-zA-Z0-9_]{1,64}$ ]]; then
        echo "Invalid username." >&2
        exit 2
    fi
}

# host:/path, the form the broker passes to create-user.sh.
validate_nfs_share() {
    if [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:/[A-Za-z0-9._/-]*$ ]] || [[ "$1" == *..* ]]; then
        echo "Invalid NFS share." >&2
        exit 2
    fi
}

is_reserved_name() {
    [ "$1" = "root" ] || [ "$1" = "$MANAGEMENT_ACCOUNT" ]
}

# An existing account the broker provisioned. Anything else is refused.
require_broker_account() {
    local username="$1"
    local uid

    is_reserved_name "$username" && refuse "$username is not a broker user."

    uid=$(id -u "$username" 2>/dev/null) || return 1
    if [ "$uid" -lt "$MINIMUM_UID" ]; then
        refuse "$username is a system account."
    fi
    if [[ " $(id -nG "$username" 2>/dev/null) " != *" $BROKER_GROUP "* ]]; then
        refuse "$username is not a broker user."
    fi
    return 0
}

# "<pid> <uid>" for every xrdp X server on the host. Numeric UIDs avoid ps truncating long
# user names.
xrdp_sessions() {
    ps h -C Xorg -o pid=,uid=,args= 2>/dev/null | awk '/xrdp/ {print $1, $2}'
}

session_display() {
    tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -m1 -E '^:[0-9]+$'
}

# xrdp 0.9 passes a bare ".Xauthority", which is relative to the X server's working
# directory, the user's home. Resolving it stats that home, so it is bounded.
session_xauthority() {
    local pid="$1"
    local auth_path
    local cwd

    auth_path=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk '$0 == "-auth" { getline; print; exit }')
    [ -z "$auth_path" ] && return 0

    if [ "${auth_path#/}" = "$auth_path" ]; then
        cwd=$(timeout "$PROBE_TIMEOUT_SECONDS" readlink -f "/proc/$pid/cwd" 2>/dev/null)
        [ -n "$cwd" ] && auth_path="$cwd/$auth_path"
    fi

    echo "$auth_path"
}

# The message on stdin, without control characters other than newlines. A message that is
# empty or too long is refused rather than cut, which could split a multibyte character.
read_message() {
    local text

    text=$(head -c "$((MESSAGE_MAX_BYTES + 1))" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tr '\t' ' ')
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"

    if [ -z "$text" ]; then
        echo "The message is empty." >&2
        return 2
    fi

    if [ "$(printf '%s' "$text" | wc -c)" -gt "$MESSAGE_MAX_BYTES" ]; then
        echo "The message is too long." >&2
        return 2
    fi

    printf '%s' "$text"
}

# Notification daemons read the body as markup, so it is escaped for notify-send.
escape_markup() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Shows the message in one X session: a notification as its owner, or xmessage as a fallback.
# Both run as the session's owner, never as root: the display and its authority file come from
# a process the user owns, so connecting to them with root's privileges would let a user who
# fakes an X server have root run an X client against it.
deliver_to_session() {
    local pid="$1"
    local uid="$2"
    local username="$3"
    local message="$4"
    local display
    local xauthority

    command -v runuser >/dev/null 2>&1 || return 1

    display=$(session_display "$pid")
    [ -z "$display" ] && return 1
    xauthority=$(session_xauthority "$pid")

    if command -v notify-send >/dev/null 2>&1; then
        if DISPLAY="$display" XAUTHORITY="$xauthority" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
            timeout "$NOTIFY_TIMEOUT_SECONDS" runuser -u "$username" -- \
            notify-send --urgency=critical --app-name="Linux Broker" -- "$MESSAGE_TITLE" "$(escape_markup "$message")" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v xmessage >/dev/null 2>&1; then
        DISPLAY="$display" XAUTHORITY="$xauthority" \
            runuser -u "$username" -- xmessage -center -timeout 300 "$MESSAGE_TITLE: $message" >/dev/null 2>&1 &
        return 0
    fi

    return 1
}

# Delivers to every xrdp session, or to one user's. Only broker users are messaged.
send_message() {
    local target_user="$1"
    local message
    local target_uid=""
    local pid
    local uid
    local username
    local sessions=0
    local delivered=0

    message=$(read_message) || exit 2

    if [ -n "$target_user" ]; then
        if ! require_broker_account "$target_user"; then
            result RESULT no-session
            result SESSIONS 0
            result DELIVERED 0
            exit 0
        fi
        target_uid=$(id -u "$target_user")
    fi

    while read -r pid uid; do
        [ -z "$pid" ] && continue
        [ -n "$target_uid" ] && [ "$uid" != "$target_uid" ] && continue
        [ "$uid" -ge "$MINIMUM_UID" ] 2>/dev/null || continue

        username=$(getent passwd "$uid" | cut -d: -f1)
        [ -z "$username" ] && continue
        is_reserved_name "$username" && continue
        [[ " $(id -nG "$username" 2>/dev/null) " == *" $BROKER_GROUP "* ]] || continue

        sessions=$((sessions + 1))
        if deliver_to_session "$pid" "$uid" "$username" "$message"; then
            delivered=$((delivered + 1))
        fi
    done < <(xrdp_sessions)

    log "Message delivered to $delivered of $sessions session(s)${target_user:+ for $target_user}."

    if [ "$sessions" -eq 0 ]; then
        result RESULT no-session
    else
        result RESULT delivered
    fi
    result SESSIONS "$sessions"
    result DELIVERED "$delivered"
}

signout() {
    local username="$1"
    local uid
    local pid
    local session_uid
    local attempts=0

    if ! require_broker_account "$username"; then
        result RESULT no-session
        exit 0
    fi
    uid=$(id -u "$username")

    if ! pgrep -u "$username" >/dev/null 2>&1; then
        result RESULT no-session
        exit 0
    fi

    # Ends every session and process of the user. The lease and the account stay: the
    # broker releases and cleans the host itself.
    loginctl terminate-user "$username" >/dev/null 2>&1 || true

    while read -r pid session_uid; do
        [ "$session_uid" = "$uid" ] && kill -TERM "$pid" 2>/dev/null
    done < <(xrdp_sessions)
    pkill -TERM -u "$username" >/dev/null 2>&1 || true

    while pgrep -u "$username" >/dev/null 2>&1; do
        if [ "$attempts" -ge 5 ]; then
            pkill -KILL -u "$username" >/dev/null 2>&1 || true
            sleep 1
            if pgrep -u "$username" >/dev/null 2>&1; then
                log "Processes are still running for $username after sign-out."
                result RESULT signout-incomplete
                exit 1
            fi
            break
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    log "Signed out $username."
    result RESULT signed-out
}

RESET_MOUNT_DIR=""

cleanup_reset_mount() {
    if [ -n "$RESET_MOUNT_DIR" ]; then
        umount "$RESET_MOUNT_DIR" >/dev/null 2>&1 || umount -l "$RESET_MOUNT_DIR" >/dev/null 2>&1 || true
        # rmdir, never rm -r: if the unmount failed this is still the share.
        rmdir "$RESET_MOUNT_DIR" >/dev/null 2>&1 || true
        RESET_MOUNT_DIR=""
    fi
}

# Renames the user's home on the share so the next checkout creates a fresh profile. The
# broker runs this during a checkout, on the host it just assigned, before create-user.sh
# mounts the home, so nothing can be using the profile.
reset_profile() {
    local nfs_share="$1"
    local username="$2"
    local profile
    local resolved
    local mount_root
    local target
    local suffix=1

    is_reserved_name "$username" && refuse "$username is not a broker user."
    if id -u "$username" >/dev/null 2>&1; then
        require_broker_account "$username"
        if pgrep -u "$username" >/dev/null 2>&1; then
            result RESULT profile-in-use
            exit 3
        fi
    fi

    if mountpoint -q "$HOME_ROOT/$username" || [ -e "$LEASE_DIRECTORY/$username.lease" ]; then
        result RESULT profile-in-use
        exit 3
    fi

    mkdir -p "$RESET_MOUNT_PARENT" && chmod 700 "$RESET_MOUNT_PARENT" || { result RESULT failed; exit 1; }
    RESET_MOUNT_DIR=$(mktemp -d "$RESET_MOUNT_PARENT/profile-reset.XXXXXX") || { result RESULT failed; exit 1; }
    trap cleanup_reset_mount EXIT

    if ! mount -t nfs "$nfs_share" "$RESET_MOUNT_DIR" -o "$NFS_OPTIONS" || ! mountpoint -q "$RESET_MOUNT_DIR"; then
        log "Could not mount the profile share to reset $username."
        result RESULT failed
        exit 1
    fi

    profile="$RESET_MOUNT_DIR/$username"
    if [ ! -e "$profile" ] && [ ! -L "$profile" ]; then
        log "No profile to reset for $username."
        result RESULT profile-missing
        exit 0
    fi

    if [ -L "$profile" ] || [ ! -d "$profile" ]; then
        refuse "The profile of $username is not a plain directory."
    fi

    mount_root=$(realpath -e "$RESET_MOUNT_DIR" 2>/dev/null)
    resolved=$(realpath -e "$profile" 2>/dev/null)
    if [ -z "$mount_root" ] || [ "$resolved" != "$mount_root/$username" ]; then
        refuse "The profile of $username resolves outside the share."
    fi

    target="$username.reset-$(date -u +%Y%m%dT%H%M%SZ)"
    while [ -e "$RESET_MOUNT_DIR/$target" ]; do
        target="$username.reset-$(date -u +%Y%m%dT%H%M%SZ)-$suffix"
        suffix=$((suffix + 1))
    done

    if ! mv -- "$profile" "$RESET_MOUNT_DIR/$target"; then
        log "Could not rename the profile of $username."
        result RESULT failed
        exit 1
    fi

    log "Reset the profile of $username; the previous profile is $target."
    result RESULT profile-reset
    result RENAMED_TO "$target"
}

[ $# -ge 1 ] || usage

ACTION="$1"

case "$ACTION" in
    signout)
        [ $# -eq 2 ] || usage
        validate_username "$2"
        signout "$2"
        ;;
    message)
        [ $# -eq 2 ] || usage
        validate_username "$2"
        send_message "$2"
        ;;
    message-all)
        [ $# -eq 1 ] || usage
        send_message ""
        ;;
    reset-profile)
        [ $# -eq 3 ] || usage
        validate_nfs_share "$2"
        validate_username "$3"
        reset_profile "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
