#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on Ubuntu
# 24.04: the desktop, by default the Ubuntu desktop, which xrdp sessions run as "Ubuntu on
# Xorg", and the Linux Broker host agent. The Custom Script Extension runs it as root.

LINUXBROKER_API_BASE_URL="${1:-}"
LINUXBROKER_API_CLIENT_ID="${2:-}"

if [[ -z "$LINUXBROKER_API_BASE_URL" || -z "$LINUXBROKER_API_CLIENT_ID" ]]; then
    echo "Linux Broker API base URL and client ID are required."
    exit 1
fi

if [[ "$LINUXBROKER_API_BASE_URL" != https://* ]]; then
    echo "Linux Broker API base URL must start with https://"
    exit 1
fi

LINUXBROKER_API_BASE_URL="${LINUXBROKER_API_BASE_URL%/}"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root."
    exit 1
fi

# ===============================
# Variables

# Override for sovereign or air-gapped clouds where raw.githubusercontent.com is unreachable.
script_source_root="${LINUXBROKER_SCRIPT_SOURCE_ROOT:-https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main}"
script_source_root="${script_source_root%/}"

release_session_url="$script_source_root/linux_host/session_release_buffer/release-session.sh"
xrdp_who_xorg_url="$script_source_root/linux_host/session_release_buffer/xrdp-who-xorg.sh"
logind_watcher_url="$script_source_root/linux_host/session_release_buffer/logind-session-watcher.sh"
create_user_script_url="$script_source_root/linux_host/create-user.sh"
create_user_script="/usr/local/bin/create-user.sh"
manage_lease_script_url="$script_source_root/linux_host/manage-lease.sh"
manage_lease_script="/usr/local/bin/manage-lease.sh"
apply_settings_script_url="$script_source_root/linux_host/apply-host-settings.sh"
apply_settings_script="/usr/local/bin/apply-host-settings.sh"
session_control_script_url="$script_source_root/linux_host/session-control.sh"
session_control_script="/usr/local/bin/session-control.sh"
patch_host_script_url="$script_source_root/linux_host/patch-host.sh"
patch_host_script="/usr/local/bin/patch-host.sh"
xrdp_startwm_script_url="$script_source_root/linux_host/xrdp-startwm.sh"
xrdp_startwm_script="/usr/local/bin/xrdp-startwm.sh"

# Disable the screen saver and screen lock on this host. Enabled by default because a
# locked greeter inside an xrdp session often cannot be unlocked after a reconnect, which
# strands the host's lease. Set LINUXBROKER_DISABLE_SCREEN_LOCK=false to keep the lock screen.
disableScreenLock="${LINUXBROKER_DISABLE_SCREEN_LOCK:-true}"
disableScreenLock=$(printf '%s' "$disableScreenLock" | tr '[:upper:]' '[:lower:]')

case "$disableScreenLock" in
    true|1|yes|y) disableScreenLock="true" ;;
    false|0|no|n) disableScreenLock="false" ;;
    *)
        echo "Unsupported LINUXBROKER_DISABLE_SCREEN_LOCK value: $disableScreenLock (expected true or false)"
        exit 1
        ;;
esac

# The desktop xrdp sessions run: gnome, the Ubuntu desktop, xfce or mate. Bicep sets
# LINUXBROKER_DESKTOP only for xfce and mate.
desktop="${LINUXBROKER_DESKTOP:-gnome}"
desktop=$(printf '%s' "$desktop" | tr '[:upper:]' '[:lower:]')

case "$desktop" in
    gnome|xfce|mate) ;;
    *)
        echo "Unsupported LINUXBROKER_DESKTOP value: $desktop (expected gnome, xfce or mate)"
        exit 1
        ;;
esac

output_directory="/usr/local/bin"
state_directory="/var/lib/linuxbroker-release-session"
desktop_file="/etc/linuxbroker/desktop.conf"
ubuntu_dconf_file="/etc/dconf/db/local.d/10-linuxbroker-ubuntu"

SCRIPT_PATH="$output_directory/release-session.sh"
WATCHER_SCRIPT_PATH="$output_directory/logind-session-watcher.sh"
LOG_FILE="/var/log/release-session.log"
CURRENT_USERS_DETAILS="$state_directory/current_users.txt"
PREVIOUS_USERS_FILE="$state_directory/previous_users.txt"
DISCONNECTED_USERS_FILE="$state_directory/disconnected_users.tsv"
SYSTEMD_SERVICE_NAME="linuxbroker-release-session.service"
SYSTEMD_TIMER_NAME="linuxbroker-release-session.timer"
WATCHER_SERVICE_NAME="linuxbroker-release-session-watcher.service"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/$SYSTEMD_SERVICE_NAME"
SYSTEMD_TIMER_PATH="/etc/systemd/system/$SYSTEMD_TIMER_NAME"
WATCHER_SERVICE_PATH="/etc/systemd/system/$WATCHER_SERVICE_NAME"

YOUR_LINUXBROKER_API_CLIENT_ID="$LINUXBROKER_API_CLIENT_ID"
YOUR_LINUXBROKER_API_BASE_URL="$LINUXBROKER_API_BASE_URL"

# Package installs never stop to ask: dpkg keeps a configuration file that was changed
# locally, needrestart leaves running services alone, and apt waits for the first-boot
# updates that may still hold the package lock.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1

apt_get() {
    apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# A mirror in the middle of a sync fails the index download now and then.
apt_update() {
    local attempt=1

    until apt_get update; do
        if [ "$attempt" -ge 5 ]; then
            echo "ERROR: apt-get update failed $attempt times."
            return 1
        fi
        echo "apt-get update failed. Retrying in 30 seconds (attempt $attempt of 5)..."
        attempt=$((attempt + 1))
        sleep 30
    done
}

# ===============================
# Execution

set -e  # Exit immediately if a command exits with a non-zero status

echo "Updating and upgrading system packages..."
apt_update
apt_get -y --with-new-pkgs upgrade

# The first-login wizard would greet every broker user, and crash reports are not collected
# (see apport below), so gnome-initial-setup and whoopsie are left out. xrdp needs no display
# manager, so Xfce and MATE come without LightDM, and without light-locker, which locks the
# screen through it. xfce4-screensaver is the screen saver the host settings configure, and
# GNOME Keyring keeps passwords for applications as it does on the other desktops. Firefox is
# a snap on Ubuntu, and a snap store that cannot be reached would fail the whole install, so
# it is installed on its own afterwards.
case "$desktop" in
    gnome)
        desktop_packages=(ubuntu-desktop-minimal gnome-initial-setup- whoopsie-)
        ;;
    xfce)
        desktop_packages=(xfce4 xfce4-goodies xfce4-screensaver xfce4-notifyd gnome-keyring libpam-gnome-keyring
            lightdm- light-locker-)
        ;;
    mate)
        desktop_packages=(mate-desktop-environment-core mate-screensaver mate-notification-daemon lightdm-)
        ;;
esac
if ! dpkg-query -W -f='${Status}' firefox 2>/dev/null | grep -q 'install ok installed'; then
    desktop_packages+=(firefox-)
fi

echo "Installing the desktop, xrdp and the Linux Broker dependencies..."
apt_get -y install jq nfs-common dconf-cli curl wget ufw libnotify-bin x11-utils dbus-user-session \
    xrdp xorgxrdp "${desktop_packages[@]}"

# Idle session enforcement degrades gracefully without xprintidle, so a host that cannot
# install it must still finish provisioning rather than fail the extension.
echo "Installing idle detection support..."
apt_get -y install xprintidle || echo "xprintidle is unavailable. Idle session enforcement will be skipped on this host."

echo "Installing Firefox..."
if ! apt_get -y install firefox; then
    echo "WARNING: Firefox could not be installed; the snap store may be unreachable. Install it later with 'apt-get install firefox'."
fi

# The xrdp certificate is the snakeoil one, whose key only the ssl-cert group can read.
if getent group ssl-cert >/dev/null && id xrdp >/dev/null 2>&1; then
    echo "Letting xrdp read its TLS key..."
    usermod -aG ssl-cert xrdp
fi

# Broker users cannot act on crash reports, so apport neither collects them nor asks about them.
echo "Disabling crash reporting..."
if [ -f /etc/default/apport ]; then
    sed -i 's/^enabled=1$/enabled=0/' /etc/default/apport
fi
systemctl disable --now apport.service >/dev/null 2>&1 || true

# Broker users cannot install updates or reboot the host, and patching is scheduled from the
# Linux Broker portal, so the update notifications stay quiet. The dconf profile that makes
# the local database take effect is written with the host settings at the end.
echo "Quieting update notifications for broker users..."
mkdir -p "$(dirname "$ubuntu_dconf_file")"
cat > "$ubuntu_dconf_file" <<'EOF'
# Managed by the Linux Broker host bootstrap.
[com/ubuntu/update-notifier]
no-show-notifications=true
show-apport-crashes=false
hide-reboot-notification=true
notify-ubuntu-advantage-available=false
show-livepatch-status-icon=false
EOF
# mate-session-manager brings ubuntu-mate-default-settings, which makes the Ubuntu MATE panel
# layout the default. That layout needs the Brisk menu, indicator and trash applets, which the
# core MATE set leaves out, so every new user was asked to delete three broken applets. MATE's
# own layout uses only the applets mate-panel ships.
if [ "$desktop" = "mate" ]; then
    cat >> "$ubuntu_dconf_file" <<'EOF'

[org/mate/panel/general]
default-layout='default'
EOF
fi
chmod 644 "$ubuntu_dconf_file"
dconf update

echo "Setting default target to graphical..."
systemctl set-default graphical.target

echo "Starting graphical target..."
systemctl start graphical.target

echo "Configuring firewall..."
ufw allow OpenSSH
ufw allow 3389/tcp
ufw --force enable
echo "Firewall configuration completed."

if [ ! -d "$output_directory" ]; then
    mkdir -p "$output_directory"
    echo "Directory $output_directory created."
fi

echo "Downloading release-session.sh..."
wget -O "$SCRIPT_PATH" "$release_session_url"

sed -i "s|YOUR_LINUX_BROKER_API_CLIENT_ID|$YOUR_LINUXBROKER_API_CLIENT_ID|g" "$SCRIPT_PATH"
sed -i "s|YOUR_LINUX_BROKER_API_BASE_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"
sed -i "s|YOUR_LINUX_BROKER_API_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"

echo "Downloading xrdp-who-xorg.sh..."
wget -O "$output_directory/xrdp-who-xorg.sh" "$xrdp_who_xorg_url"

echo "Downloading logind-session-watcher.sh..."
wget -O "$WATCHER_SCRIPT_PATH" "$logind_watcher_url"

echo "Downloading create-user.sh..."
wget -O "$create_user_script" "$create_user_script_url"

echo "Downloading manage-lease.sh..."
wget -O "$manage_lease_script" "$manage_lease_script_url"

echo "Downloading apply-host-settings.sh..."
wget -O "$apply_settings_script" "$apply_settings_script_url"

echo "Downloading session-control.sh..."
wget -O "$session_control_script" "$session_control_script_url"

echo "Downloading patch-host.sh..."
wget -O "$patch_host_script" "$patch_host_script_url"

echo "Downloading xrdp-startwm.sh..."
wget -O "$xrdp_startwm_script" "$xrdp_startwm_script_url"

echo "Setting execute permissions for downloaded scripts..."
chmod +x "$SCRIPT_PATH"
chmod +x "$output_directory/xrdp-who-xorg.sh"
chmod +x "$WATCHER_SCRIPT_PATH"
chmod +x "$create_user_script"
chmod +x "$manage_lease_script"
chmod +x "$apply_settings_script"
chmod +x "$session_control_script"
chmod +x "$patch_host_script"
chmod +x "$xrdp_startwm_script"
echo "Downloaded scripts are now executable."

# xrdp starts every session through xrdp-startwm.sh, which starts the desktop named here.
echo "Configuring xrdp to start the desktop..."
mkdir -p "$(dirname "$desktop_file")"
chmod 755 "$(dirname "$desktop_file")"
cat > "$desktop_file" <<EOF
# Written by the Linux Broker host bootstrap: the desktop xrdp-startwm.sh starts in every
# xrdp session. gnome is Ubuntu on Xorg.
DESKTOP=$desktop
EOF
chmod 644 "$desktop_file"

if ! "$xrdp_startwm_script" --install; then
    echo "ERROR: Could not configure xrdp to start sessions through $xrdp_startwm_script."
    exit 1
fi

# A restart, rather than the reload --install asks for, so xrdp also joins ssl-cert.
echo "Enabling and restarting xrdp..."
systemctl enable xrdp
systemctl restart xrdp

echo "Creating log and user details files..."
mkdir -p "$state_directory"
touch "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
chown root:root "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
chmod 600 "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"

echo "Removing legacy cron entry for release-session.sh..."
tmp_cron=$(mktemp)
crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" > "$tmp_cron" || true
if [ -s "$tmp_cron" ]; then
    crontab "$tmp_cron"
else
    crontab -r 2>/dev/null || true
fi
rm -f "$tmp_cron"

echo "Stopping any legacy release-session.sh processes..."
pkill -f "$SCRIPT_PATH" || true

echo "Installing systemd service for release-session.sh..."
cat > "$SYSTEMD_SERVICE_PATH" <<EOF
[Unit]
Description=Linux Broker Release Agent
After=network-online.target xrdp.service
Wants=network-online.target
ConditionPathExists=$SCRIPT_PATH

[Service]
Type=oneshot
User=root
WorkingDirectory=$state_directory
ExecStart=$SCRIPT_PATH --systemd-timer
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Installing systemd timer for release-session.sh..."
cat > "$SYSTEMD_TIMER_PATH" <<EOF
[Unit]
Description=Run Linux Broker Release Agent every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s
Persistent=true
Unit=$SYSTEMD_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

echo "Installing systemd service for logind-session-watcher.sh..."
cat > "$WATCHER_SERVICE_PATH" <<EOF
[Unit]
Description=Linux Broker logind Session Watcher
After=network-online.target systemd-logind.service
Wants=network-online.target
ConditionPathExists=$WATCHER_SCRIPT_PATH

[Service]
Type=simple
User=root
WorkingDirectory=$state_directory
ExecStart=$WATCHER_SCRIPT_PATH
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "Reloading systemd and enabling release-session timer..."
systemctl disable --now "$WATCHER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl disable --now "$SYSTEMD_TIMER_NAME" >/dev/null 2>&1 || true
systemctl disable --now "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl reset-failed "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl reset-failed "$WATCHER_SERVICE_NAME" >/dev/null 2>&1 || true
systemctl enable --now "$SYSTEMD_TIMER_NAME"
systemctl enable --now "$WATCHER_SERVICE_NAME"
systemctl start "$SYSTEMD_SERVICE_NAME"
echo "Systemd timer and logind watcher configured successfully."

if ! id avdadmin >/dev/null 2>&1; then
    useradd avdadmin
fi

# Only the commands the broker API actually invokes with sudo. Privileged file work
# (mount, chown, chmod, lease markers, host settings) happens inside the allowlisted
# scripts, each of which validates its own input.
cmds=(userdel groupadd usermod chpasswd "$create_user_script" "$manage_lease_script" "$apply_settings_script" "$session_control_script" "$patch_host_script")
full_paths=$(for cmd in "${cmds[@]}"; do command -v "$cmd"; done | paste -sd ',' -)
sudoers_tmp="/etc/sudoers.d/avdadmin.tmp"
echo "avdadmin ALL=(ALL) NOPASSWD: $full_paths" > "$sudoers_tmp"
chmod 440 "$sudoers_tmp"
if visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
    mv "$sudoers_tmp" /etc/sudoers.d/avdadmin
else
    rm -f "$sudoers_tmp"
    echo "ERROR: Generated sudoers policy failed validation."
    exit 1
fi
echo "avdadmin user is created and permissioned"

# Seed the Linux Broker host settings profile. This writes the screen lock policy for each
# desktop, the dconf profile that makes it take effect, the release agent's settings file,
# and the systemd drop-ins, then compiles the dconf database. LINUXBROKER_DISABLE_SCREEN_LOCK
# still chooses the screen lock posture; from here on the values are managed from the portal
# and the release agent converges the host to the configured profile on its next run.
if [ "$disableScreenLock" = "true" ]; then
    echo "Seeding host settings with the screen saver and screen lock disabled..."
    settings_seed='{"ScreenLockEnabled":false,"DisableLockScreen":true}'
else
    echo "Seeding host settings with the screen lock left enabled (LINUXBROKER_DISABLE_SCREEN_LOCK=false)."
    settings_seed='{"ScreenLockEnabled":true,"DisableLockScreen":false}'
fi

if ! printf '%s' "$settings_seed" | "$apply_settings_script"; then
    echo "ERROR: Failed to apply the initial Linux Broker host settings."
    exit 1
fi

echo "System configuration complete."
