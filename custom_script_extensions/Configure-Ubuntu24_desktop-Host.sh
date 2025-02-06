#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on Ubuntu 24 desktop

# ===============================
# Variables

release_session_url="https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/linux_host/session_release_buffer/Ubuntu/release-session.sh"
xrdp_who_xnc_url="https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/linux_host/session_release_buffer/xrdp-who-xnc.sh"

arch=$(uname -m)
remoteAccessTool="both"  # Options: "xrdp", "xpra", or "both"

output_directory="/usr/local/bin"

SCRIPT_PATH="$output_directory/release-session.sh"
LOCK_FILE="/tmp/release-session.lockfile"
LOG_FILE="/var/log/release-session.log"
CURRENT_USERS_DETAILS="$output_directory/xrdp-loggedin-users.txt"

CRON_SCHEDULE="0 * * * *" 

YOUR_LINUXBROKER_API_CLIENT_ID="my_actual_client_id"
YOUR_LINUXBROKER_API_URL="my.actual.linuxbroker.api.url"

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
sudo apt install -y azure-cli

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
sudo sed -i "s|YOUR_LINUX_BROKER_API_URL|$YOUR_LINUXBROKER_API_URL|g" "$SCRIPT_PATH"

echo "Downloading xrdp-who-xnc.sh..."
sudo wget -O "$output_directory/xrdp-who-xnc.sh" "$xrdp_who_xnc_url"

sudo chmod +x "$SCRIPT_PATH" 
sudo chmod +x "$output_directory/xrdp-who-xnc.sh"
echo "Downloaded scripts are now executable."

sudo touch "$LOG_FILE" "$CURRENT_USERS_DETAILS"
sudo chmod 666 "$LOG_FILE" 
sudo chmod 666 "$CURRENT_USERS_DETAILS"

CRON_JOB="$CRON_SCHEDULE /usr/bin/flock -n $LOCK_FILE $SCRIPT_PATH --cron"

if sudo crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" > /dev/null; then
    echo "Cron job already exists in root's crontab. No changes made."
    echo "System configuration complete."
    exit 0
fi

( sudo crontab -l 2>/dev/null; echo "$CRON_JOB" ) | sudo crontab -
echo "Cron job added to root's crontab successfully."
echo "System configuration complete."
