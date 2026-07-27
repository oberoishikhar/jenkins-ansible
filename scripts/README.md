# Utility Scripts

This directory contains utility scripts for deployment and configuration management.

## restrict-installer-network.sh

Restricts a Linux user account to local-only network access while preserving SSH connectivity for remote administration.

### Purpose

Creates firewall rules that:
- **Allow** loopback (127.0.0.1) communication
- **Allow** SSH inbound/outbound (port 22)
- **Block** all other outbound internet access

This is useful for restricted service accounts that should execute local commands and scripts but shouldn't be able to:
- Update packages from online repositories
- Download software from the internet
- Exfiltrate data over the network

### Usage

#### Quick Copy & Run

```bash
# From your local machine, copy and execute in one go:
scp scripts/restrict-installer-network.sh admin@<remote-ip>: && \
ssh admin@<remote-ip> 'chmod +x restrict-installer-network.sh && sudo ./restrict-installer-network.sh'
```

#### Step by Step

**1. Copy script to remote machine:**
```bash
scp scripts/restrict-installer-network.sh admin@192.168.1.5:
```

**2. SSH into remote machine:**
```bash
ssh admin@192.168.1.5
```

**3. Run with sudo:**
```bash
chmod +x restrict-installer-network.sh
sudo ./restrict-installer-network.sh
```

### Testing the Restrictions

After setup, test as the restricted user (e.g., `installer`):

**These should work:**
```bash
ping 127.0.0.1           # loopback
ssh user@somehost        # SSH connectivity
```

**These should timeout/fail:**
```bash
ping 8.8.8.8             # external IP
curl https://example.com # internet access
sudo yum update          # package repository (Oracle Linux)
sudo apt-get update      # package repository (Debian/Ubuntu)
```

### Persistence

Rules are applied with `--permanent` flag, so they survive:
- Firewall service restarts
- System reboots

### Troubleshooting

**View applied rules:**
```bash
sudo firewall-cmd --direct --get-all-rules | grep <UID>
```

**Remove all restrictions for a user (if needed):**
```bash
# Get user UID
INSTALLER_UID=$(id -u installer)

# Remove rules
sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 0 -m owner --uid-owner $INSTALLER_UID -d 127.0.0.1 -j ACCEPT
sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 1 -m owner --uid-owner $INSTALLER_UID -p tcp --dport 22 -j ACCEPT
sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 2 -m owner --uid-owner $INSTALLER_UID -p tcp --sport 22 -j ACCEPT
sudo firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 99 -m owner --uid-owner $INSTALLER_UID -j DROP

# Reload
sudo firewall-cmd --reload
```

### Requirements

- Target system must have `firewalld` installed and running (default on Oracle Linux 9.x, RHEL, CentOS)
- User to restrict must already exist on the system
- Must be run with `sudo` privileges

### Notes

- The script is idempotent (safe to run multiple times)
- Rules are applied per-user UID, not per-username, so they persist even if the user password changes
- SSH on port 22 is explicitly allowed in both directions
- If the restricted user needs access to other local services (databases, APIs, etc.), they will still work
