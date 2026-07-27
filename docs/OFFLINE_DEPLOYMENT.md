# Offline Deployment Guide

Deploy Jenkins + Ansible on air-gapped machines (no internet required at runtime).

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Two-Machine Setup](#two-machine-setup)
3. [Building the Offline Bundle](#building-the-offline-bundle-build-machine)
4. [Deploying to Oracle Linux](#deploying-to-oracle-linux-target-machine)
5. [Deploying to RHEL](#deploying-to-rhel-target-machine)
6. [Managing Deployments Offline](#managing-deployments-offline)
7. [Troubleshooting](#troubleshooting)

---

## Overview

**Offline deployment** means:
- ✅ Pre-download Jenkins, Ansible, and all dependencies on an internet-connected machine
- ✅ Bundle everything into a single archive (~2.5 GB)
- ✅ Transfer to air-gapped environment (USB drive, secure network, etc.)
- ✅ Run setup without internet — fully self-contained

**Why use this?**
- Deploy to secure/isolated networks (government, healthcare, finance)
- Disconnected datacenters (submarines, remote bases)
- Air-gapped CI/CD systems
- Reduced external dependencies for compliance

---

## Two-Machine Setup

| Role | Machine | Internet | Task |
|------|---------|----------|------|
| **Build** | Build Machine | ✅ Required | Creates offline package (~1 hour, one time) |
| **Deploy** | Target Machine | ❌ Not needed | Runs Jenkins + Ansible from package (~5 min) |

### What the Bundle Contains

```
jenkins-ansible-offline-ol9-YYYYMMDD-HHMMSS.tar.gz (2.5 GB)
│
├── Jenkins-Ansible/                          ← Main project
│   ├── setup.sh, add-project.sh, cleanup.sh
│   ├── Dockerfile, docker-compose.yml
│   ├── jenkins-config/                       ← JCasC config
│   ├── projects/_template/                   ← Example project
│   ├── .env.example
│   └── ... (all other project files)
│
└── offline-bundle/                           ← Pre-downloaded packages
    ├── image/
    │   └── jenkins-ansible-image.tar.gz      (1.5-2 GB)
    ├── rpms/
    │   ├── podman-*.rpm
    │   ├── slirp4netns-*.rpm
    │   ├── fuse-overlayfs-*.rpm
    │   └── ... (other deps)
    └── docs/
        └── (offline guides)
```

---

## Building the Offline Bundle (Build Machine)

**Prerequisites:**
- Linux/macOS/Windows with WSL
- Docker or Podman installed and running
- Internet access
- ~10 GB free disk space (download + build)

### Step 1: Get the Project

```bash
cd /path/to/Jenkins-Ansible
chmod +x setup.sh
```

### Step 2: Build Offline Bundle

```bash
./setup.sh --build-offline-bundle
```

**What this does:**
1. Builds Jenkins + Ansible Docker image (includes all plugins)
2. Compresses the image (~1.5 GB)
3. Downloads Podman RPMs for Oracle Linux / RHEL
4. Downloads Python/Ansible pip wheels
5. Creates final archive: `jenkins-ansible-offline-YYYYMMDD-HHMMSS.tar.gz`

**Output:**
```
✅ Final bundle: jenkins-ansible-offline-20260726-143022.tar.gz
✅ Bundle size: 2.3G
```

**Duration:** 30-60 minutes (first-time Docker pulls are slow)

### Step 3: Transfer Bundle

```bash
# Via SSH (secure network)
scp jenkins-ansible-offline-*.tar.gz user@offline-server:/home/user/

# Via rsync (shows progress)
rsync -avz --progress jenkins-ansible-offline-*.tar.gz user@offline-server:/home/user/

# Via USB (air-gapped machines)
# 1. Copy to external drive: cp jenkins-ansible-offline-*.tar.gz /media/usb/
# 2. Boot from USB on target machine
# 3. cp /media/usb/jenkins-ansible-offline-*.tar.gz ~/
```

---

## Deploying to Oracle Linux (Target Machine)

**Tested on:** Oracle Linux 8.x, 9.x  
**Time:** ~5 minutes for setup, ~90 seconds for Jenkins to start

### Prerequisites

- Oracle Linux 8 or 9
- `sudo` access (one-time only, for Podman setup)
- ~10 GB free disk space
- Ports 8080 (UI) and 50000 (agents) available

### Step 1: Extract Bundle

```bash
cd /home/user
tar -xzf jenkins-ansible-offline-*.tar.gz
cd Jenkins-Ansible

chmod +x setup.sh add-project.sh cleanup.sh
```

### Step 2: Configure (Optional)

```bash
# Copy and edit configuration
cp .env.example .env
nano .env

# Change these if needed:
# - JENKINS_PORT (default: 8080)
# - JENKINS_ADMIN_PASSWORD (MUST change for production!)
```

### Step 3: Run Offline Setup

```bash
./setup.sh --offline
```

This will:
- ✅ Detect Podman / install if needed (requires `sudo` once)
- ✅ Load pre-built image from bundle
- ✅ Start Jenkins container
- ✅ Verify Jenkins is healthy

**Note:** If Podman is not installed, the script will prompt for sudo to install it. This is the **only** time sudo is needed.

### Step 4: Verify Installation

```bash
# Check container is running
podman ps

# Check logs
journalctl --user -u jenkins-ansible -f

# Test connectivity
curl http://localhost:8080/login
```

### Step 5: Access Jenkins

Open your browser:
```
http://<your-server-ip>:8080
```

**Credentials (from .env):**
```
Username: admin
Password: changeme123  (CHANGE THIS!)
```

**Change password immediately:**
1. Click "admin" (top right)
2. Select "Configure"
3. Enter new password
4. Save

---

## Deploying to RHEL (Target Machine)

**Tested on:** RHEL 8.x, 9.x  
**Process:** Same as Oracle Linux, just different packages

### Step 1-4: Same as Oracle Linux

```bash
cd /home/user
tar -xzf jenkins-ansible-offline-*.tar.gz
cd Jenkins-Ansible
chmod +x setup.sh add-project.sh cleanup.sh
cp .env.example .env
nano .env                    # Optional: edit config
./setup.sh --offline
```

### Step 5: Verify

```bash
podman ps
journalctl --user -u jenkins-ansible -f
```

**Note:** If bundle was built on Oracle Linux, RPMs are OL-specific. To use on RHEL, rebuild the bundle on a RHEL machine:

```bash
# On RHEL build machine:
./setup.sh --build-offline-bundle
# Transfer the new bundle to RHEL target machine
```

---

## Managing Deployments Offline

### Add a Project

```bash
./add-project.sh \
  --name     myapp \
  --host     192.168.1.100 \
  --user     deployuser
```

This works completely offline — no internet needed.

### Start/Stop Jenkins

```bash
# Start
systemctl --user start jenkins-ansible

# Stop
systemctl --user stop jenkins-ansible

# Status
systemctl --user status jenkins-ansible

# View logs
journalctl --user -u jenkins-ansible -f
```

### Edit Playbooks

All playbooks are in `projects/<project>/playbooks/` — edit locally, they're live in the container.

```bash
# Example: edit deploy playbook
nano projects/myapp/playbooks/deploy.yml

# Trigger via Jenkins UI to test changes
```

### Run Deployments

**Via Jenkins UI:**
1. Open Jenkins: `http://localhost:8080`
2. Navigate to your project
3. Click "Build Now"
4. Monitor console output

**Via CLI:**
```bash
# Run Ansible directly (without Jenkins)
ansible-playbook -i projects/myapp/inventory/hosts.ini \
  projects/myapp/playbooks/deploy.yml \
  -u deployuser \
  --private-key ssh-keys/myapp.pem
```

### Update Ansible

Ansible is baked into the image at build time. To update Ansible:

**Option 1: Edit Dockerfile version**
```bash
# On build machine:
# Edit Dockerfile, line 78:
ARG ANSIBLE_VERSION="9.9.0"     # Change this

./setup.sh --build-offline-bundle
# Transfer new bundle to target
```

**Option 2: Install in container**
```bash
# On target machine, run in container:
podman exec -it jenkins-ansible pip3 install --upgrade ansible
```

---

## Troubleshooting

### Bundle Not Found

**Error:** `Offline bundle not found: jenkins-ansible-bundle.tar.gz`

**Solution:**
```bash
# Check file exists
ls -lh jenkins-ansible-offline-*.tar.gz

# If not there, rebuild on build machine:
./setup.sh --build-offline-bundle
```

### Jenkins Won't Start

**Check logs:**
```bash
journalctl --user -u jenkins-ansible -f
podman logs jenkins-ansible | tail -50
```

**Common causes:**
- Port 8080 already in use: `lsof -i :8080` → change port in .env
- Not enough RAM: Increase JENKINS_MEM in .env
- Disk full: `df -h` → free up space

**Solution:**
```bash
# Stop and restart
systemctl --user stop jenkins-ansible
rm -rf ~/.local/share/containers/storage/...  # Purge container
./setup.sh --offline
```

### Can't Connect to Target Host

**Error:** `SSH connection refused` or `No route to host`

**Verify SSH connectivity:**
```bash
ssh -i ssh-keys/myapp.pem deployuser@192.168.1.100 "echo OK"
```

**If fails:**
1. Check target host is online: `ping 192.168.1.100`
2. Verify SSH is running: `ssh -v ...` (see detailed errors)
3. Check firewall: `sudo firewall-cmd --list-ports`
4. Verify SSH key permissions: `chmod 600 ssh-keys/myapp.pem`

### Podman Image Not Loading

**Error:** `Error: image name is not fully qualified`

**Solution:**
```bash
# Load image manually
podman load < offline-bundle/image/jenkins-ansible-image.tar.gz

# Verify
podman images | grep jenkins-ansible
```

### Out of Disk Space

**Check usage:**
```bash
df -h
du -sh ~/.local/share/containers/storage/
du -sh ~/.local/share/containers/
```

**Cleanup:**
```bash
# Remove stopped containers
podman container prune -f

# Remove unused images
podman image prune -f

# Full cleanup (if needed)
./cleanup.sh --force
```

### Ansible Playbook Fails

**Check logs:**
```bash
# In Jenkins: Click build → View Console Output
# Or manually:
ansible-playbook -i projects/myapp/inventory/hosts.ini \
  projects/myapp/playbooks/deploy.yml -vvv
```

**Common issues:**
- SSH key permission: `chmod 600 ssh-keys/myapp.pem`
- Host not in known_hosts: Handled automatically
- Ansible syntax error: `ansible-playbook --syntax-check playbooks/deploy.yml`
- Target host unreachable: Check network/firewall

---

## Advanced Topics

### Custom Plugins

Add plugins to `jenkins-config/plugins.txt`, then rebuild:

```bash
# On build machine:
echo "my-plugin:1.0" >> jenkins-config/plugins.txt
./setup.sh --build-offline-bundle
```

### Multi-Target Deployments

Edit `inventory/hosts.ini` to add multiple targets:

```ini
[deploy_targets]
app01.internal ansible_user=deploy
app02.internal ansible_user=deploy
db01.internal ansible_user=deploy
```

Jenkins will deploy to all hosts in parallel.

### Backup Jenkins Data

Jenkins stores job history in `~/.local/share/containers/storage/...`

**Backup:**
```bash
podman volume inspect jenkins-ansible-home  # Find path
tar -czf jenkins-backup-$(date +%Y%m%d).tar.gz \
  ~/.local/share/containers/storage/volumes/jenkins-ansible-home
```

**Restore:**
```bash
tar -xzf jenkins-backup-YYYYMMDD.tar.gz -C ~/
```

### Kubernetes / Docker Swarm

The image can also run in Kubernetes or Docker Swarm. See `docker-compose.yml` for volume structure.

---

## Quick Reference

| Task | Command |
|------|---------|
| Build offline bundle | `./setup.sh --build-offline-bundle` |
| Deploy offline | `./setup.sh --offline` |
| Add project | `./add-project.sh --name myapp --host X.X.X.X --user user` |
| Start Jenkins | `systemctl --user start jenkins-ansible` |
| Stop Jenkins | `systemctl --user stop jenkins-ansible` |
| View logs | `journalctl --user -u jenkins-ansible -f` |
| Run playbook manually | `ansible-playbook -i projects/X/inventory -u user projects/X/playbooks/deploy.yml` |
| Clean up | `./cleanup.sh` |

---

## Support

**Issues or questions?**

1. Check logs: `journalctl --user -u jenkins-ansible`
2. Review Ansible output: Look at Jenkins build console
3. Test connectivity: `ansible all -i inventory/hosts.ini -m ping`

For security issues or production deployments, ensure:
- ✅ Change default Jenkins password
- ✅ Use SSH key authentication (not passwords)
- ✅ Restrict network access to Jenkins UI
- ✅ Regular backups of jenkins-ansible-home volume
- ✅ Use HTTPS reverse proxy in front of Jenkins
