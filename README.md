# Jenkins + Ansible Deployment Hub

A containerized Jenkins instance pre-configured with Ansible — your single deployment hub for all projects.

## What This Does

- **One Jenkins** manages deployments for **all your applications**
- Each application has its own **project folder** in Jenkins with deploy/rollback/healthcheck pipelines
- Ansible playbooks connect to target servers via SSH and perform deployments
- Works **completely offline** once set up (no internet needed at runtime)
- Runs on **macOS** (Docker Desktop), **RHEL 8/9**, and **Oracle Linux 8/9**

## Quick Start (macOS)

**Prerequisites:** Docker Desktop installed and running.

```bash
# 1. Clone / unpack this repository
cd Jenkins-Ansible

# 2. Copy and optionally edit configuration
cp .env.example .env
# Optional: change port (default 8080), password, etc.
# nano .env

# 3. Run setup (takes 10-15 minutes first time — downloads ~800MB)
chmod +x setup.sh add-project.sh
./setup.sh

# 4. Open Jenkins — port is set by JENKINS_PORT in .env (default: 8080)
open http://localhost:8080
# Username: admin   Password: changeme123  (change this in .env before setup!)

# 5. Add your first project
./add-project.sh --name myapp --host 192.168.1.100 --user deployuser
```

That's it. Jenkins will auto-discover your project and create the pipeline.

---

## Quick Start (RHEL / Oracle Linux)

```bash
chmod +x setup.sh add-project.sh

# Requires sudo for first-time Podman installation only
./setup.sh

# Opens at:
xdg-open http://localhost:8080
```

---

## 🔌 Offline Installation (Air-Gapped Environments)

For networks with no internet access, this project includes complete offline deployment tooling:

### Quick Path (3 steps, 2-3 hours total)

1. **Build Machine** (with internet, same OS/arch as target):
   ```bash
   ./build-offline-bundle.sh --output /tmp/
   # Creates: jenkins-ansible-offline-ol9-x86_64-YYYYMMDD-HHMMSS.tar.gz (~5GB)
   ```

2. **Transfer to Target** (via SCP, USB, or secure courier):
   ```bash
   scp jenkins-ansible-offline-*.tar.gz user@target:/tmp/
   ```

3. **Deploy on Target** (no internet needed):
   ```bash
   tar -xzf jenkins-ansible-offline-*.tar.gz
   cd offline-bundle-*/
   ../verify-offline-bundle.sh .
   # Then in Jenkins-Ansible directory:
   ./setup.sh --offline
   ```

### Documentation

| Document | Purpose |
|----------|---------|
| **[OFFLINE_BUNDLE_README.md](OFFLINE_BUNDLE_README.md)** | Quick reference (start here!) |
| **[docs/OFFLINE_BUNDLE_WORKFLOW.md](docs/OFFLINE_BUNDLE_WORKFLOW.md)** | Complete step-by-step guide (45 min read) |
| **[OFFLINE_BUNDLE_CHECKLIST.md](OFFLINE_BUNDLE_CHECKLIST.md)** | Verification checklist (print & use) |
| **[docs/OFFLINE_DEPLOYMENT.md](docs/OFFLINE_DEPLOYMENT.md)** | Architecture & troubleshooting |

### What the Bundle Includes

✅ **Jenkins LTS** (~2GB container image)
- All plugins pre-installed
- Configuration as Code (JCasC)
- Seed job for auto-discovery

✅ **Ansible 9.8.0** + Collections
- Pre-installed in container
- SSH connectivity
- All core modules

✅ **Podman Runtime** (~200MB RPMs)
- Container networking
- SELinux policies
- Rootless support

✅ **Python Wheels** (~60MB)
- Platform-specific (built for target OS/arch)
- All Ansible dependencies
- Ready for offline installation

### Key Points

⚠️ **OS/Arch Must Match:**
- Build on Oracle Linux 9 → Deploy on Oracle Linux 9
- Build on RHEL 8 → Deploy on RHEL 8
- Do NOT cross-build (OL→RHEL or version mismatches)

✅ **Fully Verified:**
- SHA256 checksums for all files
- Integrity check script included
- No internet needed at deployment time

✅ **Production Ready:**
- Pre-tested on Oracle Linux 8.x, 9.x
- Pre-tested on RHEL 8.x, 9.x
- All dependencies pre-baked (no surprises at runtime)

---

## Adding Projects

```bash
./add-project.sh \
  --name    myapp           \   # Project identifier (no spaces)
  --host    192.168.1.100   \   # Target server IP
  --user    deployuser      \   # SSH username on target
  --key     ./ssh-keys/myapp.pem  # SSH private key (optional — auto-generated if omitted)

# List all projects:
./add-project.sh --list
```

**What happens automatically:**
1. Project folder created in `./projects/myapp/`
2. SSH key registered in Jenkins credentials
3. Jenkins pipeline auto-created (via Seed Job)
4. Ready to deploy in ~30 seconds

---

## Project Structure

```
projects/
  _template/               ← Template for new projects (auto-copied by add-project.sh)
    project.yaml          ← Project metadata & configuration
    inventory/
      hosts.ini           ← Ansible inventory (target hosts)
    playbooks/
      deploy.yml          ← Deployment playbook
      rollback.yml        ← Rollback to previous version
      healthcheck.yml     ← Health check & verification

  myproject/               ← Your actual project (created by add-project.sh)
    project.yaml          ← Auto-generated from template
    inventory/hosts.ini   ← Your target host(s)
    playbooks/
      deploy.yml          ← Your deployment logic
      rollback.yml        ← Your rollback logic
      healthcheck.yml     ← Your health checks

ssh-keys/
  myproject.pem           ← SSH private key (auto-generated if needed)
  myproject.pem.pub       ← SSH public key

jenkins-config/
  plugins.txt             ← Pre-installed Jenkins plugins
  jenkins.yaml            ← Jenkins Configuration-as-Code (JCasC)
  seed-job.groovy         ← Auto-generate Jenkins jobs from projects/
  init.groovy.d/
    01-create-seed-job.groovy  ← Initialize seed job on startup
```

---

## Directory Layout

```
Jenkins-Ansible/
├── Dockerfile                  # Jenkins + Ansible image (multi-arch: amd64 + arm64)
├── docker-compose.yml          # Service definition (Docker)
├── .env.example                # Configuration template
├── setup.sh                    # ← START HERE: one-command setup
├── add-project.sh              # Add new deployment projects
├── build-offline-bundle.sh     # Prepare offline bundle
├── jenkins-config/
│   ├── jenkins.yaml            # Auto-configures Jenkins (JCasC)
│   ├── plugins.txt             # Pre-installed plugins
│   └── seed-job.groovy         # Auto-creates Jenkins pipelines from projects/
├── projects/                   # Your Ansible playbooks live here
│   ├── _template/              # Copy this to add new projects
│   ├── project1/               # Example project
│   └── project2/               # Example project
├── ssh-keys/                   # SSH private keys (never commit to git)
├── sudoers/
│   ├── setup-sudoers.template  # Minimal sudo for setup phase
│   └── runtime-sudoers.template# Minimal sudo for Ansible on target hosts
└── podman/
    ├── jenkins-ansible.container  # RHEL/OL systemd Quadlet
    └── jenkins_home.volume        # Persistent volume definition
```

---

## Jenkins Plugins Included

| Plugin | Purpose |
|--------|---------|
| `ansible` | Run Ansible playbooks from pipelines |
| `ssh-agent` + `ssh-credentials` | Manage SSH keys securely |
| `job-dsl` | Auto-create jobs from project folders |
| `pipeline-graph-view` | Modern pipeline visualization |
| `configuration-as-code` | Configure Jenkins via YAML (no UI clicking) |
| `folder` | Organize jobs per project |
| `ansicolor` | Colorized Ansible output |
| `dark-theme` | Modern dark UI |

---

## Sudo Requirements

### Setup Phase (one-time, 7 commands)
```
Install Podman + deps, configure user namespaces, enable lingering, load image
```
See: `sudoers/setup-sudoers.template`

### Runtime Phase
**Zero sudo needed** — Podman runs rootless as your user.

### Ansible on Target Hosts (Iteration 2)
Scoped per-project sudoers: see `sudoers/runtime-sudoers.template`

---

## Commands Reference

```bash
# Setup
./setup.sh                       # First-time setup
./setup.sh --offline             # Setup without internet
./setup.sh --build-offline-bundle # Create offline bundle

# Project management
./add-project.sh --list          # List all projects
./add-project.sh --name X --host Y --user Z  # Add project

# Jenkins (Docker)
docker compose up -d             # Start Jenkins
docker compose down              # Stop Jenkins
docker compose restart           # Restart Jenkins
docker logs -f jenkins-ansible   # View logs

# Jenkins (Podman / RHEL)
systemctl --user start jenkins-ansible
systemctl --user stop jenkins-ansible
systemctl --user status jenkins-ansible
journalctl --user -u jenkins-ansible -f
```

---

## Troubleshooting

| Problem | Solution |
|---------|---------|
| Jenkins not starting | `docker logs jenkins-ansible \| tail -50` |
| Can't connect to target host | Check SSH key is in Jenkins credentials; test with `ssh -i ssh-keys/x.pem user@host` |
| Plugin missing | Rebuild image: `docker compose build --no-cache` |
| Ansible playbook fails | Add `-vvv` verbosity in pipeline parameters for detailed output |
| Port 8080 in use | Edit `JENKINS_PORT` in `.env`, then `docker compose down && docker compose up -d` |

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Host Machine (Mac / RHEL / Oracle Linux)            │
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  Jenkins Container                             │  │
│  │                                                │  │
│  │  Jenkins UI ──► Seed Job ──► Project Folders  │  │
│  │                               ├─ project1/    │  │
│  │                               │  └─ Deploy    │  │
│  │                               └─ project2/    │  │
│  │                                  └─ Deploy    │  │
│  │  Ansible ──► SSH Keys ──► Playbooks           │  │
│  └──────────────────────────────────────────────┘  │
│            │ volumes                                │
│  ./projects/ (playbooks)                           │
│  ./ssh-keys/ (SSH keys)                            │
└──────────────────────────────────────────────────────┘
                    │ SSH
                    ▼
        ┌─────────────────────┐
        │  Target Hosts       │
        │  App 1 / App 2 / …  │
        └─────────────────────┘
```

---

## Security Notes

- SSH private keys in `./ssh-keys/` are mounted **read-only** into the container
- Never commit `.env` or `*.pem` files to git (`.gitignore` excludes them)
- Change the default admin password immediately after first login
- For production: set `JENKINS_URL` to your actual hostname in `.env`
