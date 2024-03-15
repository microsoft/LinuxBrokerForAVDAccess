#!/bin/sh
subscription-manager register --org="ID" --activationkey="KEY"

echo "Updating and upgrading system packages..."
yum update -y && yum upgrade -y

# Check to see if wget is installed
if ! rpm -q wget; then
    echo "Installing wget..."
    sudo yum install wget -y
else
    echo "wget is already installed."
fi

# Check to see if util-linux is installed
if ! rpm -q util-linux; then
    echo "Installing util-linux..."
    sudo yum install util-linux -y
else
    echo "util-linux is already installed."
fi

echo "Creating release-session directory..."
mkdir -p ~/release-session

echo "Downloading xrdp-who-xnc.sh script..."
wget https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/LinuxSessionRelease/xrdp-who-xnc.sh -O ~/release-session/xrdp-who-xnc.sh

echo "Downloading release-session.sh script..."
wget https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/main/LinuxSessionRelease/release-session.sh -O ~/release-session/release-session.sh

echo "Assigning execute permissions to release-session.sh..."
chmod +x ~/release-session/release-session.sh # assign execute permissions

echo "Updated crontab to run release-session.sh every 5 minutes"
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/flock -n ~/release-session/release-session.lock ~/release-session/release-session.sh >> ~/release-session/release-session.log 2>&1") | crontab -

echo "Creating logrotate configuration for release-session.log..."
bash -c 'cat << EOF > /etc/logrotate.d/release-session
~/release-session/release-session.log {
    size 16M
    rotate 20
    compress
    missingok
    notifempty
    create 644
}
EOF'

# Check if the Azure CLI is installed
if ! rpm -q azure-cli; then
    echo "Installing Azure CLI..."
    sh -c 'echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/azure-cli.repo'
    yum install azure-cli -y
else
    echo "Azure CLI is already installed."
fi

# Check if the "Server with GUI" group package is installed
if yum group list installed "Server with GUI" &> /dev/null; then
    echo "'Server with GUI' group package is already installed."
else
    echo "Installing 'Server with GUI' group package..."
    yum groupinstall "Server with GUI" -y
fi

echo "Setting default target to graphical..."
systemctl set-default graphical.target

echo "Starting graphical target..."
systemctl start graphical.target

if systemctl is-active --quiet firewalld; then
    echo "Firewalld is already active."
else
    echo "Enabling and starting firewalld..."
    systemctl enable --now firewalld
fi

echo "Configuring firewall to allow RDP and SSH connections..."
firewall-cmd --permanent --add-port=3389/tcp
firewall-cmd --permanent --add-port=22/tcp
firewall-cmd --reload

# Check if the EPEL repository is installed
if ! rpm -q epel-release; then
    echo "Installing EPEL repository..."
    yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm -y
else
    echo "EPEL repository is already installed."
fi

# Define the packages to check and install
packages=("xrdp" "tigervnc" "xterm")

# Loop through each package
for pkg in "${packages[@]}"; do
    # Check if the package is installed
    if rpm -q $pkg &> /dev/null; then
        echo "$pkg is already installed."
    else
        echo "Installing $pkg..."
        yum install $pkg -y
    fi
done

# Enable and start xrdp service
if systemctl is-active --quiet xrdp; then
    echo "xrdp service is already active."
else
    echo "Starting and enabling xrdp service..."
    systemctl start xrdp
    systemctl enable xrdp
fi


echo "System configuration complete. Rebooting now..."
# Ensure you have appropriate logic to handle or warn about the reboot if needed
reboot
