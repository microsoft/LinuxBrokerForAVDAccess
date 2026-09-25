#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on RHEL 8

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

# ===============================
# Variables

epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
microsoft_packages_url="https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm"

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

arch=$( /bin/arch )

# Disable the screen saver and screen lock on this host. Enabled by default because a
# locked GNOME greeter inside an xrdp session often cannot be unlocked after a reconnect, which
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

# The desktop xrdp sessions run: gnome, the Server with GUI group, or xfce or mate, both from
# EPEL. Bicep sets LINUXBROKER_DESKTOP only for xfce and mate.
desktop="${LINUXBROKER_DESKTOP:-gnome}"
desktop=$(printf '%s' "$desktop" | tr '[:upper:]' '[:lower:]')

case "$desktop" in
    gnome|xfce|mate) ;;
    *)
        echo "Unsupported LINUXBROKER_DESKTOP value: $desktop (expected gnome, xfce or mate)"
        exit 1
        ;;
esac

orgId="${RHEL_ORG_ID:-}"
activationKey="${RHEL_ACTIVATION_KEY:-}"

output_directory="/usr/local/bin"
state_directory="/var/lib/linuxbroker-release-session"
desktop_file="/etc/linuxbroker/desktop.conf"

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

# ===============================
# Execution

set -e  # Exit immediately if a command exits with a non-zero status

if [ -n "$orgId" ] && [ -n "$activationKey" ]; then
    echo "Registering the system..."
    sudo subscription-manager register --org="$orgId" --activationkey="$activationKey"
    sudo subscription-manager repos --enable "codeready-builder-for-rhel-8-${arch}-rpms"
else
    echo "Skipping system registration."
fi

echo "Updating and upgrading system packages..."
sudo dnf update -y && sudo dnf upgrade -y

echo "Installing EPEL repository..."
sudo dnf install -y "$epel_url"

echo "Installing Microsoft repository..."
sudo dnf install -y "$microsoft_packages_url"

echo "Installing essential packages..."
sudo dnf install -y wget util-linux azure-cli xorgxrdp nfs-utils curl jq dconf

# Idle session enforcement degrades gracefully without xprintidle, so a host that cannot
# install it must still finish provisioning rather than fail the extension.
echo "Installing idle detection support..."
sudo dnf install -y xprintidle || echo "xprintidle is unavailable. Idle session enforcement will be skipped on this host."

case "$desktop" in
    gnome)
        echo "Installing 'Server with GUI' group..."
        sudo dnf groupinstall -y "Server with GUI"
        ;;
    xfce)
        # GDM is left out, as it brings GNOME Shell with it and xrdp needs no display manager.
        # xfce4-screensaver is the screen saver the host settings configure, and GNOME Keyring
        # keeps passwords for applications as it does on the other desktops.
        echo "Installing the Xfce desktop..."
        sudo dnf install -y --exclude=gdm @base-x @xfce-desktop xfce4-screensaver xfce4-notifyd \
            gnome-keyring gnome-keyring-pam
        ;;
    mate)
        echo "Installing the MATE desktop..."
        sudo dnf install -y @base-x mate-session-manager mate-panel marco caja mate-settings-daemon \
            mate-control-center mate-terminal mate-screensaver mate-notification-daemon mate-polkit \
            mate-power-manager mate-desktop mate-menus mate-themes mate-icon-theme mate-backgrounds \
            mate-media pluma eom engrampa
        # Atril, the document viewer, needs a package from CodeReady Builder on RHEL 8.
        sudo dnf install -y atril || echo "Atril is unavailable without CodeReady Builder, so MATE has no document viewer on this host."
        ;;
esac

echo "Installing xrdp..."
sudo dnf install -y xrdp

echo "Setting default target to graphical..."
sudo systemctl set-default graphical.target

echo "Starting graphical target..."
sudo systemctl start graphical.target

if sudo systemctl is-active --quiet firewalld; then
    echo "Firewalld is already active."
else
    echo "Enabling and starting firewalld..."
    sudo systemctl enable --now firewalld
fi

echo "Configuring firewall to allow SSH and xrdp connections..."
sudo firewall-cmd --permanent --add-port=22/tcp  # Always allow SSH
sudo firewall-cmd --permanent --add-port=3389/tcp
sudo firewall-cmd --permanent --add-service=ms-wbt || echo "Service 'ms-wbt' may not be available. Skipping."

if systemctl is-active --quiet xrdp; then
    echo "xrdp service is already active."
else
    echo "Starting and enabling xrdp service..."
    sudo systemctl start xrdp
    sudo systemctl enable xrdp --now
fi

echo "Reloading firewall configurations..."
sudo firewall-cmd --reload
echo "Firewall configuration completed."

if [ ! -d "$output_directory" ]; then
    sudo mkdir -p "$output_directory"
    echo "Directory $output_directory created."
fi

echo "Downloading release-session.sh..."
sudo wget -O "$SCRIPT_PATH" "$release_session_url"

sudo sed -i "s|YOUR_LINUX_BROKER_API_CLIENT_ID|$YOUR_LINUXBROKER_API_CLIENT_ID|g" "$SCRIPT_PATH"
sudo sed -i "s|YOUR_LINUX_BROKER_API_BASE_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"
sudo sed -i "s|YOUR_LINUX_BROKER_API_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"

echo "Downloading xrdp-who-xorg.sh..."
sudo wget -O "$output_directory/xrdp-who-xorg.sh" "$xrdp_who_xorg_url"

echo "Downloading logind-session-watcher.sh..."
sudo wget -O "$WATCHER_SCRIPT_PATH" "$logind_watcher_url"

echo "Downloading create-user.sh..."
sudo wget -O "$create_user_script" "$create_user_script_url"

echo "Downloading manage-lease.sh..."
sudo wget -O "$manage_lease_script" "$manage_lease_script_url"

echo "Downloading apply-host-settings.sh..."
sudo wget -O "$apply_settings_script" "$apply_settings_script_url"

echo "Downloading session-control.sh..."
sudo wget -O "$session_control_script" "$session_control_script_url"

echo "Downloading patch-host.sh..."
sudo wget -O "$patch_host_script" "$patch_host_script_url"

echo "Downloading xrdp-startwm.sh..."
sudo wget -O "$xrdp_startwm_script" "$xrdp_startwm_script_url"

echo "Setting execute permissions for downloaded scripts..."
sudo chmod +x "$SCRIPT_PATH"
sudo chmod +x "$output_directory/xrdp-who-xorg.sh"
sudo chmod +x "$WATCHER_SCRIPT_PATH"
sudo chmod +x "$create_user_script"
sudo chmod +x "$manage_lease_script"
sudo chmod +x "$apply_settings_script"
sudo chmod +x "$session_control_script"
sudo chmod +x "$patch_host_script"
sudo chmod +x "$xrdp_startwm_script"
echo "Downloaded scripts are now executable."

# xrdp starts every session through xrdp-startwm.sh, which starts the desktop named here. For
# GNOME that is the distribution's own session script, as before.
echo "Configuring xrdp to start sessions through xrdp-startwm.sh..."
sudo mkdir -p "$(dirname "$desktop_file")"
sudo chmod 755 "$(dirname "$desktop_file")"
cat <<EOF | sudo tee "$desktop_file" >/dev/null
# Written by the Linux Broker host bootstrap: the desktop xrdp-startwm.sh starts in every
# xrdp session.
DESKTOP=$desktop
EOF
sudo chmod 644 "$desktop_file"

if ! sudo "$xrdp_startwm_script" --install; then
    echo "ERROR: Could not configure xrdp to start sessions through $xrdp_startwm_script."
    exit 1
fi

echo "Creating log and user details files..."
sudo mkdir -p "$state_directory"
sudo touch "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
sudo chown root:root "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"
sudo chmod 600 "$LOG_FILE" "$CURRENT_USERS_DETAILS" "$PREVIOUS_USERS_FILE" "$DISCONNECTED_USERS_FILE"

echo "Removing legacy cron entry for release-session.sh..."
tmp_cron=$(mktemp)
sudo crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" > "$tmp_cron" || true
if [ -s "$tmp_cron" ]; then
    sudo crontab "$tmp_cron"
else
    sudo crontab -r 2>/dev/null || true
fi
rm -f "$tmp_cron"

echo "Stopping any legacy release-session.sh processes..."
sudo pkill -f "$SCRIPT_PATH" || true

echo "Installing systemd service for release-session.sh..."
cat <<EOF | sudo tee "$SYSTEMD_SERVICE_PATH" >/dev/null
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
cat <<EOF | sudo tee "$SYSTEMD_TIMER_PATH" >/dev/null
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
cat <<EOF | sudo tee "$WATCHER_SERVICE_PATH" >/dev/null
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
sudo systemctl disable --now "$WATCHER_SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl disable --now "$SYSTEMD_TIMER_NAME" >/dev/null 2>&1 || true
sudo systemctl disable --now "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SYSTEMD_SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl reset-failed "$WATCHER_SERVICE_NAME" >/dev/null 2>&1 || true
sudo systemctl enable --now "$SYSTEMD_TIMER_NAME"
sudo systemctl enable --now "$WATCHER_SERVICE_NAME"
sudo systemctl start "$SYSTEMD_SERVICE_NAME"
echo "Systemd timer and logind watcher configured successfully."

if ! id avdadmin >/dev/null 2>&1; then
    sudo useradd avdadmin
fi

# Only the commands the broker API actually invokes with sudo. Privileged file work
# (mount, chown, chmod, lease markers, host settings) happens inside the allowlisted
# scripts, each of which validates its own input.
cmds=(userdel groupadd usermod chpasswd "$create_user_script" "$manage_lease_script" "$apply_settings_script" "$session_control_script" "$patch_host_script")
full_paths=$(for cmd in "${cmds[@]}"; do command -v "$cmd"; done | paste -sd ',' -)
sudoers_tmp="/etc/sudoers.d/avdadmin.tmp"
echo "avdadmin ALL=(ALL) NOPASSWD: $full_paths" | sudo tee "$sudoers_tmp" >/dev/null
sudo chmod 440 "$sudoers_tmp"
if sudo visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
    sudo mv "$sudoers_tmp" /etc/sudoers.d/avdadmin
else
    sudo rm -f "$sudoers_tmp"
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

if ! printf '%s' "$settings_seed" | sudo "$apply_settings_script"; then
    echo "ERROR: Failed to apply the initial Linux Broker host settings."
    exit 1
fi

echo "System configuration complete."
