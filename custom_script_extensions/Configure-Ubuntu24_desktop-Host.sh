#!/bin/bash
set -euo pipefail

# Installs and configures the necessary packages for Linux Broker for AVD Access on Ubuntu 24 desktop

LINUXBROKER_API_BASE_URL="${1:-}"
LINUXBROKER_API_CLIENT_ID="${2:-}"
broker_agent_source="${LINUXBROKER_LOCAL_AGENT_DIRECTORY:?Use the checksum-verified deployment extension to stage bootstrap and helper files first.}"
[[ "$broker_agent_source" = /* ]] || { echo 'An absolute verified helper directory is required.' >&2; exit 1; }
sudo bash "$broker_agent_source/check-broker-host-prerequisites.sh" platform
broker_admin_username="${LINUXBROKER_ADMIN_USERNAME:-avdadmin}"
if [[ ! "$broker_admin_username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$broker_admin_username" = root ]; then
    echo 'Invalid broker SSH administrator username.' >&2
    exit 1
fi
if sudo test -e /var/lib/linuxbroker-release-session/lease.json ||
   { sudo test -d /var/lib/linuxbroker-release-session/leases &&
     [ -n "$(sudo find /var/lib/linuxbroker-release-session/leases -mindepth 1 -maxdepth 1 -print -quit)" ]; }; then
    echo 'Existing lease state requires the reviewed Migrate-ExistingEnvironment.ps1 flow, not bootstrap.' >&2
    exit 1
fi

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

create_user_script="/usr/local/bin/create-user.sh"
manage_lease_script="/usr/local/bin/manage-lease.sh"
apply_settings_script="/usr/local/bin/apply-host-settings.sh"

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
sudo apt install -y azure-cli nfs-common jq dconf-cli python3 util-linux iproute2 procps passwd
sudo python3 "$broker_agent_source/install-broker-python.py" --config-base64 "${LINUXBROKER_PYTHON_RUNTIME_CONFIG:?The pinned private Python runtime configuration is required.}"

# Idle session enforcement degrades gracefully without xprintidle, so a host that cannot
# install it must still finish provisioning rather than fail the extension.
echo "Installing idle detection support..."
sudo apt install -y xprintidle || echo "xprintidle is unavailable. Idle session enforcement will be skipped on this host."

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

echo "Installing verified release-session.sh..."
sudo install -o root -g root -m 0755 "$broker_agent_source/release-session.sh" "$SCRIPT_PATH"

sudo sed -i "s|YOUR_LINUX_BROKER_API_CLIENT_ID|$YOUR_LINUXBROKER_API_CLIENT_ID|g" "$SCRIPT_PATH"
sudo sed -i "s|YOUR_LINUX_BROKER_API_BASE_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"
sudo sed -i "s|YOUR_LINUX_BROKER_API_URL|$YOUR_LINUXBROKER_API_BASE_URL|g" "$SCRIPT_PATH"

echo "Installing verified xrdp-who-xorg.sh..."
sudo install -o root -g root -m 0755 "$broker_agent_source/xrdp-who-xorg.sh" "$output_directory/xrdp-who-xorg.sh"

echo "Installing verified logind-session-watcher.sh..."
sudo install -o root -g root -m 0755 "$broker_agent_source/logind-session-watcher.sh" "$WATCHER_SCRIPT_PATH"

echo "Installing verified create-user.sh..."
sudo install -o root -g root -m 0755 "$broker_agent_source/create-user.sh" "$create_user_script"

echo "Installing verified lease and reconciliation helpers..."
sudo install -o root -g root -m 0755 "$broker_agent_source/manage-lease.sh" "$manage_lease_script"
sudo install -o root -g root -m 0755 "$broker_agent_source/broker-lease.py" "$output_directory/broker-lease.py"
sudo install -o root -g root -m 0755 "$broker_agent_source/broker-freezer.py" "$output_directory/broker-freezer.py"
sudo install -o root -g root -m 0755 "$broker_agent_source/configure-broker-xrdp-gate.py" "$output_directory/configure-broker-xrdp-gate.py"
sudo install -o root -g root -m 0755 "$broker_agent_source/release-session-common.sh" "$output_directory/release-session-common.sh"

echo "Installing verified apply-host-settings.sh..."
sudo install -o root -g root -m 0755 "$broker_agent_source/apply-host-settings.sh" "$apply_settings_script"

sudo chmod +x "$SCRIPT_PATH"
sudo chmod +x "$output_directory/xrdp-who-xorg.sh"
sudo chmod +x "$WATCHER_SCRIPT_PATH"
sudo chmod +x "$create_user_script"
sudo chmod +x "$manage_lease_script"
sudo chmod +x "$apply_settings_script"
sudo chown root:root "$SCRIPT_PATH" "$WATCHER_SCRIPT_PATH" "$output_directory/xrdp-who-xorg.sh" \
    "$create_user_script" "$manage_lease_script" "$apply_settings_script" \
    "$output_directory/broker-lease.py" "$output_directory/release-session-common.sh"
sudo chmod 0755 "$SCRIPT_PATH" "$WATCHER_SCRIPT_PATH" "$output_directory/xrdp-who-xorg.sh" \
    "$create_user_script" "$manage_lease_script" "$apply_settings_script" \
    "$output_directory/broker-lease.py" "$output_directory/release-session-common.sh"
echo "Downloaded scripts are now executable."

sudo install -d -o root -g root -m 0700 "$state_directory" "$state_directory/leases"
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

echo "Existing legacy processes must be quiesced through the coordinated migration, never by killing user desktops."

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

echo "Staging systemd units; post-provision activates them after trusted host enrollment."
sudo systemctl daemon-reload
sudo systemctl disable --now "$WATCHER_SERVICE_NAME" "$SYSTEMD_TIMER_NAME" "$SYSTEMD_SERVICE_NAME"

id "$broker_admin_username" >/dev/null

full_paths="$create_user_script *, $manage_lease_script cleanup *, $apply_settings_script \"\""
sudoers_tmp="/etc/sudoers.d/avdadmin.tmp"
echo "$broker_admin_username ALL=(root) NOPASSWD: $full_paths" | sudo tee "$sudoers_tmp" >/dev/null
sudo chown root:root "$sudoers_tmp"
sudo chmod 440 "$sudoers_tmp"
if sudo visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
    sudo mv "$sudoers_tmp" /etc/sudoers.d/avdadmin
else
    sudo rm -f "$sudoers_tmp"
    echo "ERROR: Generated sudoers policy failed validation."
    exit 1
fi
echo "Broker administrator is permissioned only for validated helpers; marker migration is deployment-root only."

# Screen lock policy is generated by apply-host-settings.sh from the fleet-wide settings
# profile, so every supported distribution now receives it. Seeding the defaults here means
# the host starts converged, and the release agent applies any configured profile on its
# next run.
echo "Applying default Linux Broker host settings..."
sudo "$apply_settings_script" --defaults

sudo /usr/local/libexec/linuxbroker/python3 -I "$output_directory/configure-broker-xrdp-gate.py" --enroll-drained --admin-username "$broker_admin_username"
sudo bash "$broker_agent_source/check-broker-host-prerequisites.sh" full
echo "System configuration complete."
