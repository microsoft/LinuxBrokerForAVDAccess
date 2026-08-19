#!/bin/bash

# Usage: ./create-user.sh <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <NFS_SHARE> <USERID> <USERNAME> [LEASE_ID]"
    exit 1
fi

NFS_SHARE="$1"
USERID="$2"
USERNAME="$3"
LEASE_ID="${4:-}"

# Constants
NFS_MOUNT_ROOT="/awipsprofiles"
NFS_OPTIONS="vers=4,minorversion=1,sec=sys,nconnect=4"
NFS_USERHOME="$NFS_MOUNT_ROOT/$USERNAME"
LOCAL_USERHOME="/home/$USERNAME"
LOGFILE=/var/log/createuser.log
LEASE_DIRECTORY="/var/lib/linuxbroker-release-session/leases"
LEASE_FILE="$LEASE_DIRECTORY/$USERNAME.lease"

# Parameters output
echo "Running create-user.sh with: $1, $2, $3" >> $LOGFILE

# Ensure NFS mount root exists
if [ ! -d "$NFS_MOUNT_ROOT" ]; then
    mkdir -p "$NFS_MOUNT_ROOT"
fi

# Mount NFS root if not already mounted
echo "Mount NFS root on /awipsprofiles" >> $LOGFILE
if ! mountpoint -q "$NFS_MOUNT_ROOT"; then
    mount -t nfs "$NFS_SHARE" "$NFS_MOUNT_ROOT" -o "$NFS_OPTIONS"
    if [ $? -ne 0 ]; then
        echo "Failed to mount NFS share: $NFS_SHARE" >> $LOGFILE
        exit 1
    fi
fi

# Create local user if it doesn't exist
echo "Check or create user: $USERID $USERNAME $LOCAL_USERHOME" >> $LOGFILE
if ! id "$USERNAME" &>/dev/null; then
    useradd -d "$LOCAL_USERHOME" -u "$USERID" -U "$USERNAME" -M
else
    echo "User $USERNAME already exists. Skipping useradd." >> $LOGFILE
fi

# Create remote user home directory if it doesn't exist
echo "Create user home on the NFS share" >> $LOGFILE
if [ ! -d "$NFS_USERHOME" ]; then
    mkdir -p "$NFS_USERHOME"
    cp -r /etc/skel/. "$NFS_USERHOME"
    chown -R "$USERNAME:$USERNAME" "$NFS_USERHOME"
    chmod 700 "$NFS_USERHOME"
fi

# Ensure local mount point exists and is owned by the user
echo "Create user home mount point in /home" >> $LOGFILE
if [ ! -d "$LOCAL_USERHOME" ]; then
    mkdir -p "$LOCAL_USERHOME"
    chown "$USERNAME:$USERNAME" "$LOCAL_USERHOME"
    chmod 700 "$LOCAL_USERHOME"
fi

# Mount user's NFS home to local user home if not already mounted
echo "Mount user home folder" >> $LOGFILE
if ! mountpoint -q "$LOCAL_USERHOME"; then
    mount --bind "$NFS_USERHOME" "$LOCAL_USERHOME"
fi

if [ -n "$LEASE_ID" ]; then
    echo "Write lease marker for $USERNAME" >> $LOGFILE
    mkdir -p "$LEASE_DIRECTORY"
    printf '%s\n' "$LEASE_ID" > "$LEASE_FILE"
    chown root:root "$LEASE_FILE"
    chmod 600 "$LEASE_FILE"
fi

# Unmount NFS root
umount "$NFS_MOUNT_ROOT"