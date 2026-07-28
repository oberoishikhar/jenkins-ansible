# Offline Bundle — Quick Start

**Build and deploy Jenkins-Ansible to air-gapped environments with no internet access.**

---

## Quick Summary

| Phase | Machine | Task | Time | Internet |
|-------|---------|------|------|----------|
| **1. Build** | Build PC (OL/RHEL) | `./build-offline-bundle.sh` | 45-90 min | ✅ Required |
| **2. Transfer** | Both | Via SCP/USB | 5-30 min | ❌ No |
| **3. Deploy** | Target (OL/RHEL) | `./setup.sh --offline` | 5-10 min | ❌ No |

---

## Build Machine Setup (5 minutes)

**Prerequisites:**
- Oracle Linux 8.x or 9.x (or RHEL 8.x or 9.x)
- **Same OS/arch as target machine** ⚠️
- Internet access
- 20GB free disk space
- Docker or Podman installed and running **before** starting the build
  (this script does NOT install a runtime for you — install it first):
  ```bash
  sudo dnf install -y podman slirp4netns fuse-overlayfs
  podman --version
  ```

**Run:**
```bash
cd Jenkins-Ansible
./build-offline-bundle.sh --output /tmp/

# Outputs: jenkins-ansible-offline-ol9-x86_64-YYYYMMDD-HHMMSS.tar.gz (~5GB)
```

---

## Transfer to Target (5-30 minutes)

**Via SCP:**
```bash
scp jenkins-ansible-offline-ol9-*.tar.gz admin@target-machine:/tmp/
```

**Via USB:**
```bash
# Mount USB, copy file, physically transport to target
```

---

## Deploy on Target Machine (10 minutes)

**Prerequisites:**
- Oracle Linux 8.x or 9.x (or RHEL 8.x or 9.x)
- Same OS/version/arch as build machine
- 10GB free disk space
- NO internet needed

**Run:**
```bash
cd /tmp
tar -xzf jenkins-ansible-offline-ol9-*.tar.gz
cd offline-bundle-*/

# Verify integrity
../verify-offline-bundle.sh .

# Deploy
cd ../.. && tar -xzf jenkins-ansible-source.tar.gz
cd Jenkins-Ansible
./setup.sh --offline

# Jenkins is ready at: http://localhost:8080
# Login: admin / changeme123 (CHANGE THIS!)
```

---

## Files in This Bundle

| Component | Size | Purpose |
|-----------|------|---------|
| `images/jenkins-ansible-*.tar.gz` | ~2.0GB | Pre-built Docker image (Jenkins + Ansible + plugins) |
| `rpms/podman/` | ~200MB | Podman runtime + dependencies |
| `wheels/` | ~60MB | Python packages (Ansible, paramiko, etc.) |
| `MANIFEST.md` | — | Detailed deployment guide |
| `CHECKSUMS.sha256` | — | Verify bundle integrity |
| `scripts/setup.sh` | — | Main deployment script |

---

## Common Tasks

### ✅ Verify Bundle (Target Machine)
```bash
cd offline-bundle-*/
../verify-offline-bundle.sh .
```

### ✅ Check What's Installed
```bash
podman images
systemctl --user status jenkins-ansible
curl http://localhost:8080/login
```

### ✅ View Logs
```bash
journalctl --user -u jenkins-ansible -f
```

### ✅ Add First Project
```bash
cd Jenkins-Ansible
./add-project.sh --name myapp --host 192.168.1.100 --user deployer
```

### ✅ Change Jenkins Password
1. Open: http://localhost:8080
2. Click username (top right) → Configure
3. Set new password → Save

### ✅ Stop/Start Jenkins
```bash
systemctl --user stop jenkins-ansible   # Stop
systemctl --user start jenkins-ansible  # Start
systemctl --user restart jenkins-ansible # Restart
```

---

## Troubleshooting

### ❌ "OS mismatch" or "Architecture mismatch"

**Problem:** Built on OL8 but deploying on OL9, or x86_64→aarch64

**Solution:** Rebuild bundle on same OS/arch as target

### ❌ "RPM Installation fails"

**Problem:** dnf install can't find packages

**Solution:**
```bash
cd offline-bundle/rpms/podman
createrepo .
sudo dnf install -y --repofrompath=local,. *.rpm
```

### ❌ "Jenkins won't start"

**Problem:** Container not running

**Solution:**
```bash
# Check if image loaded
podman images | grep jenkins

# If not, manually load:
podman load < offline-bundle/images/jenkins-ansible-*.tar.gz

# Restart
systemctl --user restart jenkins-ansible
```

### ❌ "Can't connect to http://localhost:8080"

**Problem:** Port 8080 in use or firewall blocking

**Solution:**
```bash
# Check if listening
netstat -tlnp | grep 8080

# Allow through firewall
sudo firewall-cmd --add-port=8080/tcp --permanent
sudo firewall-cmd --reload

# If port in use, change in .env: JENKINS_PORT=9080
```

---

## Important Notes

⚠️ **OS Must Match:**
- Build: Oracle Linux 9 → Target: Oracle Linux 9
- Build: RHEL 8 → Target: RHEL 8
- Do NOT cross-build (OL→RHEL or 8→9)

⚠️ **Architecture Must Match:**
- Build: x86_64 → Target: x86_64
- Build: aarch64 → Target: aarch64
- Do NOT build on different arch

⚠️ **Default Password:**
- Change from `changeme123` immediately
- Use SSH keys (not passwords) for deployments

⚠️ **Disk Space:**
- Need 10GB+ for Jenkins data/builds
- Check: `df -h`

⚠️ **Offline Verification:**
- Every file checksummed for integrity
- Run: `./verify-offline-bundle.sh` before deploying

---

## What This Bundle Includes

✅ **Jenkins LTS** with plugins:
- Job DSL (for seed job)
- Git integration
- Ansible plugin
- Pipeline support
- Email notifications

✅ **Ansible 9.8.0** with:
- Core collections
- SSH connectivity
- Paramiko for SSH
- Jinja2 templating
- YAML support

✅ **Podman Runtime** with:
- Container networking
- SELinux support
- Systemd integration
- Rootless container support

✅ **Project Templates** for:
- Deployment automation
- Health checks
- Rollback playbooks
- Multi-target deployments

---

## Next Steps

1. **Deploy:** See "Deploy on Target Machine" section above
2. **Configure:** Update `.env` with site-specific settings
3. **Add Projects:** Use `./add-project.sh` for each deployment target
4. **Secure:** Change default credentials, use SSH keys
5. **Backup:** Schedule regular `jenkins-ansible-home` backups

---

## Full Documentation

For comprehensive guide, see:
- **[OFFLINE_BUNDLE_WORKFLOW.md](docs/OFFLINE_BUNDLE_WORKFLOW.md)** — Complete step-by-step guide
- **[OFFLINE_DEPLOYMENT.md](docs/OFFLINE_DEPLOYMENT.md)** — Detailed architecture & troubleshooting
- **[MANIFEST.md](offline-bundle-*/MANIFEST.md)** — This bundle's specific contents

---

## Support

**Verification Script:**
```bash
./verify-offline-bundle.sh .  # Checks integrity & readiness
```

**Build Logs:**
```bash
tail -100 offline_build.log
```

**Deployment Logs:**
```bash
journalctl --user -u jenkins-ansible | tail -50
```

---

**Built:** See MANIFEST.md for build date and system info
**Bundle ID:** See directory name (offline-bundle-20260726-143022)
