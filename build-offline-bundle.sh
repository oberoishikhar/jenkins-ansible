#!/usr/bin/env bash
# =============================================================================
# build-offline-bundle.sh
# =============================================================================
# Enhanced offline bundle builder for air-gapped Jenkins-Ansible deployments
#
# This script MUST be run on the TARGET OS (Oracle Linux or RHEL) to ensure
# all RPMs and Python wheels are compatible with the deployment target.
#
# USAGE:
#   ./build-offline-bundle.sh [--output DIR] [--skip-image] [--skip-rpms]
#
# REQUIREMENTS:
#   - Oracle Linux 8+ or RHEL 8+ (build must match target OS)
#   - Internet access (one-time only, on build machine)
#   - ~15GB free disk space
#   - Docker/Podman installed and running
#
# =============================================================================

set -eo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="."
SKIP_IMAGE=false
SKIP_RPMS=false
SKIP_WHEELS=false
SKIP_INTERNET_CHECK=false

# Parse arguments EARLY before using variables
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)              OUTPUT_DIR="$2"; shift 2;;
        --skip-image)          SKIP_IMAGE=true; shift;;
        --skip-rpms)           SKIP_RPMS=true; shift;;
        --skip-wheels)         SKIP_WHEELS=true; shift;;
        --skip-internet-check) SKIP_INTERNET_CHECK=true; shift;;
        --help)                echo "Usage: $0 [--output DIR] [--skip-image] [--skip-rpms] [--skip-wheels] [--skip-internet-check]"; exit 0;;
        *)                     echo "Unknown option: $1"; exit 1;;
    esac
done

# Detect OS/platform info
OS_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | cut -d. -f1)
ARCH=$(uname -m)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Build configuration
IMAGE_NAME="jenkins-ansible"
IMAGE_TAG="latest"
BUNDLE_DIR="${OUTPUT_DIR}/offline-bundle-${TIMESTAMP}"
MANIFEST_FILE="${BUNDLE_DIR}/MANIFEST.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Logging Functions ───────────────────────────────────────────────────────
log()       { echo -e "${BLUE}➜${NC} $*"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
log_error() { echo -e "${RED}✗${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}$*${NC}"; echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# ─── Error Handling ──────────────────────────────────────────────────────────
# Only trap critical errors; allow non-critical steps to continue with warnings
handle_error() {
    local line=$1
    log_error "Error at line $line"
    # Don't exit immediately - let optional steps fail gracefully
}
trap 'handle_error $LINENO' ERR

# =============================================================================
# VALIDATION
# =============================================================================

validate_build_environment() {
    log_step "Validating Build Environment"

    # Check for required build files (Dockerfile needs these for COPY commands)
    log "Checking required build files..."
    local missing_files=0

    local required_files=(
        "Dockerfile:Docker container definition"
        "docker-compose.yml:Docker compose configuration"
        "jenkins-config/jenkins.yaml:Jenkins configuration"
        "jenkins-config/plugins.txt:Jenkins plugins list"
        "jenkins-config/seed-job.groovy:Jenkins seed job"
        "jenkins-config/init.groovy.d:Jenkins initialization scripts"
        "setup.sh:Deployment setup script"
        "add-project.sh:Project management script"
        ".env.example:Environment template"
        "podman/jenkins-ansible.container:Systemd service definition"
        "podman/jenkins_home.volume:Volume definition"
    )

    for file_spec in "${required_files[@]}"; do
        local file="${file_spec%:*}"
        local desc="${file_spec#*:}"

        if [ -e "${SCRIPT_DIR}/${file}" ]; then
            log_ok "$desc"
        else
            log_error "Missing: $desc (${file})"
            ((missing_files++))
        fi
    done

    if [ $missing_files -gt 0 ]; then
        log_error "Build aborted: $missing_files required file(s) missing"
        log_error ""
        log_error "Required directory structure:"
        log_error "  Jenkins-Ansible/"
        log_error "  ├── Dockerfile"
        log_error "  ├── docker-compose.yml"
        log_error "  ├── setup.sh"
        log_error "  ├── add-project.sh"
        log_error "  ├── .env.example"
        log_error "  ├── jenkins-config/"
        log_error "  │   ├── jenkins.yaml"
        log_error "  │   ├── plugins.txt"
        log_error "  │   ├── seed-job.groovy"
        log_error "  │   └── init.groovy.d/"
        log_error "  └── podman/"
        log_error "      ├── jenkins-ansible.container"
        log_error "      └── jenkins_home.volume"
        exit 1
    fi
    log_ok "All required build files present"
}

validate_system() {
    log_step "Validating Build System"

    # Check OS
    if [[ "$OS_ID" != "ol" && "$OS_ID" != "rhel" ]]; then
        log_error "This script MUST run on Oracle Linux or RHEL (detected: ${OS_ID})"
        log_error "Reason: RPMs and wheels must match the target platform exactly"
        exit 1
    fi
    log_ok "Operating System: ${OS_ID} ${OS_VERSION} (${ARCH})"

    # Check internet (more lenient - try multiple sources)
    log "Checking internet connectivity..."
    local internet_ok=false

    # Try Docker registry first
    if curl -fsS --max-time 10 "https://registry-1.docker.io/v2/" &>/dev/null; then
        log_ok "Internet: Docker registry reachable"
        internet_ok=true
    # Try Google DNS
    elif curl -fsS --max-time 10 "https://www.google.com" &>/dev/null; then
        log_ok "Internet: Google reachable (Docker registry may be slow)"
        internet_ok=true
    # Try basic ping
    elif ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log_warn "Internet: ICMP works, but HTTPS may be restricted"
        internet_ok=true
    fi

    if [ "$internet_ok" = false ]; then
        if [ "$SKIP_INTERNET_CHECK" = true ]; then
            log_warn "Internet check failed, but --skip-internet-check was specified — proceeding anyway"
        else
            log_error "No internet access detected"
            log_error ""
            log_error "Troubleshooting:"
            log_error "  1. Test connectivity: curl -v https://www.google.com"
            log_error "  2. Check DNS: nslookup google.com"
            log_error "  3. Check proxy: echo \$HTTPS_PROXY"
            log_error "  4. Check firewall: ping -c 1 8.8.8.8"
            log_error ""
            log_error "Or bypass check with: ./build-offline-bundle.sh --skip-internet-check"
            exit 1
        fi
    fi

    # Check container runtime (Docker or Podman) — required, not auto-installed by this script
    if command -v docker &>/dev/null; then
        log_ok "Container runtime: docker ($(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ','))"
    elif command -v podman &>/dev/null; then
        log_ok "Container runtime: podman ($(podman --version 2>/dev/null | awk '{print $3}'))"

        # Rootless Podman needs subuid/subgid ranges, otherwise image pulls/builds
        # fail with "insufficient UIDs or GIDs available in user namespace"
        local current_user
        current_user=$(whoami)
        if [ "$current_user" != "root" ]; then
            if grep -q "^${current_user}:" /etc/subuid 2>/dev/null && \
               grep -q "^${current_user}:" /etc/subgid 2>/dev/null; then
                log_ok "Rootless user namespaces: configured for ${current_user}"
            else
                log_warn "No /etc/subuid or /etc/subgid entry for ${current_user}"
                log_warn "Configuring rootless user namespaces (requires sudo)..."
                if sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$current_user"; then
                    podman system migrate 2>/dev/null || true
                    log_ok "User namespace mapping: configured"
                else
                    log_error "Could not configure user namespaces for rootless Podman"
                    log_error "Run manually: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${current_user}"
                    log_error "Then: podman system migrate"
                    exit 1
                fi
            fi
        fi
    else
        log_error "No container runtime found (docker or podman required)"
        log_error ""
        log_error "This script does NOT install a container runtime automatically."
        log_error "Install Podman before running this script:"
        log_error "  sudo dnf install -y podman slirp4netns fuse-overlayfs"
        log_error "Or Docker, per your organization's standard install method."
        exit 1
    fi

    # Check other required commands
    for cmd in dnf tar gzip; do
        if command -v "$cmd" &>/dev/null; then
            log_ok "Command: $cmd"
        else
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done


    # Check disk space
    local avail_gb
    avail_gb=$(df -BG "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | sed 's/G//')
    if [ "${avail_gb}" -lt 15 ]; then
        log_error "Insufficient disk space: ${avail_gb}GB available, need 15GB"
        exit 1
    fi
    log_ok "Disk Space: ${avail_gb}GB available (need 15GB)"
}

# =============================================================================
# BUILD DIRECTORIES
# =============================================================================

setup_directories() {
    log_step "Setting Up Bundle Directories"

    mkdir -p "${BUNDLE_DIR}"/{rpms,images,wheels,docs,scripts}
    log_ok "Created: ${BUNDLE_DIR}"

    mkdir -p "${BUNDLE_DIR}/rpms"/{podman,dependencies}
    log_ok "Prepared: RPM staging directories"
}

# =============================================================================
# BUILD CONTAINER IMAGE
# =============================================================================

build_image() {
    if [ "$SKIP_IMAGE" = true ]; then
        log_warn "Skipping image build (--skip-image)"
        return
    fi

    log_step "Building Jenkins-Ansible Container Image"
    log "This takes 5-15 minutes (downloads all plugins, Ansible, etc.)"

    # Verify build requirements exist in SCRIPT_DIR (needed for Dockerfile COPY commands)
    log "Verifying build context..."
    if [ ! -d "${SCRIPT_DIR}/jenkins-config" ]; then
        log_error "jenkins-config directory not found in ${SCRIPT_DIR}"
        log_error "The Dockerfile requires: jenkins-config/plugins.txt, jenkins.yaml, seed-job.groovy"
        exit 1
    fi
    log_ok "Build context verified"

    # Detect runtime
    local runtime="docker"
    if ! command -v docker &>/dev/null; then
        runtime="podman"
    fi

    log "Using runtime: ${runtime}"
    log "Building for: linux/${ARCH}"

    local build_log="${BUNDLE_DIR}/image_build.log"
    log "Streaming build output live (full log: ${build_log})"
    echo ""

    if $runtime build \
        --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
        --progress=plain \
        "${SCRIPT_DIR}" 2>&1 | tee "${build_log}"; then
        echo ""
        log_ok "Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        echo ""
        log_error "Image build failed — see ${build_log} for full details"
        exit 1
    fi

    # Save image to tar
    local image_tar="${BUNDLE_DIR}/images/jenkins-ansible-${ARCH}.tar.gz"
    log "Saving image to: ${image_tar}"

    $runtime save "${IMAGE_NAME}:${IMAGE_TAG}" | gzip > "${image_tar}"
    local image_size
    image_size=$(du -sh "${image_tar}" | cut -f1)
    log_ok "Image saved: ${image_size}"
}

# =============================================================================
# DOWNLOAD RPMS FOR PODMAN AND DEPENDENCIES
# =============================================================================

download_rpms() {
    if [ "$SKIP_RPMS" = true ]; then
        log_warn "Skipping RPM download (--skip-rpms)"
        return
    fi

    log_step "Downloading RPMs for Podman and Dependencies"
    log "Target: ${OS_ID} ${OS_VERSION} (${ARCH})"

    # List of RPMs needed for containerized Jenkins-Ansible
    local rpms=(
        "podman"
        "podman-catatonit"
        "podman-gvproxy"
        "podman-remote"
        "podman-tests"
        "podman-docker"
        "containers-common"
        "container-selinux"
        "slirp4netns"
        "fuse-overlayfs"
        "catatonit"
        "conmon"
    )

    log "Downloading RPMs and dependencies..."
    for rpm in "${rpms[@]}"; do
        log "  • ${rpm}..."
        dnf download \
            --resolve \
            --destdir="${BUNDLE_DIR}/rpms/podman" \
            --multi-lib \
            "$rpm" 2>/dev/null || \
            log_warn "    Could not download $rpm (may not be available)"
    done

    # Count RPMs
    local rpm_count
    rpm_count=$(find "${BUNDLE_DIR}/rpms" -name "*.rpm" | wc -l)
    log_ok "Downloaded ${rpm_count} RPM files"

    # Create RPM index
    cat > "${BUNDLE_DIR}/rpms/RPMS.txt" <<EOF
# Podman and Container Runtime RPMs
# Downloaded: $(date)
# OS: ${OS_ID} ${OS_VERSION}
# Arch: ${ARCH}
#
# To install on target machine:
#   sudo dnf install -y *.rpm
#
# Or with local repo:
#   dnf install -y --repofrompath=local,. 'podman*' 'container*' 'slirp4netns' 'fuse-overlayfs'

$(find "${BUNDLE_DIR}/rpms" -name "*.rpm" -printf '%f\n' | sort)
EOF
    log_ok "Created RPM index: rpms/RPMS.txt"
}

# =============================================================================
# DOWNLOAD PYTHON WHEELS
# =============================================================================

download_wheels() {
    if [ "$SKIP_WHEELS" = true ]; then
        log_warn "Skipping wheel download (--skip-wheels)"
        return
    fi

    log_step "Downloading Python Packages (Wheels)"
    log "Wheels will be ${ARCH}-specific (Linux compatible)"

    # Install pip3 if not available
    if ! command -v pip3 &>/dev/null; then
        log "Installing python3-pip..."
        if command -v dnf &>/dev/null; then
            sudo dnf install -y python3-pip 2>/dev/null || {
                log_warn "Could not install pip3 via dnf - proceeding without wheels"
                log_warn "Wheels can be downloaded manually or skipped with --skip-wheels"
                return
            }
        else
            log_warn "pip3 not found and unable to install - proceeding without wheels"
            log_warn "Wheels can be downloaded manually or skipped with --skip-wheels"
            return
        fi
    fi

    # Packages needed
    local packages=(
        "ansible==9.8.0"
        "paramiko"
        "jinja2"
        "PyYAML"
        "netaddr"
    )

    log "Downloading wheels..."
    if pip3 download \
            --dest "${BUNDLE_DIR}/wheels" \
            --platform "linux_${ARCH//-/_}" \
            --only-binary=:all: \
            --no-deps \
            "${packages[@]}" 2>&1; then
        log_ok "Downloaded $(ls -1 "${BUNDLE_DIR}/wheels" 2>/dev/null | wc -l) wheel files"
    else
        log_warn "Wheel download encountered issues - some packages may be missing"
    fi

    # Create wheel index
    cat > "${BUNDLE_DIR}/wheels/WHEELS.txt" <<EOF
# Python Packages for Jenkins-Ansible
# Downloaded: $(date)
# Platform: linux_${ARCH}
# Python: 3.8+
#
# Install on target machine:
#   pip3 install --no-index --find-links=. -r requirements.txt

$(ls -1 "${BUNDLE_DIR}/wheels" | grep -E '\.whl$' | sort)
EOF
    log_ok "Created wheel index: wheels/WHEELS.txt"
}

# =============================================================================
# GENERATE DEPLOYMENT MANIFEST
# =============================================================================

generate_manifest() {
    log_step "Generating Bundle Manifest"

    local image_tar="${BUNDLE_DIR}/images/jenkins-ansible-${ARCH}.tar.gz"
    local image_size="0B"
    [ -f "$image_tar" ] && image_size=$(du -sh "$image_tar" | cut -f1)

    local rpm_count=0
    [ -d "${BUNDLE_DIR}/rpms/podman" ] && rpm_count=$(find "${BUNDLE_DIR}/rpms/podman" -name "*.rpm" | wc -l)

    local wheel_count=0
    [ -d "${BUNDLE_DIR}/wheels" ] && wheel_count=$(find "${BUNDLE_DIR}/wheels" -name "*.whl" | wc -l)

    cat > "$MANIFEST_FILE" <<EOF
# Jenkins-Ansible Offline Bundle

**Build Date:** $(date)
**Build Machine:** ${OS_ID} ${OS_VERSION} (${ARCH})
**Bundle ID:** offline-bundle-${TIMESTAMP}

## Contents

### Container Images
- \`images/jenkins-ansible-${ARCH}.tar.gz\` (${image_size})
  - Jenkins LTS with pre-installed plugins
  - Ansible ${ANSIBLE_VERSION:-9.8.0}
  - All required tools (git, curl, rsync, etc.)

### RPM Packages
- Directory: \`rpms/podman/\` (${rpm_count} files)
  - Podman container runtime
  - Container networking (slirp4netns, fuse-overlayfs)
  - SELinux policies

### Python Wheels
- Directory: \`wheels/\` (${wheel_count} files)
  - Ansible and dependencies
  - Paramiko, Jinja2, PyYAML, netaddr
  - Platform: linux_${ARCH} (pre-compiled for target OS)

## Deployment on Target Machine

### System Requirements
- Oracle Linux 8.x or 9.x (or RHEL equivalent)
- ${ARCH} architecture
- 4GB RAM minimum
- 10GB disk space
- Sudo access (one-time, for Podman installation)

### Installation Steps

\`\`\`bash
# 1. Extract bundle
tar -xzf offline-bundle-${TIMESTAMP}.tar.gz

# 2. Install Podman RPMs (requires sudo)
cd offline-bundle-${TIMESTAMP}/rpms/podman
sudo dnf install -y *.rpm

# 3. Configure Podman for rootless operation
podman system migrate
echo "user.max_user_namespaces=28633" | sudo tee /etc/sysctl.d/80-userns.conf
sudo sysctl -p /etc/sysctl.d/80-userns.conf

# 4. Load Jenkins image
podman load < ../images/jenkins-ansible-${ARCH}.tar.gz

# 5. Run Jenkins-Ansible setup
cd ../..
./setup.sh --offline
\`\`\`

## Verification

### Verify bundle integrity
\`\`\`bash
cd offline-bundle-${TIMESTAMP}
sha256sum -c CHECKSUMS.sha256 || echo "Verification failed"
\`\`\`

### Verify installation on target
\`\`\`bash
# Check Podman
podman --version

# Check image loaded
podman images | grep jenkins-ansible

# Start Jenkins
systemctl --user status jenkins-ansible
curl http://localhost:8080/login
\`\`\`

## Troubleshooting

### RPM Installation Fails
If \`dnf install -y *.rpm\` fails with dependency errors:

\`\`\`bash
# Enable AppStream repo if needed
sudo dnf config-manager --enable ol9_appstream  # For Oracle Linux 9

# Or use createrepo to build a local repo
cd rpms/podman
createrepo .
cd ..
sudo dnf install -y --repofrompath=local,podman/. podman slirp4netns fuse-overlayfs
\`\`\`

### Image Load Fails
\`\`\`bash
# Verify image file is not corrupted
ls -lh images/jenkins-ansible-${ARCH}.tar.gz
file images/jenkins-ansible-${ARCH}.tar.gz  # Should show gzip

# Try loading with verbose output
podman load -i images/jenkins-ansible-${ARCH}.tar.gz --verbose
\`\`\`

### Wheel Installation Fails
If Python packages don't install:
\`\`\`bash
# Verify correct platform
python3 -c "import struct; print('linux_' + ('x86_64' if struct.calcsize('P') * 8 == 64 else 'arm64'))"

# Reinstall pip if needed
python3 -m pip install --upgrade pip setuptools
\`\`\`

## Build Information

- **Build OS:** ${OS_ID} ${OS_VERSION}
- **Arch:** ${ARCH}
- **Podman version included:** $(podman --version 2>/dev/null || echo "Check rpms/podman for version")
- **Python wheels:** Linux-specific (built on ${OS_ID})
- **All plugins pre-baked:** Yes (no internet needed at runtime)

## Support

For issues or questions:
1. Check build logs: \`tail -100 offline_build.log\`
2. Review OFFLINE_DEPLOYMENT.md in main project
3. Test on same OS as build machine (Oracle Linux → Oracle Linux, RHEL → RHEL)

---
*Generated by build-offline-bundle.sh*
EOF

    log_ok "Generated manifest: $MANIFEST_FILE"
}

# =============================================================================
# GENERATE CHECKSUMS
# =============================================================================

generate_checksums() {
    log_step "Generating Checksums for Integrity Verification"

    cd "$BUNDLE_DIR"
    find . -type f \( -name "*.tar.gz" -o -name "*.rpm" -o -name "*.whl" \) \
        -exec sha256sum {} + > CHECKSUMS.sha256

    local file_count
    file_count=$(wc -l < CHECKSUMS.sha256)
    log_ok "Generated checksums for ${file_count} files"

    cd - > /dev/null
}

# =============================================================================
# COPY SETUP SCRIPTS AND DEPLOYMENT FILES (EARLY - BEFORE OPTIONAL STEPS)
# =============================================================================

copy_setup_scripts() {
    log_step "Copying Setup Scripts and Deployment Files"

    # Copy critical deployment files
    log "Copying deployment scripts..."
    cp "${SCRIPT_DIR}/setup.sh" "${BUNDLE_DIR}/scripts/" || {
        log_error "Failed to copy setup.sh"
        exit 1
    }
    log_ok "Copied setup.sh"

    cp "${SCRIPT_DIR}/add-project.sh" "${BUNDLE_DIR}/scripts/" || {
        log_error "Failed to copy add-project.sh"
        exit 1
    }
    log_ok "Copied add-project.sh"

    # Copy configuration template
    cp "${SCRIPT_DIR}/.env.example" "${BUNDLE_DIR}/.env.example" || {
        log_error "Failed to copy .env.example"
        exit 1
    }
    log_ok "Copied .env.example"

    # Copy Docker/deployment config files
    log "Copying deployment configuration..."
    cp "${SCRIPT_DIR}/Dockerfile" "${BUNDLE_DIR}/" || {
        log_error "Failed to copy Dockerfile"
        exit 1
    }
    log_ok "Copied Dockerfile"

    cp "${SCRIPT_DIR}/docker-compose.yml" "${BUNDLE_DIR}/" || {
        log_error "Failed to copy docker-compose.yml"
        exit 1
    }
    log_ok "Copied docker-compose.yml"

    # Copy Jenkins configuration (CRITICAL for Docker build)
    if [ ! -d "${SCRIPT_DIR}/jenkins-config" ]; then
        log_error "jenkins-config directory not found"
        exit 1
    fi
    cp -r "${SCRIPT_DIR}/jenkins-config" "${BUNDLE_DIR}/" || {
        log_error "Failed to copy jenkins-config directory"
        exit 1
    }
    log_ok "Copied jenkins-config/"

    # Copy podman systemd service files (CRITICAL for deployment)
    if [ ! -d "${SCRIPT_DIR}/podman" ]; then
        log_error "podman directory not found (contains systemd service files)"
        exit 1
    fi
    mkdir -p "${BUNDLE_DIR}/scripts/podman"
    cp -r "${SCRIPT_DIR}/podman"/* "${BUNDLE_DIR}/scripts/podman/" || {
        log_error "Failed to copy podman service files"
        exit 1
    }
    log_ok "Copied podman service files"

    # Copy entire project source (optional, for reference)
    log "Copying project source..."
    tar -czf "${BUNDLE_DIR}/jenkins-ansible-source.tar.gz" \
        --exclude=".git" \
        --exclude="offline-bundle*" \
        --exclude="*.tar.gz" \
        --exclude="jenkins_home" \
        --exclude="__pycache__" \
        -C "$(dirname "$SCRIPT_DIR")" \
        "$(basename "$SCRIPT_DIR")" \
        2>/dev/null || log_warn "Could not copy full source (may not be in git repo)"

    log_ok "All deployment files copied successfully"
}

# =============================================================================
# CREATE FINAL ARCHIVE
# =============================================================================

create_final_archive() {
    log_step "Creating Final Offline Bundle Archive"

    local final_archive="${OUTPUT_DIR}/jenkins-ansible-offline-${OS_ID}${OS_VERSION}-${ARCH}-${TIMESTAMP}.tar.gz"

    log "Archiving: ${final_archive}"
    tar -czf "$final_archive" -C "$OUTPUT_DIR" "$(basename "$BUNDLE_DIR")" 2>&1 | tail -5

    local bundle_size
    bundle_size=$(du -sh "$final_archive" | cut -f1)

    log_ok "Final bundle: ${final_archive}"
    log_ok "Bundle size: ${bundle_size}"

    echo ""
    echo -e "${BOLD}${GREEN}✓ Offline Bundle Created Successfully${NC}"
    echo ""
    echo "  Bundle:  ${final_archive}"
    echo "  Size:    ${bundle_size}"
    echo "  Details: See ${BUNDLE_DIR}/MANIFEST.md"
    echo ""
    echo -e "${BOLD}Next Step:${NC} Transfer this file to your offline machine:"
    echo "  scp ${final_archive} user@offline-server:/tmp/"
    echo ""
}

# =============================================================================
# VERIFY BUNDLE COMPLETENESS
# =============================================================================

verify_bundle() {
    log_step "Verifying Bundle Completeness"

    local issues=0

    # Check for critical files
    local critical_files=(
        "scripts/setup.sh:Deployment script"
        "Dockerfile:Container definition"
        "jenkins-config/jenkins.yaml:Jenkins configuration"
    )

    for file_spec in "${critical_files[@]}"; do
        local file="${file_spec%:*}"
        local desc="${file_spec#*:}"
        if [ -f "${BUNDLE_DIR}/${file}" ]; then
            log_ok "Found: $desc"
        else
            log_warn "Missing: $desc (${file})"
            ((issues++))
        fi
    done

    # Check for container image
    if ls "${BUNDLE_DIR}"/images/jenkins-ansible-*.tar.gz &>/dev/null; then
        local img_size=$(du -sh "${BUNDLE_DIR}"/images/jenkins-ansible-*.tar.gz | cut -f1)
        log_ok "Found: Container image ($img_size)"
    else
        log_warn "Missing: Container image"
        ((issues++))
    fi

    if [ $issues -eq 0 ]; then
        log_ok "Bundle is complete ✓"
        return 0
    else
        log_warn "Bundle has $issues missing item(s) - it may not deploy correctly"
        return 0  # Don't fail, allow partial bundles
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Jenkins-Ansible Offline Bundle Builder                   ║"
    echo "║  (Must run on target OS: Oracle Linux or RHEL)            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Validate build environment FIRST (before any other checks)
    validate_build_environment
    validate_system
    setup_directories

    # Copy deployment files EARLY (before optional steps that might fail)
    copy_setup_scripts

    # Build container image (critical)
    build_image

    # Download optional components (failures don't stop the build)
    download_rpms || log_warn "RPM download had issues"
    download_wheels || log_warn "Wheel download had issues"

    # Finalize bundle
    generate_manifest
    generate_checksums
    verify_bundle
    create_final_archive

    echo -e "${BOLD}${GREEN}✅ Build Complete!${NC}"
}

# Run main with any remaining arguments
main "$@"
