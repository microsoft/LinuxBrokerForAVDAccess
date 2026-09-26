#!/bin/bash

# Usage: ./create-user.sh <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]
#        ./create-user.sh --password-stdin <NFS_SHARE> <USERID> <USERNAME> <LEASE_ID>

# The Linux Broker host agent version. Every script in linux_host/ declares the same value
# and the heartbeat reports it; bump them together with HOST_AGENT_VERSION in api/config.py.
LINUXBROKER_AGENT_VERSION="1.1.0"

# Constants
NFS_MOUNT_ROOT="/awipsprofiles"
NFS_OPTIONS="vers=4,minorversion=1,sec=sys,nconnect=4"
LOGFILE=/var/log/createuser.log
LEASE_DIRECTORY="/var/lib/linuxbroker-release-session/leases"
# The key that opens each user's login keyring, left on tmpfs for the xrdp session launcher.
KEYRING_KEY_DIRECTORY="/run/linuxbroker-keyring"
PASSWORD_MODE="false"
SCRIPT_MOUNTED_NFS_ROOT="false"

usage() {
    echo "Usage: $0 <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]"
    exit 1
}

log() {
    echo "$1" >> "$LOGFILE"
}

fail() {
    log "ERROR: $1"
    echo "$1" >&2
    cleanup_nfs_root
    exit 1
}

cleanup_nfs_root() {
    if [ "$SCRIPT_MOUNTED_NFS_ROOT" = "true" ]; then
        umount "$NFS_MOUNT_ROOT" >/dev/null 2>&1 || true
        SCRIPT_MOUNTED_NFS_ROOT="false"
    fi
}

validate_new_form_inputs() {
    if [ -z "$NFS_SHARE" ]; then
        fail "Invalid NFS share."
    fi

    if ! [[ "$USERID" =~ ^[0-9]+$ ]] || [ "$USERID" -lt 1000 ]; then
        fail "Invalid UID."
    fi

    if ! [[ "$USERNAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        fail "Invalid username."
    fi

    if ! [[ "$LEASE_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        fail "Invalid lease id."
    fi
}

run_checked() {
    local message="$1"
    shift

    "$@" || fail "$message"
}

ensure_group() {
    local group_name="$1"

    if ! getent group "$group_name" >/dev/null 2>&1; then
        run_checked "Failed to create group $group_name." groupadd "$group_name"
    fi
}

ensure_user_group_membership() {
    local group_name="$1"

    ensure_group "$group_name"
    run_checked "Failed to add $USERNAME to group $group_name." usermod -aG "$group_name" "$USERNAME"
}

# Leaves the user's keyring key where the xrdp session launcher reads it, or removes a key an
# earlier checkout left when none was sent. The key only unlocks the keyring, so a failure is
# logged and the sign-in goes ahead.
store_keyring_key() {
    local key_file="$KEYRING_KEY_DIRECTORY/$USERNAME" tmp

    if [ -z "$KEYRING_KEY" ]; then
        rm -f "$key_file" 2>/dev/null || log "Could not remove the old keyring key of $USERNAME."
        return 0
    fi

    # Anyone may open a key by name, but only its owner can read it and nobody can list them.
    if ! mkdir -p "$KEYRING_KEY_DIRECTORY" || ! chown root:root "$KEYRING_KEY_DIRECTORY" \
        || ! chmod 711 "$KEYRING_KEY_DIRECTORY"; then
        log "Could not prepare $KEYRING_KEY_DIRECTORY, so the keyring of $USERNAME stays locked."
        return 0
    fi
    if ! tmp=$(mktemp "$KEYRING_KEY_DIRECTORY/.$USERNAME.XXXXXX"); then
        log "Could not write the keyring key of $USERNAME."
        return 0
    fi
    if ! printf '%s\n' "$KEYRING_KEY" > "$tmp" || ! chown "$USERNAME" "$tmp" || ! chmod 400 "$tmp" \
        || ! mv -f "$tmp" "$key_file"; then
        rm -f "$tmp"
        log "Could not write the keyring key of $USERNAME."
        return 0
    fi
    log "Stored the keyring key of $USERNAME."
}

if [ "${1:-}" = "--password-stdin" ]; then
    if [ $# -ne 5 ]; then
        usage
    fi

    PASSWORD_MODE="true"
    NFS_SHARE="$2"
    USERID="$3"
    USERNAME="$4"
    LEASE_ID="$5"
elif [ $# -ge 3 ] && [ $# -le 4 ]; then
    NFS_SHARE="$1"
    USERID="$2"
    USERNAME="$3"
    LEASE_ID="${4:-}"
else
    usage
fi

NFS_USERHOME="$NFS_MOUNT_ROOT/$USERNAME"
LOCAL_USERHOME="/home/$USERNAME"
LEASE_FILE="$LEASE_DIRECTORY/$USERNAME.lease"

if [ "$PASSWORD_MODE" = "true" ]; then
    validate_new_form_inputs
fi

# Parameters output
log "Running create-user.sh with: $NFS_SHARE, $USERID, $USERNAME"

# Ensure NFS mount root exists
if [ ! -d "$NFS_MOUNT_ROOT" ]; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to create $NFS_MOUNT_ROOT." mkdir -p "$NFS_MOUNT_ROOT"
    else
        mkdir -p "$NFS_MOUNT_ROOT"
    fi
fi

# Mount NFS root if not already mounted
log "Mount NFS root on /awipsprofiles"
if ! mountpoint -q "$NFS_MOUNT_ROOT"; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to mount NFS share: $NFS_SHARE" mount -t nfs "$NFS_SHARE" "$NFS_MOUNT_ROOT" -o "$NFS_OPTIONS"
        SCRIPT_MOUNTED_NFS_ROOT="true"
    else
        mount -t nfs "$NFS_SHARE" "$NFS_MOUNT_ROOT" -o "$NFS_OPTIONS"
        if [ $? -ne 0 ]; then
            log "Failed to mount NFS share: $NFS_SHARE"
            exit 1
        fi
        SCRIPT_MOUNTED_NFS_ROOT="true"
    fi
fi

if [ "$PASSWORD_MODE" = "true" ]; then
    if ! IFS= read -r PASSWORD; then
        fail "Password was not supplied on stdin."
    fi

    if [ -z "$PASSWORD" ]; then
        fail "Password was not supplied on stdin."
    fi

    # The broker sends the user's keyring key on a second line when it has a keyring vault.
    KEYRING_KEY=""
    IFS= read -r KEYRING_KEY || true
    if [ -n "$KEYRING_KEY" ] && ! [[ "$KEYRING_KEY" =~ ^[A-Za-z0-9_-]{16,128}$ ]]; then
        log "Ignoring a keyring key for $USERNAME that is not a valid key."
        KEYRING_KEY=""
    fi
fi

# Create local user if it doesn't exist. Ubuntu's useradd would give the user /bin/sh, which
# makes a poor shell in a desktop terminal.
log "Check or create user: $USERID $USERNAME $LOCAL_USERHOME"
if ! id "$USERNAME" &>/dev/null; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to create user $USERNAME." useradd -d "$LOCAL_USERHOME" -u "$USERID" -U -s /bin/bash "$USERNAME" -M
    else
        useradd -d "$LOCAL_USERHOME" -u "$USERID" -U -s /bin/bash "$USERNAME" -M
    fi
else
    log "User $USERNAME already exists. Skipping useradd."
    # Users that an earlier version created on Ubuntu have /bin/sh.
    if [ "$PASSWORD_MODE" = "true" ] && [ "$(getent passwd "$USERNAME" | cut -d: -f7)" = "/bin/sh" ]; then
        if usermod -s /bin/bash "$USERNAME"; then
            log "Changed the login shell of $USERNAME from /bin/sh to /bin/bash."
        else
            log "Could not change the login shell of $USERNAME from /bin/sh to /bin/bash."
        fi
    fi
fi

if [ "$PASSWORD_MODE" = "true" ]; then
    ensure_user_group_membership "tsusers"
    ensure_user_group_membership "appusers"
fi

# Create remote user home directory if it doesn't exist
log "Create user home on the NFS share"
if [ ! -d "$NFS_USERHOME" ]; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to create NFS home for $USERNAME." mkdir -p "$NFS_USERHOME"
        run_checked "Failed to copy skeleton files for $USERNAME." cp -r /etc/skel/. "$NFS_USERHOME"
        run_checked "Failed to chown NFS home for $USERNAME." chown -R "$USERNAME:$USERNAME" "$NFS_USERHOME"
        run_checked "Failed to chmod NFS home for $USERNAME." chmod 700 "$NFS_USERHOME"
    else
        mkdir -p "$NFS_USERHOME"
        cp -r /etc/skel/. "$NFS_USERHOME"
        chown -R "$USERNAME:$USERNAME" "$NFS_USERHOME"
        chmod 700 "$NFS_USERHOME"
    fi
fi

# Ensure local mount point exists and is owned by the user
log "Create user home mount point in /home"
if [ ! -d "$LOCAL_USERHOME" ]; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to create local home for $USERNAME." mkdir -p "$LOCAL_USERHOME"
        run_checked "Failed to chown local home for $USERNAME." chown "$USERNAME:$USERNAME" "$LOCAL_USERHOME"
        run_checked "Failed to chmod local home for $USERNAME." chmod 700 "$LOCAL_USERHOME"
    else
        mkdir -p "$LOCAL_USERHOME"
        chown "$USERNAME:$USERNAME" "$LOCAL_USERHOME"
        chmod 700 "$LOCAL_USERHOME"
    fi
fi

# The RHEL release agent unmounts a home that has no lease, so write the lease before the
# home is mounted.
if [ -n "$LEASE_ID" ]; then
    log "Write lease marker for $USERNAME"
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to create lease directory." mkdir -p "$LEASE_DIRECTORY"
        printf '%s\n' "$LEASE_ID" > "$LEASE_FILE" || fail "Failed to write lease marker for $USERNAME."
        run_checked "Failed to chown lease marker for $USERNAME." chown root:root "$LEASE_FILE"
        run_checked "Failed to chmod lease marker for $USERNAME." chmod 600 "$LEASE_FILE"
    else
        mkdir -p "$LEASE_DIRECTORY"
        printf '%s\n' "$LEASE_ID" > "$LEASE_FILE"
        chown root:root "$LEASE_FILE"
        chmod 600 "$LEASE_FILE"
    fi
fi

# Mount user's NFS home to local user home if not already mounted
log "Mount user home folder"
if ! mountpoint -q "$LOCAL_USERHOME"; then
    if [ "$PASSWORD_MODE" = "true" ]; then
        run_checked "Failed to bind mount $NFS_USERHOME to $LOCAL_USERHOME." mount --bind "$NFS_USERHOME" "$LOCAL_USERHOME"
    else
        mount --bind "$NFS_USERHOME" "$LOCAL_USERHOME"
    fi
fi

if [ "$PASSWORD_MODE" = "true" ]; then
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd || fail "Failed to set password for $USERNAME."
    unset PASSWORD
    store_keyring_key
    unset KEYRING_KEY
    if [ "$SCRIPT_MOUNTED_NFS_ROOT" = "true" ]; then
        run_checked "Failed to unmount $NFS_MOUNT_ROOT." umount "$NFS_MOUNT_ROOT"
        SCRIPT_MOUNTED_NFS_ROOT="false"
    fi
    echo "__CREATE_USER_RESULT=ok__"
    exit 0
fi

# Unmount NFS root
umount "$NFS_MOUNT_ROOT"