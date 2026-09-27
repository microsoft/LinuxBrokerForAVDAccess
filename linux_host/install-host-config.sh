#!/bin/bash
#
# Usage: install-host-config.sh
#
# Writes, as root, the host configuration the Linux Broker adds to the distribution's:
#
# - /etc/logrotate.d/linuxbroker rotates the broker's logs in /var/log every week, or sooner
#   once one passes 50 MB, and keeps four.
# - /etc/udev/rules.d/99-nfs.rules sets the read-ahead of every NFS mount on the host to
#   15 MiB, as Microsoft recommends for Azure Files NFS shares, instead of the 128 KiB Linux
#   has used since kernel 5.4. It takes the place of the distribution's rule of the same name;
#   a rule an administrator wrote there is left alone. NFS mounts that already exist get the
#   value at once.
# - /var/cache/linuxbroker/users, where create-user.sh keeps each broker user's cache on the
#   local disk, and /etc/tmpfiles.d/linuxbroker.conf, which empties it at every boot.
# - /etc/profile.d/linuxbroker-cache.sh, which points XDG_CACHE_HOME at that cache in login
#   shells, as xrdp-startwm.sh does in desktop sessions.
#
# It also removes /awipsprofiles, where create-user.sh mounted the share before it moved to
# /nfs_profiles, when that directory is empty and nothing is mounted on it.
#
# It is idempotent and rewrites a file only when it differs, so the host bootstrap and the
# host migration run it every time. Every step is attempted; it exits 1 when any of them
# failed, 2 on a usage error and 0 otherwise.

set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# The Linux Broker host agent version. Every script in linux_host/ declares the same value
# and the heartbeat reports it; bump them together with HOST_AGENT_VERSION in api/config.py.
LINUXBROKER_AGENT_VERSION="1.2.0"

MANAGED_MARKER="# Managed by the Linux Broker (install-host-config.sh)."
LOGROTATE_FILE="/etc/logrotate.d/linuxbroker"
NFS_RULE_FILE="/etc/udev/rules.d/99-nfs.rules"
NFS_READ_AHEAD_KB=15360
TMPFILES_FILE="/etc/tmpfiles.d/linuxbroker.conf"
PROFILE_FILE="/etc/profile.d/linuxbroker-cache.sh"
USER_CACHE_PARENT="/var/cache/linuxbroker"
USER_CACHE_ROOT="$USER_CACHE_PARENT/users"
LEGACY_MOUNT_ROOT="/awipsprofiles"
# Where the NFS mounts and the read-ahead of their devices are read. The overrides are for
# the tests only.
NFS_VOLUMES_FILE="${LINUXBROKER_NFS_VOLUMES_FILE:-/proc/fs/nfsfs/volumes}"
BDI_DIRECTORY="${LINUXBROKER_BDI_DIRECTORY:-/sys/class/bdi}"

FAILED=0
FILE_CHANGED=0

usage() {
    echo "Usage: $0" >&2
    exit 2
}

step_failed() {
    echo "ERROR: $1" >&2
    FAILED=1
}

restore_context() {
    if command -v restorecon >/dev/null 2>&1; then
        restorecon "$@" >/dev/null 2>&1 || true
    fi
}

# Writes a file only when its content, mode or owner differs, through a temporary file in the
# same directory so nothing reads half of it. The temporary name starts with a dot, which
# logrotate, udev, systemd-tmpfiles and /etc/profile all skip. Sets FILE_CHANGED.
install_file() {
    local label="$1" path="$2" content="$3" directory tmp

    FILE_CHANGED=0
    if [ -f "$path" ] && [ ! -L "$path" ] && [ "$(stat -c '%a %u %g' "$path" 2>/dev/null)" = "644 0 0" ] \
        && [ "$(cat "$path" 2>/dev/null)" = "$content" ]; then
        echo "$label: $path is up to date."
        return 0
    fi
    directory=$(dirname "$path")
    if ! mkdir -p "$directory" || ! tmp=$(mktemp "$directory/.$(basename "$path").XXXXXX"); then
        step_failed "$label: could not write $path."
        return 1
    fi
    if ! printf '%s\n' "$content" > "$tmp" || ! chmod 644 "$tmp" || ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        step_failed "$label: could not write $path."
        return 1
    fi
    restore_context "$path"
    FILE_CHANGED=1
    echo "$label: wrote $path."
}

log_rotation_content() {
    cat <<'EOF'
# Managed by the Linux Broker (install-host-config.sh). Changes here are overwritten.
# The broker's logs. Every writer appends a line at a time, so an empty file with the same
# owner and mode can take the place of the one rotated. patch-host.sh trims
# linuxbroker-patch.log itself, and a package manager writes to it for a whole patch run, so it
# is not rotated here.
/var/log/release-session.log
/var/log/release-session-watcher.log
/var/log/createuser.log
/var/log/linuxbroker-host-settings.log
/var/log/linuxbroker-session-control.log
{
    su root root
    weekly
    maxsize 50M
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    create
}
EOF
}

# Microsoft's rule but for the comments and one character: udev reads $$ as a literal $, so
# awk still gets $4, and udev no longer reports Microsoft's $4 as an invalid substitution each
# time it loads its rules, as systemd 255 does.
nfs_rule_content() {
    cat <<'EOF'
# Managed by the Linux Broker (install-host-config.sh). Changes here are overwritten.
# Sets the read-ahead of every NFS mount to 15 MiB, as Microsoft recommends for Azure Files NFS
# shares: https://learn.microsoft.com/azure/storage/files/nfs-performance
# It takes the place of the distribution's rule of the same name. To keep a rule of your own
# here, remove the first line, and install-host-config.sh leaves the file alone.
SUBSYSTEM=="bdi", ACTION=="add", PROGRAM="/usr/bin/awk -v bdi=$kernel 'BEGIN{ret=1} {if ($$4 == bdi) {ret=0}} END{exit ret}' /proc/fs/nfsfs/volumes", ATTR{read_ahead_kb}="15360"
EOF
}

tmpfiles_content() {
    cat <<'EOF'
# Managed by the Linux Broker (install-host-config.sh). Changes here are overwritten.
# create-user.sh keeps each broker user's cache in /var/cache/linuxbroker/users, where only
# root can add entries. Nothing in it is needed once the host restarts, so it is emptied at
# boot.
d /var/cache/linuxbroker 0755 root root -
D /var/cache/linuxbroker/users 0711 root root -
EOF
}

# Sourced by sh as well as bash, so it keeps to POSIX sh and leaves no variables behind.
profile_content() {
    cat <<'EOF'
# Managed by the Linux Broker (install-host-config.sh). Changes here are overwritten.
# Keeps a broker user's cache on the local disk rather than in the home directory on the NFS
# share, once create-user.sh has prepared it. xrdp-startwm.sh does the same in desktop
# sessions.
if [ -z "${XDG_CACHE_HOME:-}" ]; then
    linuxbroker_user=$(id -un 2>/dev/null) || linuxbroker_user=""
    linuxbroker_cache="/var/cache/linuxbroker/users/$linuxbroker_user"
    if [ -n "$linuxbroker_user" ] && [ -d "$linuxbroker_cache" ] && [ ! -L "$linuxbroker_cache" ] \
        && [ -O "$linuxbroker_cache" ]; then
        XDG_CACHE_HOME=$linuxbroker_cache
        export XDG_CACHE_HOME
    fi
    unset linuxbroker_user linuxbroker_cache
fi
EOF
}

install_log_rotation() {
    install_file "Log rotation" "$LOGROTATE_FILE" "$(log_rotation_content)"
}

# The rule only runs when an NFS mount is added, so the mounts that already exist get the
# value here. The fourth field of each NFS volume is its device, which names its backing
# device in sysfs.
apply_read_ahead_now() {
    local device setting count=0

    [ -r "$NFS_VOLUMES_FILE" ] || return 0
    while read -r device; do
        [[ "$device" =~ ^[0-9]+:[0-9]+$ ]] || continue
        setting="$BDI_DIRECTORY/$device/read_ahead_kb"
        [ -f "$setting" ] || continue
        [ "$(cat "$setting" 2>/dev/null)" = "$NFS_READ_AHEAD_KB" ] && continue
        if printf '%s\n' "$NFS_READ_AHEAD_KB" > "$setting" 2>/dev/null; then
            count=$((count + 1))
        else
            echo "NFS read-ahead: could not set the read-ahead of NFS device $device."
        fi
    done < <(awk 'NR > 1 { print $4 }' "$NFS_VOLUMES_FILE" 2>/dev/null)
    if [ "$count" -gt 0 ]; then
        echo "NFS read-ahead: set $NFS_READ_AHEAD_KB KiB on $count NFS mount(s) that already existed."
    fi
}

install_nfs_read_ahead() {
    if [ -e "$NFS_RULE_FILE" ] && ! grep -qF "$MANAGED_MARKER" "$NFS_RULE_FILE" 2>/dev/null; then
        echo "NFS read-ahead: left $NFS_RULE_FILE alone, because the Linux Broker did not write it."
        return 0
    fi
    install_file "NFS read-ahead" "$NFS_RULE_FILE" "$(nfs_rule_content)" || return 0
    if [ "$FILE_CHANGED" -eq 1 ]; then
        if ! command -v udevadm >/dev/null 2>&1; then
            echo "NFS read-ahead: udevadm was not found, so udev was not asked to reload its rules."
        elif ! udevadm control --reload >/dev/null 2>&1; then
            echo "NFS read-ahead: udevadm control --reload failed; udev loads the rule when the host restarts."
        fi
    fi
    apply_read_ahead_now
}

install_user_cache() {
    install_file "Local caches" "$TMPFILES_FILE" "$(tmpfiles_content)"
    if mkdir -p "$USER_CACHE_ROOT" && chown root:root "$USER_CACHE_PARENT" "$USER_CACHE_ROOT" \
        && chmod 755 "$USER_CACHE_PARENT" && chmod 711 "$USER_CACHE_ROOT"; then
        restore_context "$USER_CACHE_PARENT" "$USER_CACHE_ROOT"
        echo "Local caches: $USER_CACHE_ROOT is ready."
    else
        step_failed "Local caches: could not prepare $USER_CACHE_ROOT."
    fi
    install_file "Local caches" "$PROFILE_FILE" "$(profile_content)"
}

# Never more than rmdir, which only removes an empty directory.
remove_legacy_mount_root() {
    if [ ! -e "$LEGACY_MOUNT_ROOT" ] && [ ! -L "$LEGACY_MOUNT_ROOT" ]; then
        return 0
    fi
    if [ -L "$LEGACY_MOUNT_ROOT" ] || [ ! -d "$LEGACY_MOUNT_ROOT" ]; then
        echo "Legacy mount root: left $LEGACY_MOUNT_ROOT alone, because it is not a directory."
    elif mountpoint -q "$LEGACY_MOUNT_ROOT"; then
        echo "Legacy mount root: left $LEGACY_MOUNT_ROOT alone, because something is mounted on it."
    elif [ -n "$(ls -A -- "$LEGACY_MOUNT_ROOT" 2>/dev/null)" ]; then
        echo "Legacy mount root: left $LEGACY_MOUNT_ROOT alone, because it is not empty."
    elif rmdir -- "$LEGACY_MOUNT_ROOT" 2>/dev/null; then
        echo "Legacy mount root: removed the empty $LEGACY_MOUNT_ROOT; the share is mounted on /nfs_profiles now."
    else
        echo "Legacy mount root: could not remove $LEGACY_MOUNT_ROOT."
    fi
}

[ $# -eq 0 ] || usage

if [ "$(id -u)" -ne 0 ]; then
    echo "install-host-config.sh must run as root." >&2
    exit 1
fi

install_log_rotation
install_nfs_read_ahead
install_user_cache
remove_legacy_mount_root

if [ "$FAILED" -ne 0 ]; then
    echo "The Linux Broker host configuration is incomplete; run install-host-config.sh again as root." >&2
    exit 1
fi
echo "The Linux Broker host configuration is up to date."
