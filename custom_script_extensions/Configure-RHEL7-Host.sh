#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on RHEL 7

LINUXBROKER_API_BASE_URL="${1:-}"
LINUXBROKER_API_CLIENT_ID="${2:-}"

if [ -z "$LINUXBROKER_API_BASE_URL" ] || [ -z "$LINUXBROKER_API_CLIENT_ID" ]; then
    echo "Linux Broker API base URL and client ID are required."
    exit 1
fi

case "$LINUXBROKER_API_BASE_URL" in
    https://*) ;;
    *)
        echo "Linux Broker API base URL must start with https://"
        exit 1
        ;;
esac

LINUXBROKER_API_BASE_URL="${LINUXBROKER_API_BASE_URL%/}"

# ===============================
# Variables

epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm"
xpra_repo_path="/etc/yum.repos.d/xpra.repo"
xpra_url="https://xpra.org/repos/CentOS/xpra.repo"
microsoft_packages_url="https://packages.microsoft.com/config/rhel/7/packages-microsoft-prod.rpm"
# Override for sovereign or air-gapped clouds where raw.githubusercontent.com is unreachable.
script_source_root="${LINUXBROKER_SCRIPT_SOURCE_ROOT:-https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main}"
script_source_root="${script_source_root%/}"

release_session_url="$script_source_root/linux_host/session_release_buffer/RHEL/release-session.sh"
xrdp_who_xorg_url="$script_source_root/linux_host/session_release_buffer/xrdp-who-xorg.sh"
logind_watcher_url="$script_source_root/linux_host/session_release_buffer/logind-session-watcher.sh"
create_user_script_url="$script_source_root/linux_host/create-user.sh"
create_user_script="/usr/local/bin/create-user.sh"
manage_lease_script_url="$script_source_root/linux_host/manage-lease.sh"
manage_lease_script="/usr/local/bin/manage-lease.sh"
screensaver_settings_url="$script_source_root/linux_host/session_release_buffer/RHEL/00-screensaver"
screensaver_locks_url="$script_source_root/linux_host/session_release_buffer/RHEL/screensaver"

arch=$( /bin/arch )
remoteAccessTool="both"  # Options: "xrdp", "xpra", or "both"

# Disable the GNOME screen saver and screen lock on this host. Enabled by default because a
# locked greeter inside an xrdp/xpra session often cannot be unlocked after a reconnect, which
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

orgId="${RHEL_ORG_ID:-}"
activationKey="${RHEL_ACTIVATION_KEY:-}"

output_directory="/usr/local/bin"
dconf_local_directory="/etc/dconf/db/local.d"
dconf_profile_file="/etc/dconf/profile/user"
state_directory="/var/lib/linuxbroker-release-session"

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

if [ -n "$orgId" ] && [ -n "$activationKey" ]; then
    echo "Registering the system..."
    sudo subscription-manager register --org="$orgId" --activationkey="$activationKey"
    sudo subscription-manager repos --enable="rhel-7-server-optional-rpms" --enable="rhel-7-server-extras-rpms" --enable="rhel-7-server-rh-common-rpms"
else
    echo "Skipping system registration."
fi

echo "Updating and upgrading system packages..."
sudo yum update -y

sudo yum install -y "$epel_url"
sudo yum install -y "$microsoft_packages_url"
sudo wget -O "$xpra_repo_path" "$xpra_url"
sudo yum install -y wget util-linux azure-cli nfs-utils xorgxrdp curl jq
sudo yum groupinstall -y "Server with GUI"

case "$remoteAccessTool" in
    "xrdp")
        remoteAccessPackages=("xrdp")
        ;;
    "xpra")
        remoteAccessPackages=("xpra")
        ;;
    "both")
        remoteAccessPackages=("xrdp" "xpra")
        ;;
    *)
        echo "Unsupported remote access tool: $remoteAccessTool"
        exit 1
        ;;
esac

for pkg in "${remoteAccessPackages[@]}"; do
    sudo yum install -y "$pkg"
done

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

echo "Configuring firewall to allow $remoteAccessTool connections..."
sudo firewall-cmd --permanent --add-port=22/tcp  # Always allow SSH

if [ "$remoteAccessTool" = "xrdp" ] || [ "$remoteAccessTool" = "both" ]; then
    sudo firewall-cmd --permanent --add-port=3389/tcp
    sudo firewall-cmd --permanent --add-port=443/tcp
    if sudo systemctl is-active --quiet xrdp; then
        echo "xrdp service is already active."
    else
        echo "Starting and enabling xrdp service..."
        sudo systemctl start xrdp
        sudo systemctl enable xrdp --now
    fi
fi

if [ "$remoteAccessTool" = "xpra" ] || [ "$remoteAccessTool" = "both" ]; then
    sudo firewall-cmd --permanent --add-port=443/tcp
    if sudo systemctl is-active --quiet xpra; then
        echo "xpra service is already active."
    else
        echo "Starting and enabling xpra service..."
        sudo systemctl start xpra
        sudo systemctl enable xpra --now
    fi
fi

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

sudo chmod +x "$SCRIPT_PATH"
sudo chmod +x "$output_directory/xrdp-who-xorg.sh"
sudo chmod +x "$WATCHER_SCRIPT_PATH"
sudo chmod +x "$create_user_script"
sudo chmod +x "$manage_lease_script"
echo "Downloaded scripts are now executable."

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
# (mount, chown, chmod, lease markers) happens inside the two allowlisted scripts.
cmds=(userdel groupadd usermod chpasswd "$create_user_script" "$manage_lease_script")
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

# Disable screen lock on Gnome desktop
if [ "$disableScreenLock" = "true" ]; then
    echo "Disabling the Gnome Desktop screen saver and screen lock..."

    sudo mkdir -p "$dconf_local_directory/locks"

    echo "Downloading Gnome Desktop screen lock settings..."
    if ! sudo wget -O "$dconf_local_directory/00-screensaver" "$screensaver_settings_url"; then
        echo "ERROR: Failed to download screen lock settings from $screensaver_settings_url"
        exit 1
    fi

    if ! sudo wget -O "$dconf_local_directory/locks/screensaver" "$screensaver_locks_url"; then
        echo "ERROR: Failed to download screen lock overrides from $screensaver_locks_url"
        exit 1
    fi

    sudo chmod 644 "$dconf_local_directory/00-screensaver" "$dconf_local_directory/locks/screensaver"

    # A system dconf database is only consulted when a profile references it. RHEL does not
    # ship /etc/dconf/profile/user, so without this the settings above are silently ignored.
    sudo mkdir -p "$(dirname "$dconf_profile_file")"
    if [ ! -s "$dconf_profile_file" ]; then
        printf 'user-db:user\nsystem-db:local\n' | sudo tee "$dconf_profile_file" >/dev/null
        echo "Created dconf profile $dconf_profile_file."
    elif ! grep -qx 'system-db:local' "$dconf_profile_file"; then
        # Guarantee a trailing newline before appending to an existing profile.
        sudo sed -i -e '$a\' "$dconf_profile_file"
        echo 'system-db:local' | sudo tee -a "$dconf_profile_file" >/dev/null
        echo "Added system-db:local to existing dconf profile $dconf_profile_file."
    else
        echo "dconf profile $dconf_profile_file already references system-db:local."
    fi
    sudo chmod 644 "$dconf_profile_file"

    if ! sudo dconf update; then
        echo "ERROR: 'dconf update' failed; the screen lock settings were not applied."
        exit 1
    fi

    echo "Gnome Desktop screen lock is disabled."
else
    echo "Skipping Gnome Desktop screen lock configuration (LINUXBROKER_DISABLE_SCREEN_LOCK=false)."
fi

echo "System configuration complete."
