#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on Ubuntu 24 desktop

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

# Override for sovereign or air-gapped clouds where raw.githubusercontent.com is unreachable.
script_source_root="${LINUXBROKER_SCRIPT_SOURCE_ROOT:-https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main}"
script_source_root="${script_source_root%/}"

release_session_url="$script_source_root/linux_host/session_release_buffer/Ubuntu/release-session.sh"
xrdp_who_xorg_url="$script_source_root/linux_host/session_release_buffer/xrdp-who-xorg.sh"
logind_watcher_url="$script_source_root/linux_host/session_release_buffer/logind-session-watcher.sh"
create_user_script_url="$script_source_root/linux_host/create-user.sh"
create_user_script="/usr/local/bin/create-user.sh"
manage_lease_script_url="$script_source_root/linux_host/manage-lease.sh"
manage_lease_script="/usr/local/bin/manage-lease.sh"

arch=$(uname -m)
remoteAccessTool="both"  # Options: "xrdp", "xpra", or "both"

output_directory="/usr/local/bin"
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

echo "Updating and upgrading system packages..."
sudo apt update -y && sudo apt upgrade -y

# Install necessary dependencies
echo "Installing necessary packages..."
sudo apt install -y wget curl software-properties-common gnupg2

# Add Microsoft packages repository
echo "Adding Microsoft packages repository..."
wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt update -y

# Add Xpra repository
echo "Adding Xpra repository..."
sudo add-apt-repository ppa:xpra/stable -y
sudo apt update -y

# Install Azure CLI
echo "Installing Azure CLI..."
sudo apt install -y azure-cli nfs-common jq

# Optional: Install Desktop Environment (Uncomment if needed)
# echo "Installing Desktop Environment..."
# sudo apt install -y xfce4 xfce4-goodies  # Lightweight desktop environment

# Install remote access tools
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

echo "Installing remote access packages: ${remoteAccessPackages[*]}"
for pkg in "${remoteAccessPackages[@]}"; do
    sudo apt install -y "$pkg"
done

if [[ "$remoteAccessTool" == "xrdp" || "$remoteAccessTool" == "both" ]]; then
    sudo apt install -y xorgxrdp
fi

echo "Setting default target to graphical..."
sudo systemctl set-default graphical.target

echo "Starting graphical target..."
sudo systemctl start graphical.target

# Configure Firewall using UFW
echo "Configuring firewall..."
sudo apt install -y ufw
sudo ufw allow OpenSSH

if [[ "$remoteAccessTool" == "xrdp" || "$remoteAccessTool" == "both" ]]; then
    sudo ufw allow 3389/tcp
    sudo ufw allow 443/tcp
fi

if [[ "$remoteAccessTool" == "xpra" || "$remoteAccessTool" == "both" ]]; then
    sudo ufw allow 443/tcp
fi

sudo ufw --force enable
echo "Firewall configuration completed."

# Download and set up scripts
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

echo "System configuration complete."
