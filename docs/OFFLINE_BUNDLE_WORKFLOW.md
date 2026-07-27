# Offline Bundle Workflow — Complete Guide

This document describes the complete process for building, transferring, and deploying Jenkins-Ansible to air-gapped environments.

---

## Overview

```
┌──────────────────────────┐
│  Build Machine           │
│  (Internet access)       │
│  Oracle Linux / RHEL     │
│                          │
│ 1. build-offline-bundle  │
│ 2. Transfer via USB/SCP  │
│ 3. ~5GB bundle file      │
└─────────────┬────────────┘
              │
              │ Transfer via:
              │ • SCP/SSH
              │ • USB drive
              │ • Secure courier
              │
┌─────────────▼────────────┐
│  Target Machine          │
│  (NO internet)           │
│  Oracle Linux / RHEL     │
│                          │
│ 1. Extract bundle        │
│ 2. verify-offline-bundle │
│ 3. setup.sh --offline    │
└──────────────────────────┘
```

---

## Phase 1: Prepare Build Machine

### Prerequisites

**Build Machine Requirements:**
- Oracle Linux 8.x or 9.x (or RHEL 8.x or 9.x)
- **MUST match target OS** (OL8→OL8, OL9→OL9, RHEL8→RHEL8, etc.)
- **MUST match target architecture** (x86_64 or aarch64)
- Internet connectivity (to download packages)
- ~20 GB free disk space (for build artifacts)
- Docker or Podman installed and running
- `dnf` package manager (for RPM downloads)

### Step 1: Clone the Project

```bash
git clone <jenkins-ansible-repo> Jenkins-Ansible
cd Jenkins-Ansible
```

### Step 2: Build the Offline Bundle

**Critical:** This script MUST run on the same OS/arch as your target machine.

```bash
# Make sure we're on the correct OS
grep '^ID=' /etc/os-release          # Should show: ol or rhel
grep '^VERSION_ID=' /etc/os-release  # Should show: 8.x or 9.x
uname -m                             # Should show: x86_64 or aarch64

# Run the builder
./build-offline-bundle.sh --output /tmp/offline-bundles
```

**What this does:**
1. ✅ Validates OS/architecture match
2. ✅ Builds Jenkins-Ansible Docker image
3. ✅ Downloads Podman RPMs and dependencies (matching target OS exactly)
4. ✅ Downloads Python wheels (platform-specific for Linux)
5. ✅ Generates checksums for integrity verification
6. ✅ Creates a manifest with deployment instructions

**Duration:** 45-90 minutes (first time, due to plugin/dependency downloads)

**Output:**
```
✓ Offline Bundle Created Successfully
  Bundle:  /tmp/offline-bundles/jenkins-ansible-offline-ol9-x86_64-20260726-143022.tar.gz
  Size:    5.2G
  Details: See offline-bundle-*/MANIFEST.md
```

### Step 3: Verify Bundle on Build Machine

```bash
# Verify the bundle was created correctly
cd /tmp/offline-bundles
tar -tzf jenkins-ansible-offline-ol9-x86_64-*.tar.gz | head -20

# Check contents
mkdir -p test-extract
tar -xzf jenkins-ansible-offline-ol9-x86_64-*.tar.gz -C test-extract
ls -lh test-extract/offline-bundle-*/

# Expected structure:
# ├── images/          (Docker image tar.gz, ~2GB)
# ├── rpms/            (Podman + dependencies, ~200MB)
# ├── wheels/          (Python packages, ~60MB)
# ├── scripts/         (setup.sh, add-project.sh)
# ├── MANIFEST.md      (Deployment guide)
# ├── CHECKSUMS.sha256 (For verification)
# └── ...
```

---

## Phase 2: Transfer Bundle to Target Machine

### Option A: SCP (Secure, Over Network)

```bash
# From build machine:
scp jenkins-ansible-offline-ol9-x86_64-*.tar.gz \
  admin@target-machine:/home/admin/

# Verify transfer
ssh admin@target-machine 'ls -lh jenkins-ansible-offline-ol9-x86_64-*.tar.gz'
```

### Option B: USB Drive (Air-Gapped / Physically Isolated)

```bash
# From build machine (prepare USB)
sudo mount /dev/sdX1 /mnt/usb
cp jenkins-ansible-offline-ol9-x86_64-*.tar.gz /mnt/usb/
sudo umount /mnt/usb

# Physical transport to offline machine
# On target machine (plug in USB)
mkdir -p ~/offline-bundle-tmp
cp /media/usb/jenkins-ansible-offline-ol9-x86_64-*.tar.gz ~/
```

### Option C: Direct SSH (if network available to target)

```bash
# On target machine:
mkdir -p ~/jenkins-ansible
cd ~/jenkins-ansible

# Wait for file transfer
# Then verify:
ls -lh jenkins-ansible-offline-ol9-x86_64-*.tar.gz
```

---

## Phase 3: Deploy on Target Machine

### Step 1: Extract Bundle

```bash
# Navigate to transfer location
cd ~/jenkins-ansible  # or wherever file was transferred

# Extract
tar -xzf jenkins-ansible-offline-ol9-x86_64-*.tar.gz

# Enter extracted directory
cd offline-bundle-*/
ls -la
```

### Step 2: Verify Bundle Integrity

```bash
# Run verification script
../verify-offline-bundle.sh .

# Expected output:
# ✓ Bundle Verification PASSED
# Status: Ready for deployment
```

**If verification fails:**
- Check disk space: `df -h /`
- Verify OS/arch: `grep '^ID=' /etc/os-release`, `uname -m`
- Check checksums: `sha256sum -c CHECKSUMS.sha256`

### Step 3: Prepare Deployment

```bash
# Extract the Jenkins-Ansible project
tar -xzf jenkins-ansible-source.tar.gz
cd Jenkins-Ansible

# Copy bundle into project
cp -r ../offline-bundle-*/* .

# Verify structure
ls -la jenkins-ansible-bundle.tar.gz
ls -la offline-bundle/
```

### Step 4: Configure Jenkins (Optional)

```bash
# Copy configuration template
cp .env.example .env

# Edit if needed (port, admin password, etc.)
nano .env
```

**Key settings:**
```bash
JENKINS_PORT=8080              # Change if port is in use
JENKINS_ADMIN_USER=admin       # CHANGE THIS in production
JENKINS_ADMIN_PASSWORD=changeme123  # CHANGE THIS!
```

### Step 5: Run Offline Setup

```bash
# Make scripts executable
chmod +x setup.sh add-project.sh cleanup.sh

# Run offline deployment
# If Podman is not installed, you'll be prompted for sudo password (one time only)
./setup.sh --offline
```

**What this does:**
1. ✅ Detects if Podman is installed
2. ✅ If not, installs Podman from offline RPMs (requires sudo)
3. ✅ Loads Jenkins image from offline bundle
4. ✅ Starts Jenkins via systemd
5. ✅ Waits for Jenkins to become ready
6. ✅ Triggers seed job (discovers projects)

**Duration:** 5-10 minutes

**Expected Output:**
```
🎉 Jenkins + Ansible Hub is UP and RUNNING!

Jenkins URL:  http://localhost:8080
Username:     admin
Password:     changeme123

⚠️ First time? Change the default password!
```

### Step 6: Access Jenkins

```bash
# Local access (on target machine)
curl http://localhost:8080/login

# Remote access (from workstation)
ssh -L 8080:localhost:8080 user@target-machine

# Then open browser: http://localhost:8080
```

---

## Troubleshooting

### Bundle Extraction Fails

```bash
# Check if tar is corrupted
file jenkins-ansible-offline-*.tar.gz  # Should show: gzip

# Try verbose extraction
tar -xzvf jenkins-ansible-offline-*.tar.gz 2>&1 | tail -20

# If corrupted, re-transfer the bundle
```

### RPM Installation Fails

```bash
# Check what's available
ls -la offline-bundle/rpms/podman/

# Try manual installation
cd offline-bundle/rpms/podman
sudo dnf install -y *.rpm

# If that fails, create local repo:
createrepo .
sudo dnf install -y --repofrompath=local,. podman slirp4netns fuse-overlayfs
```

### Jenkins Won't Start

```bash
# Check logs
journalctl --user -u jenkins-ansible -f

# Check if Podman loaded the image
podman images | grep jenkins-ansible

# If not loaded, manually load:
podman load < offline-bundle/images/jenkins-ansible-*.tar.gz
podman images

# Try restarting
systemctl --user restart jenkins-ansible
```

### Out of Disk Space

```bash
# Check usage
df -h /
du -sh ~/

# Clean up old bundles
rm -rf offline-bundle-*/
rm -f jenkins-ansible-offline-*.tar.gz

# Or move extracted bundle elsewhere
mv offline-bundle-*/ /var/lib/jenkins-ansible-offline/
```

### Can't Connect to Jenkins

```bash
# Verify it's listening
netstat -tlnp | grep 8080
ss -tlnp | grep 8080

# Check firewall
sudo firewall-cmd --list-ports
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --reload

# Test connectivity
curl -v http://localhost:8080/login
```

---

## Advanced Usage

### Add Projects in Offline Mode

```bash
# Create project configuration
./add-project.sh \
  --name myapp \
  --host 192.168.1.50 \
  --user deployuser
```

**Note:** This works completely offline — no internet needed. Deploy keys are managed locally in `ssh-keys/` directory.

### Update Ansible Version

Edit `Dockerfile` and rebuild on build machine:

```bash
# On build machine:
sed -i 's/ARG ANSIBLE_VERSION=.*/ARG ANSIBLE_VERSION="2.16.0"/' Dockerfile

# Rebuild bundle
./build-offline-bundle.sh --output /tmp/

# Transfer new bundle to target
```

### Monitor Deployments

```bash
# Watch Jenkins logs
journalctl --user -u jenkins-ansible -f

# View container logs
podman logs -f jenkins-ansible

# Check build history
curl -s http://localhost:8080/job/myapp/api/json | jq '.builds'
```

---

## Security Best Practices

1. **Change Default Password**
   ```bash
   # Immediately after first login:
   # Jenkins → admin (top right) → Configure → Set new password
   ```

2. **Use SSH Keys (Not Passwords)**
   ```bash
   # Generate key for each project
   ssh-keygen -t ed25519 -C "jenkins-myapp" -f ssh-keys/myapp.pem
   chmod 600 ssh-keys/myapp.pem
   
   # Copy public key to target hosts
   ssh-copy-id -i ssh-keys/myapp.pem deployuser@target-host
   ```

3. **Restrict Network Access**
   ```bash
   # If not deploying internally, use SSH tunnel
   ssh -L 8080:localhost:8080 user@target-machine
   
   # Or setup reverse proxy with auth (nginx, HAProxy)
   ```

4. **Backup Jenkins Data**
   ```bash
   # Regular backups
   tar -czf jenkins-backup-$(date +%Y%m%d).tar.gz \
     ~/.local/share/containers/storage/volumes/jenkins-ansible-home/_data/
   ```

---

## Testing Offline Operation

### Simulate Air-Gap (Optional)

```bash
# Block network traffic
sudo iptables -A OUTPUT -d 0.0.0.0/0 -j DROP

# Verify Jenkins still works
curl http://localhost:8080/login

# Re-enable network
sudo iptables -F
```

### Run Health Checks

```bash
# Test Ansible connectivity
ansible-playbook -i projects/myapp/inventory/hosts.ini \
  -m ping projects/myapp/playbooks/healthcheck.yml

# Test Jenkins API
curl -s http://localhost:8080/api/json | jq '.version'
```

---

## Reference: Bundle Structure

After extraction, the bundle contains:

```
offline-bundle-20260726-143022/
├── images/
│   └── jenkins-ansible-x86_64.tar.gz  (~2.0 GB)
│       Pre-built Docker image with:
│       • Jenkins LTS with all plugins pre-installed
│       • Ansible 9.8.0
│       • All tools (git, rsync, ssh, curl, etc.)
│
├── rpms/
│   ├── podman/
│   │   ├── podman-*.rpm              (~30 MB, ~15 files)
│   │   ├── slirp4netns-*.rpm
│   │   ├── fuse-overlayfs-*.rpm
│   │   ├── container-selinux-*.rpm
│   │   └── [other dependencies]
│   │
│   └── RPMS.txt                       (Index of all RPMs)
│
├── wheels/
│   ├── ansible-*.whl                  (~50 MB)
│   ├── paramiko-*.whl
│   ├── jinja2-*.whl
│   ├── PyYAML-*.whl
│   └── [dependencies]
│
├── scripts/
│   ├── setup.sh                       (Main deployment script)
│   └── add-project.sh                 (Project creation script)
│
├── MANIFEST.md                        (Deployment guide)
├── CHECKSUMS.sha256                   (Integrity verification)
└── jenkins-ansible-source.tar.gz      (Full project source)
```

---

## FAQ

**Q: Can I use a bundle built on OL8 for OL9?**
A: No. RPMs and wheels are OS-version specific. Build separately for each target.

**Q: Can I use a bundle built on x86_64 for aarch64?**
A: No. Wheels and binaries are architecture-specific. Build on the target architecture.

**Q: How often do I need to rebuild?**
A: Only when:
- Updating to a new Jenkins version
- Upgrading Ansible
- Adding/removing plugins
- Changing to a different target OS/arch

**Q: Can I deploy multiple projects from one bundle?**
A: Yes. Use `./add-project.sh` multiple times to create projects. All use the same Jenkins instance.

**Q: What if target machine has internet later?**
A: Jenkins continues to work. You can optionally enable auto-updates, but it's not required.

**Q: How do I update Jenkins plugins offline?**
A: Edit `jenkins-config/plugins.txt`, rebuild the bundle, and redeploy to the target.

---

## Support

**Issues:**
1. Check build logs: `tail -100 offline_build.log`
2. Check deployment logs: `journalctl --user -u jenkins-ansible`
3. Review MANIFEST.md in the bundle
4. Consult OFFLINE_DEPLOYMENT.md for additional troubleshooting

**For Complex Issues:**
- Capture full logs: `journalctl --user -u jenkins-ansible > jenkins.log`
- Run verification: `./verify-offline-bundle.sh > verification.log`
- Check disk space: `df -h; du -sh ~/`

---

*Last updated: 2026-07-26*
*For latest version, see: docs/OFFLINE_BUNDLE_WORKFLOW.md*
