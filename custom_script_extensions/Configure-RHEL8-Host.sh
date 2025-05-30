#!/bin/sh

# Installs and configures the necessary packages for Linux Broker for AVD Access on RHEL 8

# ===============================
# Variables

# Default definition for the main project
GH_OWNER="microsoft"
GH_REPO="LinuxBrokerForAVDAccess"
GH_BRANCH="main"

# if GIT repo, parse out the config data
remote_url=$(git config --get remote.origin.url 2>/dev/null)
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

# if current repo is a different fork/branch, change it accordingly
if [[ "$remote_url" =~ github.com[/:]([^/]+)/([^/.]+) ]]; then
    GH_OWNER="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]}"
    GH_BRANCH="$branch"
fi

epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"
xpra_repo_path="/etc/yum.repos.d/xpra.repo"
xpra_url="https://raw.githubusercontent.com/Xpra-org/xpra/master/packaging/repos/almalinux/xpra.repo"
microsoft_packages_url="https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm"
release_session_url="https://raw.githubusercontent.com/$GH_OWNER/LinuxBrokerForAVDAccess/refs/heads/$GH_BRANCH/linux_host/session_release_buffer/RHEL/release-session.sh"
xrdp_who_xorg_url="https://raw.githubusercontent.com/$GH_OWNER/LinuxBrokerForAVDAccess/refs/heads/$GH_BRANCH/linux_host/session_release_buffer/xrdp-who-xorg.sh"
screensaver_settings_url="https://raw.githubusercontent.com/$GH_OWNER/LinuxBrokerForAVDAccess/refs/heads/$GH_BRANCH/linux_host/session_release_buffer/RHEL/00-screensaver"
screensaver_locks_url="https://raw.githubusercontent.com/$GH_OWNER/LinuxBrokerForAVDAccess/refs/heads/$GH_BRANCH/linux_host/session_release_buffer/RHEL/screensaver"
xrdp_ini="/etc/xrdp/xrdp.ini"

arch=$( /bin/arch )
remoteAccessTool="both"  # Options: "xrdp", "xpra", or "both"

register="true"
orgId="ORG_ID"
activationKey="ACTIVATION_KEY"

output_directory="/usr/local/bin"
dconf_local_directory="/etc/dconf/db/local.d"

SCRIPT_PATH="$output_directory/release-session.sh"
LOCK_FILE="/tmp/release-session.lockfile"
LOG_FILE="/var/log/release-session.log"
CURRENT_USERS_DETAILS="$output_directory/xrdp-loggedin-users.txt"

CRON_SCHEDULE="0 * * * *" 

YOUR_LINUXBROKER_API_CLIENT_ID="my_actual_client_id"
YOUR_LINUXBROKER_API_URL="my.actual.linuxbroker.api.url"

# ===============================
# Execution

if [ "$register" = "true" ]; then
    echo "Registering the system..."
    sudo subscription-manager register --org="$orgId" --activationkey="$activationKey"
    sudo subscription-manager repos --enable "codeready-builder-for-rhel-8-${arch}-rpms"
else
    echo "Skipping system registration."
fi

echo "Updating and upgrading system packages..."
sudo dnf update -y && sudo dnf upgrade -y

sudo dnf install -y "$epel_url"
sudo dnf install -y "$microsoft_packages_url"
sudo wget -O "$xpra_repo_path" "$xpra_url"
sudo dnf install -y wget util-linux azure-cli xorgxrdp
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

for pkg in "${remoteAccessPackages[@]}"; do
    sudo dnf install -y "$pkg"
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
    sudo firewall-cmd --permanent --add-service=ms-wbt
    sudo firewall-cmd --permanent --add-port=443/tcp
    if systemctl is-active --quiet xrdp; then
        echo "xrdp service is already active."
    else
        echo "Starting and enabling xrdp service..."
        sudo systemctl start xrdp
        sudo systemctl enable xrdp --now
    fi
fi

if [ "$remoteAccessTool" = "xpra" ] || [ "$remoteAccessTool" = "both" ]; then
    sudo firewall-cmd --permanent --add-port=443/tcp
    if systemctl is-active --quiet xpra; then
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
sudo sed -i "s|YOUR_LINUX_BROKER_API_URL|$YOUR_LINUXBROKER_API_URL|g" "$SCRIPT_PATH"

echo "Downloading xrdp-who-xorg.sh..."
sudo wget -O "$output_directory/xrdp-who-xorg.sh" "$xrdp_who_xorg_url"

sudo chmod +x "$SCRIPT_PATH" 
sudo chmod +x "$output_directory/xrdp-who-xorg.sh"
echo "Downloaded scripts are now executable."

sudo touch "$LOG_FILE" "$CURRENT_USERS_DETAILS"
sudo chmod 666 "$LOG_FILE" 
sudo chmod 666 "$CURRENT_USERS_DETAILS"

CRON_JOB="$CRON_SCHEDULE /usr/bin/flock -n $LOCK_FILE $SCRIPT_PATH --cron"

if (sudo crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH"); then
    echo "Cron job already exists in root's crontab. No changes made."
    echo "System configuration complete."
    exit 0
fi

(sudo crontab -l 2>/dev/null; echo "$CRON_JOB") | sudo crontab -
echo "Cron job added to root's crontab successfully."

# XRDP.ini - change default X windows from Xvnc to Xorg
# Enable [Xorg] block: uncomment the header and specific lines
sudo sed -i '/^\s*#\[Xorg\]/ s/^#//' "$xrdp_ini"
sudo sed -i '/^\[Xorg\]/,/^\[/ {
 s/^#\(name=Xorg\)/\1/
 s/^#\(lib=libxup.so\)/\1/
 s/^#\(username=ask\)/\1/
 s/^#\(password=ask\)/\1/
 s/^#\(port=-1\)/\1/
 s/^#\(code=20\)/\1/
}' "$xrdp_ini"

# Disable [Xvnc] block: comment the header and all non-comment lines
sudo sed -i '/^\[Xvnc\]/ s/^\[Xvnc\]/#[Xvnc]/' "$xrdp_ini"
sudo sed -i '/^#[Xvnc\]/,/^\[/ {
 s/^\([^\[#;].*\)/#\1/
}' "$xrdp_ini"

sudo systemctl restart xrdp
echo "XRDP is configured with Xorg"

# Creaet AVDUser and give limited sudo rights
sudo useradd avdadmin
cmds=(getent useradd userdel groupadd id usermod chpasswd)
full_paths=$(for cmd in "${cmds[@]}"; do command -v "$cmd"; done | paste -sd ',' -)
echo "avdadmin ALL=(ALL) NOPASSWD: $full_paths" > avdadmin
sudo cp avdadmin /etc/sudoers.d
sudo chmod 440 /etc/sudoers.d/avdadmin
# Note: public ssh key is still needed for avdadmin
echo "avdadmin user is created and permissioned"

# Disable screen lock on Gnome desktop
echo "Downloading Gnome Desktop screen lock settings..."
sudo wget -O "$dconf_local_directory/00-screensaver" "$screensaver_settings_url"
sudo wget -O "$dconf_local_directory/locks/screensaver" "$screensaver_locks_url"
sudo dconf update

# Complete
echo "System configuration complete."
