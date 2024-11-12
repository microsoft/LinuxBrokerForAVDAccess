#!/bin/bash

# Installs and configures the necessary packages for Linux Broker for AVD Access on RHEL 9

# ===============================
# Variables

epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
xpra_repo_path="/etc/yum.repos.d/xpra.repo"
xpra_url="https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/rhel/xpra.repo"
microsoft_packages_url="https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm"
release_session_url="https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/linux_host/session_release_buffer/RHEL/release-session.sh"
xrdp_who_xnc_url="https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/linux_host/session_release_buffer/xrdp-who-xnc.sh"

arch=$( /bin/arch )
remoteAccessTool="both"  # Options: "xrdp", "xpra", or "both"

register="true"
orgId="ORG_ID"
activationKey="ACTIVATION_KEY"

output_directory="/usr/local/bin"

SCRIPT_PATH="$output_directory/release-session.sh"
LOCK_FILE="/tmp/release-session.lockfile"
LOG_FILE="/var/log/release-session.log"
CURRENT_USERS_DETAILS="$output_directory/xrdp-loggedin-users.txt"

CRON_SCHEDULE="0 * * * *"

# ===============================
# Execution

set -e  # Exit immediately if a command exits with a non-zero status

if [ "$register" = "true" ]; then
    echo "Registering the system..."
    sudo subscription-manager register --org="$orgId" --activationkey="$activationKey"
    sudo subscription-manager repos --enable "codeready-builder-for-rhel-9-${arch}-rpms" --enable "rhel-9-for-x86_64-appstream-rpms" --enable "rhel-9-for-x86_64-baseos-rpms"
else
    echo "Skipping system registration."
fi

echo "Updating and upgrading system packages..."
sudo dnf update -y && sudo dnf upgrade -y

echo "Installing EPEL repository..."
sudo dnf install -y "$epel_url"

echo "Installing Microsoft repository..."
sudo dnf install -y "$microsoft_packages_url"

echo "Adding Xpra repository..."
sudo wget -O "$xpra_repo_path" "$xpra_url"

echo "Installing essential packages..."
sudo dnf install -y wget util-linux azure-cli

echo "Installing 'Server with GUI' group..."
sudo dnf groupinstall -y "Server with GUI"

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

echo "Installing remote access packages: ${remoteAccessPackages[@]}..."
sudo dnf install -y "${remoteAccessPackages[@]}"

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

if [[ "$remoteAccessTool" == "xrdp" || "$remoteAccessTool" == "both" ]]; then
    sudo firewall-cmd --permanent --add-port=3389/tcp
    sudo firewall-cmd --permanent --add-port=443/tcp
    sudo firewall-cmd --permanent --add-service=ms-wbt || echo "Service 'ms-wbt' may not be available. Skipping."
    if systemctl is-active --quiet xrdp; then
        echo "xrdp service is already active."
    else
        echo "Starting and enabling xrdp service..."
        sudo systemctl start xrdp
        sudo systemctl enable xrdp --now
    fi
fi

if [[ "$remoteAccessTool" == "xpra" || "$remoteAccessTool" == "both" ]]; then
    sudo firewall-cmd --permanent --add-port=443/tcp
    if systemctl is-active --quiet xpra; then
        echo "xpra service is already active."
    else
        echo "Starting and enabling xpra service..."
        sudo systemctl start xpra
        sudo systemctl enable xpra --now
    fi
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

echo "Downloading xrdp-who-xnc.sh..."
sudo wget -O "$output_directory/xrdp-who-xnc.sh" "$xrdp_who_xnc_url"

echo "Setting execute permissions for downloaded scripts..."
sudo chmod +x "$SCRIPT_PATH"
sudo chmod +x "$output_directory/xrdp-who-xnc.sh"
echo "Downloaded scripts are now executable."

echo "Creating log and user details files..."
sudo touch "$LOG_FILE" "$CURRENT_USERS_DETAILS"
sudo chmod 666 "$LOG_FILE"
sudo chmod 666 "$CURRENT_USERS_DETAILS"

CRON_JOB="$CRON_SCHEDULE /usr/bin/flock -n $LOCK_FILE $SCRIPT_PATH --cron"

if sudo crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" > /dev/null; then
    echo "Cron job already exists in root's crontab. No changes made."
    echo "System configuration complete."
    exit 0
fi

echo "Adding cron job to root's crontab..."
( sudo crontab -l 2>/dev/null; echo "$CRON_JOB" ) | sudo crontab -
echo "Cron job added to root's crontab successfully."
echo "System configuration complete."
