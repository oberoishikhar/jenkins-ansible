#!/bin/bash
#
# restrict-installer-network.sh
# Restricts the 'installer' user to local-only network access
# Allows SSH (port 22) and loopback, blocks all other internet access
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== Installer User Network Restriction Setup ===${NC}\n"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Verify 'installer' user exists
if ! id installer &>/dev/null; then
    echo -e "${RED}ERROR: 'installer' user does not exist${NC}"
    exit 1
fi

# Get installer UID
INSTALLER_UID=$(id -u installer)
echo -e "${GREEN}✓${NC} Found installer user (UID: $INSTALLER_UID)"

# Verify firewalld is running
if ! systemctl is-active --quiet firewalld; then
    echo -e "${YELLOW}⚠ firewalld is not running, starting it...${NC}"
    systemctl start firewalld
fi
echo -e "${GREEN}✓${NC} firewalld is running"

echo ""
echo "Applying firewall rules..."
echo "  - Allowing loopback (127.0.0.1)"
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 -m owner --uid-owner $INSTALLER_UID -d 127.0.0.1 -j ACCEPT

echo "  - Allowing SSH outbound (port 22)"
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 1 -m owner --uid-owner $INSTALLER_UID -p tcp --dport 22 -j ACCEPT

echo "  - Allowing SSH return traffic (port 22)"
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 2 -m owner --uid-owner $INSTALLER_UID -p tcp --sport 22 -j ACCEPT

echo "  - Blocking all other outbound traffic"
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 99 -m owner --uid-owner $INSTALLER_UID -j DROP

# Reload firewall
echo ""
echo "Reloading firewall configuration..."
firewall-cmd --reload

echo ""
echo -e "${GREEN}✓ Firewall rules applied successfully!${NC}\n"

# Display the rules that were added
echo "Applied rules:"
firewall-cmd --direct --get-all-rules | grep $INSTALLER_UID || echo "  (rules stored in firewalld permanent config)"

echo ""
echo -e "${YELLOW}=== Verification ===${NC}\n"

echo "To test the restrictions, run these commands as the 'installer' user:\n"
echo -e "  ${GREEN}Should work:${NC}"
echo "    ping 127.0.0.1"
echo "    ssh user@somehost"
echo ""
echo -e "  ${RED}Should timeout/fail:${NC}"
echo "    ping 8.8.8.8"
echo "    curl https://example.com"
echo "    sudo apt-get update  (or yum in Oracle Linux)"
echo ""

echo -e "${GREEN}✓ Setup complete!${NC}"
echo "Rules are persistent and will survive reboots."
