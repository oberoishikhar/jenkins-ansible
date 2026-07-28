#!/usr/bin/env bash
# =============================================================================
# setup.sh — Jenkins + Ansible Deployment Hub
# =============================================================================
#
# This script sets up the complete Jenkins + Ansible deployment hub.
# It works on: macOS (Docker Desktop), RHEL 8/9, Oracle Linux 8/9
#
# USAGE:
#   ./setup.sh                         Online setup (needs internet, first time)
#   ./setup.sh --offline               Offline setup (uses bundle file)
#   ./setup.sh --build-offline-bundle  Build a bundle for offline machines
#   ./setup.sh --dry-run               Show what would be done, don't do it
#   ./setup.sh --help                  Show this help
#
# REQUIREMENTS:
#   macOS:        Docker Desktop installed and running
#   RHEL/OL:      sudo access (for Podman/Docker installation only)
#
# =============================================================================

set -euo pipefail

# ─── Script Location ─────────────────────────────────────────────────────────
# Always work relative to where THIS script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Version & Constants ─────────────────────────────────────────────────────
TOOL_VERSION="1.0.0"
IMAGE_NAME="jenkins-ansible"
IMAGE_TAG="latest"
CONTAINER_NAME="jenkins-ansible"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
BUNDLE_FILE="${SCRIPT_DIR}/jenkins-ansible-bundle.tar.gz"
LOG_FILE="${SCRIPT_DIR}/setup.log"
MIN_DISK_GB=5
MIN_RAM_MB=2048
JENKINS_PORT="${JENKINS_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-50000}"

# ─── Mode Flags ──────────────────────────────────────────────────────────────
MODE="online"           # online | offline | build-bundle | dry-run
RUNTIME=""              # detected: docker | podman
OS_TYPE=""              # detected: macos | rhel | oracle
OS_VERSION=""
ARCH=""                 # detected: amd64 | arm64

# ─── State Tracking (for rollback on failure) ─────────────────────────────────
SETUP_COMPLETE=false
CONTAINER_STARTED=false

# =============================================================================
# COLORS & FORMATTING
# =============================================================================
# Check if terminal supports colors
if [ -t 1 ] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    WHITE='\033[1;37m'
    GRAY='\033[0;37m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' MAGENTA='' WHITE='' GRAY='' BOLD='' NC=''
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
# All output goes to both screen AND setup.log for later troubleshooting
_log()        { echo -e "$*" | tee -a "$LOG_FILE"; }
log_header()  { _log "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
                _log "${BOLD}${BLUE}  $1${NC}"; \
                _log "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
log_ok()      { _log "  ${GREEN}✅ $1${NC}"; }
log_warn()    { _log "  ${YELLOW}⚠️  $1${NC}"; }
log_error()   { _log "  ${RED}❌ $1${NC}"; }
log_info()    { _log "  ${CYAN}ℹ️  $1${NC}"; }
log_doing()   { _log "  ${WHITE}🔄 $1${NC}"; }
log_step()    { _log "\n${BOLD}${MAGENTA}  ▶  $1${NC}"; }
log_blank()   { _log ""; }

# =============================================================================
# CLEANUP & ERROR HANDLER
# =============================================================================
cleanup_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ "$SETUP_COMPLETE" = false ]; then
        log_blank
        log_error "Setup encountered an error and was stopped."
        log_blank
        if [ "$CONTAINER_STARTED" = true ]; then
            log_doing "Stopping partially-started containers..."
            if [ "$RUNTIME" = "docker" ]; then
                docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true
            fi
        fi
        _log ""
        _log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        _log "${YELLOW}  What to do next:${NC}"
        _log "${YELLOW}  1. Read the error message above carefully${NC}"
        _log "${YELLOW}  2. Check the full log: cat setup.log${NC}"
        _log "${YELLOW}  3. Fix the problem and run ./setup.sh again${NC}"
        _log "${YELLOW}  4. If stuck, share setup.log when asking for help${NC}"
        _log "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        _log ""
    fi
}

trap cleanup_on_failure EXIT

# =============================================================================
# HELP TEXT
# =============================================================================
print_help() {
    cat << 'HELP'

Jenkins + Ansible Deployment Hub — Setup Script

USAGE:
  ./setup.sh [options]

OPTIONS:
  (no options)              Online setup — builds image, installs everything
  --offline                 Offline setup — loads from jenkins-ansible-bundle.tar.gz
  --build-offline-bundle    Create offline bundle for air-gapped machines
  --dry-run                 Show what WOULD be done, without doing it
  --help, -h                Show this help

EXAMPLES:
  # First-time setup (needs internet):
  ./setup.sh

  # Setup on machine with no internet:
  ./setup.sh --offline

  # Prepare offline bundle on internet-connected machine:
  ./setup.sh --build-offline-bundle

HELP
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --offline)               MODE="offline";;
            --build-offline-bundle)  MODE="build-bundle";;
            --dry-run)               MODE="dry-run";;
            --help|-h)               print_help; exit 0;;
            *)
                log_error "Unknown option: $1"
                log_info "Run ./setup.sh --help for usage"
                exit 1
                ;;
        esac
        shift
    done
}

# =============================================================================
# BANNER
# =============================================================================
print_banner() {
    _log ""
    _log "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    _log "${BOLD}${MAGENTA}║     🚀  Jenkins + Ansible Deployment Hub  v${TOOL_VERSION}         ║${NC}"
    _log "${BOLD}${MAGENTA}║     One-command setup for multi-project deployments      ║${NC}"
    _log "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    _log ""
    _log "  ${GRAY}Log file: ${LOG_FILE}${NC}"
    _log "  ${GRAY}Mode:     ${MODE}${NC}"
    _log "  ${GRAY}Started:  $(date)${NC}"
    _log ""

    if [ "$MODE" = "dry-run" ]; then
        _log "  ${YELLOW}${BOLD}DRY RUN MODE — Nothing will actually be installed or changed${NC}"
        _log ""
    fi
}

# =============================================================================
# OS & ARCHITECTURE DETECTION
# =============================================================================
detect_system() {
    log_step "Detecting your system..."

    # Detect architecture
    local raw_arch
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64)         ARCH="amd64";;
        aarch64|arm64)  ARCH="arm64";;
        *)              ARCH="$raw_arch"; log_warn "Unusual architecture: ${raw_arch}";;
    esac

    # Detect OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
        OS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "unknown")

        # Check macOS minimum version (12+)
        local major_ver
        major_ver=$(echo "$OS_VERSION" | cut -d. -f1)
        if [ "${major_ver:-0}" -lt 12 ] 2>/dev/null; then
            log_warn "macOS ${OS_VERSION} detected. macOS 12+ recommended."
        fi

    elif [ -f /etc/oracle-release ]; then
        OS_TYPE="oracle"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/oracle-release | head -1)
        local major_ver
        major_ver=$(echo "$OS_VERSION" | cut -d. -f1)
        if [ "${major_ver:-0}" -lt 8 ]; then
            log_error "Oracle Linux ${OS_VERSION} is not supported. Need Oracle Linux 8 or 9."
            exit 1
        fi

    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        local major_ver
        major_ver=$(echo "$OS_VERSION" | cut -d. -f1)
        if [ "${major_ver:-0}" -lt 8 ]; then
            log_error "RHEL ${OS_VERSION} is not supported. Need RHEL 8 or 9."
            exit 1
        fi

    else
        log_error "Unsupported operating system."
        log_info "This script supports: macOS, RHEL 8/9, Oracle Linux 8/9"
        log_info "Detected: $(uname -s) $(uname -r)"
        exit 1
    fi

    log_ok "Operating System: ${OS_TYPE} ${OS_VERSION}"
    log_ok "Architecture: ${ARCH} ($(uname -m))"
    _log ""
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
run_preflight_checks() {
    log_header "Pre-Flight Checks"
    log_info "Checking your system before making any changes..."
    _log ""

    local all_passed=true

    # ─── Check 1: Disk Space ─────────────────────────────────────────────────
    local available_kb
    if [[ "$OS_TYPE" == "macos" ]]; then
        available_kb=$(df -k "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    else
        available_kb=$(df -k "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    fi
    local available_gb=$(( ${available_kb:-0} / 1024 / 1024 ))

    if [ "$available_gb" -lt "$MIN_DISK_GB" ]; then
        log_error "Disk space: ${available_gb}GB available — need at least ${MIN_DISK_GB}GB"
        log_info "  Free up disk space, then run setup again."
        all_passed=false
    else
        log_ok "Disk space: ${available_gb}GB available (need ${MIN_DISK_GB}GB)"
    fi

    # ─── Check 2: RAM ────────────────────────────────────────────────────────
    local total_mb
    if [[ "$OS_TYPE" == "macos" ]]; then
        total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    else
        total_mb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 0)
    fi

    if [ "${total_mb:-0}" -lt "$MIN_RAM_MB" ]; then
        log_warn "RAM: ${total_mb}MB total — ${MIN_RAM_MB}MB recommended. Jenkins may be slow."
    else
        log_ok "RAM: ${total_mb}MB available"
    fi

    # ─── Check 3: Port Availability ──────────────────────────────────────────
    check_port_available "$JENKINS_PORT" "Jenkins Web UI" || all_passed=false
    check_port_available "$AGENT_PORT"   "Jenkins Agents"  || all_passed=false

    # ─── Check 4: Required files present ─────────────────────────────────────
    local required_files=(
        "Dockerfile"
        "docker-compose.yml"
        "jenkins-config/jenkins.yaml"
        "jenkins-config/plugins.txt"
        "jenkins-config/seed-job.groovy"
    )
    for f in "${required_files[@]}"; do
        if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
            log_error "Missing required file: ${f}"
            log_info "  Your setup files may be incomplete. Re-download the package."
            all_passed=false
        fi
    done
    if $all_passed; then
        log_ok "All required setup files present"
    fi

    # ─── Check 5: Mode-specific checks ───────────────────────────────────────
    if [ "$MODE" = "offline" ]; then
        if [ ! -f "$BUNDLE_FILE" ]; then
            log_error "Offline bundle not found: ${BUNDLE_FILE}"
            log_info "  You need the file 'jenkins-ansible-bundle.tar.gz' in this directory."
            log_info "  Get it from your administrator or the machine that built it."
            all_passed=false
        else
            local bundle_size
            bundle_size=$(du -sh "$BUNDLE_FILE" 2>/dev/null | cut -f1)
            log_ok "Offline bundle found: jenkins-ansible-bundle.tar.gz (${bundle_size})"
        fi
    elif [ "$MODE" = "online" ] || [ "$MODE" = "build-bundle" ]; then
        check_network_access || all_passed=false
    fi

    _log ""

    # ─── Summary ─────────────────────────────────────────────────────────────
    if [ "$all_passed" = false ]; then
        log_error "Pre-flight checks FAILED. Fix the issues above and run setup again."
        log_info "Your system has NOT been modified yet."
        exit 1
    fi

    log_ok "All pre-flight checks PASSED — safe to proceed"
}

check_port_available() {
    local port=$1
    local label=$2

    if command -v lsof &>/dev/null; then
        if lsof -i ":${port}" &>/dev/null 2>&1; then
            log_error "Port ${port} (${label}) is already in use"
            log_info "  Find what is using it: lsof -i :${port}"
            log_info "  Change the port in .env file: JENKINS_PORT=<new-port>  (edit your .env file)"
            return 1
        fi
    elif command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            log_error "Port ${port} (${label}) is already in use"
            log_info "  Find what is using it: ss -tlnp | grep :${port}"
            return 1
        fi
    fi
    log_ok "Port ${port} (${label}) is free"
    return 0
}

check_network_access() {
    log_doing "Checking internet access..."
    if curl -fsS --max-time 15 --connect-timeout 10 "https://registry-1.docker.io/v2/" > /dev/null 2>&1; then
        log_ok "Internet access: OK"
        return 0
    elif curl -fsS --max-time 15 --connect-timeout 10 "https://www.google.com" > /dev/null 2>&1; then
        log_warn "Docker registry may not be reachable, but internet is up. Proceeding..."
        return 0
    else
        log_error "No internet access detected"
        log_info "  For offline installation, use: ./setup.sh --offline"
        log_info "  For online installation, check your network connection."
        return 1
    fi
}

# =============================================================================
# ENVIRONMENT FILE SETUP
# =============================================================================
setup_env_file() {
    log_step "Checking configuration..."

    if [ ! -f "$ENV_FILE" ]; then
        log_doing "Creating .env configuration file from template..."
        cp "${SCRIPT_DIR}/.env.example" "$ENV_FILE"
        log_ok "Created .env file"
        log_warn "Using DEFAULT credentials (admin / changeme123)"
        log_warn "Change the password in .env before using in production!"
    else
        log_ok "Configuration file (.env) already exists"
    fi

    # Load the env file
    # shellcheck disable=SC1090
    set -o allexport
    source "$ENV_FILE"
    set +o allexport

    # Re-read port settings from env
    JENKINS_PORT="${JENKINS_PORT:-8080}"
    AGENT_PORT="${AGENT_PORT:-50000}"
}

# =============================================================================
# CONTAINER RUNTIME DETECTION & INSTALLATION
# =============================================================================
detect_or_install_runtime() {
    log_header "Container Runtime Setup"

    if [[ "$OS_TYPE" == "macos" ]]; then
        setup_runtime_macos
    else
        setup_runtime_linux
    fi
}

setup_runtime_macos() {
    log_step "Checking Docker Desktop (macOS)..."

    if command -v docker &>/dev/null; then
        # Docker command exists — check if daemon is running
        if docker info &>/dev/null 2>&1; then
            RUNTIME="docker"
            local version
            version=$(docker --version | cut -d' ' -f3 | tr -d ',')
            log_ok "Docker Desktop is running (version ${version})"
        else
            log_error "Docker Desktop is installed but NOT running"
            log_blank
            _log "  ${YELLOW}Please start Docker Desktop:${NC}"
            _log "  1. Find the Docker whale icon in your menu bar"
            _log "  2. Click it and wait for 'Docker Desktop is running'"
            _log "  3. Run ./setup.sh again"
            _log ""
            _log "  If Docker Desktop is not installed:"
            _log "  Download from: https://www.docker.com/products/docker-desktop/"
            exit 1
        fi
    else
        log_error "Docker Desktop is not installed"
        _log ""
        _log "  ${YELLOW}Install Docker Desktop:${NC}"
        _log "  1. Go to: https://www.docker.com/products/docker-desktop/"
        _log "  2. Download for Mac (${ARCH})"
        _log "  3. Install, start it, then run ./setup.sh again"
        exit 1
    fi

    # Check Docker Compose
    if docker compose version &>/dev/null 2>&1; then
        log_ok "Docker Compose: $(docker compose version --short)"
    else
        log_error "Docker Compose (v2) not found"
        log_info "Update Docker Desktop to the latest version (includes Compose v2)"
        exit 1
    fi

    # Check buildx for multi-arch
    if docker buildx version &>/dev/null 2>&1; then
        log_ok "Docker Buildx (multi-arch): available"
    else
        log_warn "Docker buildx not available — multi-arch builds will not work"
        log_info "Update Docker Desktop for buildx support"
    fi
}

setup_runtime_linux() {
    log_step "Checking container runtime (RHEL/Oracle Linux)..."

    # Check if Podman or Docker already installed
    local has_podman=false
    local has_docker=false

    command -v podman &>/dev/null && has_podman=true
    command -v docker &>/dev/null && has_docker=true

    if $has_podman; then
        RUNTIME="podman"
        local version
        version=$(podman --version | awk '{print $3}')
        log_ok "Podman detected (version ${version})"
        configure_podman_rootless
    elif $has_docker && docker info &>/dev/null 2>&1; then
        RUNTIME="docker"
        local version
        version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        log_ok "Docker detected (version ${version})"
    else
        log_info "No container runtime found. Installing Podman..."
        install_podman_linux
        RUNTIME="podman"
        configure_podman_rootless
    fi

    # Also ensure docker-compose is available (alias or actual)
    if [ "$RUNTIME" = "podman" ]; then
        if ! command -v podman-compose &>/dev/null; then
            log_doing "Installing podman-compose..."
            if command -v pip3 &>/dev/null; then
                pip3 install --user podman-compose 2>/dev/null || \
                    log_warn "Could not install podman-compose — will use podman directly"
            fi
        fi
    fi
}

install_podman_linux() {
    log_doing "Installing Podman..."

    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        log_info "Sudo access is needed to install Podman. You may be prompted for your password."
        if ! sudo -v; then
            log_error "Could not get sudo access"
            log_info "Ask your system administrator to install Podman:"
            log_info "  sudo dnf install -y podman slirp4netns fuse-overlayfs"
            exit 1
        fi
    fi

    if [ "$MODE" = "offline" ]; then
        install_podman_offline
    else
        install_podman_online
    fi

    log_ok "Podman installed: $(podman --version)"
}

install_podman_online() {
    sudo dnf install -y podman slirp4netns fuse-overlayfs 2>&1 | tee -a "$LOG_FILE"
}

install_podman_offline() {
    local rpm_dir="${SCRIPT_DIR}/offline-bundle/rpms"
    if [ ! -d "$rpm_dir" ] || [ -z "$(ls -A "$rpm_dir" 2>/dev/null)" ]; then
        log_error "Offline RPMs not found in: ${rpm_dir}"
        log_info "The offline bundle should contain an 'rpms' directory."
        log_info "Rebuild the bundle with: ./setup.sh --build-offline-bundle"
        exit 1
    fi
    log_doing "Installing from local RPM packages..."
    sudo dnf install -y "${rpm_dir}"/*.rpm 2>&1 | tee -a "$LOG_FILE"
}

configure_podman_rootless() {
    local current_user
    current_user=$(whoami)

    log_step "Configuring Podman for rootless operation..."

    # Check if subuid/subgid already configured
    if grep -q "^${current_user}:" /etc/subuid 2>/dev/null && \
       grep -q "^${current_user}:" /etc/subgid 2>/dev/null; then
        log_ok "Rootless user namespaces: already configured"
    else
        log_doing "Configuring user namespaces for ${current_user}..."
        if sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$current_user" 2>&1 | tee -a "$LOG_FILE"; then
            podman system migrate 2>/dev/null || true
            log_ok "User namespace mapping: configured"
        else
            log_warn "Could not configure user namespaces — rootless Podman may not work"
        fi
    fi

    # Check user.max_user_namespaces sysctl
    local ns_count
    ns_count=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)
    if [ "${ns_count:-0}" -lt 1000 ]; then
        log_doing "Enabling kernel user namespaces..."
        echo "user.max_user_namespaces=28633" | sudo tee /etc/sysctl.d/80-userns.conf > /dev/null
        sudo sysctl -p /etc/sysctl.d/80-userns.conf > /dev/null 2>&1 || true
        log_ok "User namespaces: enabled"
    else
        log_ok "User namespaces: already enabled (${ns_count})"
    fi

    # Enable lingering so containers survive after logout
    if ! loginctl show-user "$current_user" 2>/dev/null | grep -q "Linger=yes"; then
        sudo loginctl enable-linger "$current_user" 2>/dev/null || \
            log_warn "Could not enable loginctl linger — containers may stop on logout"
        log_ok "Systemd lingering: enabled (containers will survive logout)"
    else
        log_ok "Systemd lingering: already enabled"
    fi
}

# =============================================================================
# BUILD MULTI-ARCH IMAGE
# =============================================================================
build_image() {
    log_header "Building Jenkins + Ansible Image"
    log_info "This step downloads and installs all software into the image."
    log_info "First-time build takes 5-15 minutes (downloads ~800MB). Be patient! ☕"
    _log ""

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would build image: ${IMAGE_NAME}:${IMAGE_TAG}"
        return 0
    fi

    # Setup multi-arch builder
    if [ "$RUNTIME" = "docker" ]; then
        log_doing "Setting up multi-architecture build support..."
        if docker buildx version &>/dev/null 2>&1; then
            docker buildx create \
                --name jenkins-ansible-builder \
                --driver docker-container \
                --use \
                --bootstrap 2>/dev/null || \
            docker buildx use jenkins-ansible-builder 2>/dev/null || true
            log_ok "Multi-arch builder ready (supports amd64 + arm64)"
        fi

        log_doing "Building for platform: linux/${ARCH}..."
        log_info "Build log is saved to setup.log"

        if docker buildx build \
            --platform "linux/${ARCH}" \
            --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
            --load \
            --progress=plain \
            "$SCRIPT_DIR" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
        else
            log_error "Image build FAILED"
            log_info "Check setup.log for details"
            log_info "Common causes:"
            log_info "  - No internet access (plugin download failed)"
            log_info "  - Docker Desktop not running or out of memory"
            log_info "  - Dockerfile syntax error"
            exit 1
        fi

    else
        # Podman build
        log_doing "Building image with Podman for linux/${ARCH}..."
        if podman build \
            --network host \
            --platform "linux/${ARCH}" \
            --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
            "$SCRIPT_DIR" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
        else
            log_error "Image build FAILED. Check setup.log for details."
            exit 1
        fi
    fi

    # Show final image size
    local image_size
    if [ "$RUNTIME" = "docker" ]; then
        image_size=$(docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" \
            --format '{{.Size}}' 2>/dev/null | \
            awk '{printf "%.1fGB", $1/1024/1024/1024}' || echo "unknown")
    else
        image_size=$(podman image inspect "${IMAGE_NAME}:${IMAGE_TAG}" \
            --format '{{.Size}}' 2>/dev/null | \
            awk '{printf "%.1fGB", $1/1024/1024/1024}' || echo "unknown")
    fi
    log_ok "Image size: ${image_size}"
}

# =============================================================================
# LOAD IMAGE FROM OFFLINE BUNDLE
# =============================================================================
load_image() {
    log_header "Loading Image from Offline Bundle"

    local bundle_size
    bundle_size=$(du -sh "$BUNDLE_FILE" | cut -f1)
    log_info "Loading ${bundle_size} bundle (may take 2-5 minutes)..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would load image from: ${BUNDLE_FILE}"
        return 0
    fi

    if [ "$RUNTIME" = "docker" ]; then
        if docker load < "$BUNDLE_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Image loaded successfully"
        else
            log_error "Failed to load image from bundle"
            log_info "The bundle file may be corrupted. Try downloading it again."
            exit 1
        fi
    else
        if podman load < "$BUNDLE_FILE" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Image loaded successfully"
        else
            log_error "Failed to load image from bundle"
            exit 1
        fi
    fi

    # Verify image loaded
    local verify_cmd
    if [ "$RUNTIME" = "docker" ]; then
        verify_cmd="docker image inspect ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        verify_cmd="podman image inspect ${IMAGE_NAME}:${IMAGE_TAG}"
    fi

    if $verify_cmd &>/dev/null; then
        log_ok "Image verified: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        log_error "Image not found after loading. Bundle may be for a different image name."
        exit 1
    fi
}

# =============================================================================
# SET UP DIRECTORY STRUCTURE
# =============================================================================
setup_directories() {
    log_step "Setting up directory structure..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would create directories: projects/, ssh-keys/"
        return 0
    fi

    # Create directories with correct permissions
    mkdir -p "${SCRIPT_DIR}/projects/_template/inventory"
    mkdir -p "${SCRIPT_DIR}/projects/_template/playbooks"
    mkdir -p "${SCRIPT_DIR}/ssh-keys"
    mkdir -p "${SCRIPT_DIR}/jenkins-config"

    # Set permissions
    chmod 700 "${SCRIPT_DIR}/ssh-keys"    # Private keys must be protected

    log_ok "Directories created"
    log_ok "ssh-keys/ directory: protected (chmod 700)"
}

# =============================================================================
# START JENKINS (Docker Compose or Podman Quadlet)
# =============================================================================
start_services() {
    log_header "Starting Jenkins"

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would start Jenkins container"
        return 0
    fi

    # Check if already running
    if [ "$RUNTIME" = "docker" ]; then
        if docker ps --filter "name=${CONTAINER_NAME}" --filter "status=running" -q 2>/dev/null | grep -q .; then
            log_warn "Jenkins is already running!"
            log_info "To restart: docker compose restart"
            log_info "To stop:    docker compose down"
            CONTAINER_STARTED=true
            return 0
        fi

        log_doing "Starting Jenkins container..."
        CONTAINER_STARTED=true
        if docker compose -f "$COMPOSE_FILE" up -d 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Jenkins container started"
        else
            log_error "Failed to start Jenkins"
            log_info "Check logs: docker logs ${CONTAINER_NAME}"
            exit 1
        fi

    else
        # Podman with Quadlet (systemd)
        log_doing "Installing Jenkins as a systemd user service..."
        mkdir -p "${HOME}/.config/containers/systemd/"
        cp "${SCRIPT_DIR}/podman/jenkins-ansible.container" "${HOME}/.config/containers/systemd/"
        cp "${SCRIPT_DIR}/podman/jenkins_home.volume" "${HOME}/.config/containers/systemd/"

        systemctl --user daemon-reload
        CONTAINER_STARTED=true

        if systemctl --user enable --now jenkins-ansible 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Jenkins service started (systemctl --user status jenkins-ansible)"
        else
            log_error "Failed to start Jenkins systemd service"
            log_info "Check: journalctl --user -u jenkins-ansible"
            exit 1
        fi
    fi
}

# =============================================================================
# WAIT FOR JENKINS TO BECOME READY
# =============================================================================
wait_for_jenkins() {
    log_step "Waiting for Jenkins to start up..."
    log_info "Jenkins takes 60-90 seconds to initialise. Please wait..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would wait for Jenkins at http://localhost:${JENKINS_PORT}"
        return 0
    fi

    local max_wait=180
    local waited=0
    local url="http://localhost:${JENKINS_PORT}"
    local dot_count=0

    while [ $waited -lt $max_wait ]; do
        if curl -sf --max-time 5 "${url}/login" > /dev/null 2>&1; then
            echo ""
            log_ok "Jenkins is ready! (took ${waited}s)"
            return 0
        fi

        # Show progress dots
        printf "."
        dot_count=$((dot_count + 1))
        if [ $dot_count -ge 60 ]; then
            echo ""
            dot_count=0
        fi

        sleep 3
        waited=$((waited + 3))
    done

    echo ""
    log_error "Jenkins did not start within ${max_wait} seconds"
    log_info "Check what's happening:"
    if [ "$RUNTIME" = "docker" ]; then
        log_info "  docker logs ${CONTAINER_NAME} | tail -50"
        log_info "  docker ps -a"
    else
        log_info "  journalctl --user -u jenkins-ansible | tail -50"
    fi
    exit 1
}

# =============================================================================
# TRIGGER SEED JOB
# =============================================================================
trigger_seed_job() {
    log_step "Discovering projects..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would approve and trigger seed job via Jenkins API"
        return 0
    fi

    local admin_user="${JENKINS_ADMIN_USER:-admin}"
    local admin_pass="${JENKINS_ADMIN_PASSWORD:-changeme123}"
    local url="http://localhost:${JENKINS_PORT}"

    # Give init.groovy.d scripts a moment to create the Seed-Job
    log_doing "Waiting for Jenkins to finish initial configuration..."
    sleep 15

    # Get CSRF crumb (required for POST requests)
    # IMPORTANT: save the session cookie (-c) and reuse it (-b) — Jenkins ties crumbs to sessions
    local cookie_jar
    cookie_jar=$(mktemp /tmp/jenkins-cookies-XXXXXX.txt)
    local crumb=""
    crumb=$(curl -sf --max-time 10 \
        -c "${cookie_jar}" \
        -u "${admin_user}:${admin_pass}" \
        "${url}/crumbIssuer/api/json" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crumb',''))" 2>/dev/null || echo "")

    local curl_auth=(-sf --max-time 15 -b "${cookie_jar}" -u "${admin_user}:${admin_pass}")
    if [ -n "$crumb" ]; then
        curl_auth+=(-H "Jenkins-Crumb:${crumb}")
    fi

    # ── Step 1: Trigger Seed-Job once (it will fail — adds script to pending approval) ─
    # Job DSL script approval requires the exact hash the plugin computes (format changes
    # between plugin versions). The safest approach: let it fail once, then approve the
    # pending entry which contains the EXACT hash the plugin is looking for.
    log_doing "Running seed job (initial run to capture script hash)..."
    curl "${curl_auth[@]}" -X POST "${url}/job/_Admin/job/Seed-Job/build" > /dev/null 2>&1 || true
    sleep 20  # wait for the build to start and fail

    # ── Step 2: Approve the pending script via Script Console ────────────────
    # This script reads all pending (unapproved) scripts and approves them.
    # Using Script Console gives full admin trust — no classloader restrictions.
    log_doing "Approving seed job script..."
    local approve_script
    approve_script='
import org.jenkinsci.plugins.scriptsecurity.scripts.ScriptApproval

def approval = ScriptApproval.get()
def pending = approval.pendingScripts.toList()
if (pending) {
    pending.each { ps ->
        approval.approveScript(ps.hash)
        println "APPROVED: " + ps.hash
    }
    approval.save()
} else if (approval.approvedScriptHashes) {
    println "ALREADY_APPROVED: scripts previously approved"
} else {
    println "NOTHING_PENDING: no scripts waiting for approval"
}
'
    local approval_result=""
    approval_result=$(curl "${curl_auth[@]}" -X POST \
        --data-urlencode "script=${approve_script}" \
        "${url}/scriptText" 2>/dev/null || echo "")

    if echo "$approval_result" | grep -qE "APPROVED:|ALREADY_APPROVED:"; then
        log_ok "Seed script approved"
    else
        log_warn "Could not auto-approve seed script"
        log_info "  Approve manually: Manage Jenkins → In-process Script Approval → Approve"
    fi

    # ── Step 3: Trigger Seed-Job again — now approved, should succeed ────────
    sleep 3
    if curl "${curl_auth[@]}" -X POST "${url}/job/_Admin/job/Seed-Job/build" > /dev/null 2>&1; then
        log_ok "Seed job triggered — project pipelines will appear in ~30 seconds"
    else
        log_warn "Could not trigger seed job"
        log_info "  Trigger manually: Jenkins → _Admin → Seed-Job → Build Now"
    fi
}

# =============================================================================
# SUCCESS SUMMARY
# =============================================================================
print_success() {
    local admin_user="${JENKINS_ADMIN_USER:-admin}"
    local admin_pass="${JENKINS_ADMIN_PASSWORD:-changeme123}"

    _log ""
    _log "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    _log "${BOLD}${GREEN}║                                                          ║${NC}"
    _log "${BOLD}${GREEN}║  🎉  Jenkins + Ansible Hub is UP and RUNNING!            ║${NC}"
    _log "${BOLD}${GREEN}║                                                          ║${NC}"
    _log "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    _log ""
    _log "  ${BOLD}Jenkins URL:${NC}  ${CYAN}http://localhost:${JENKINS_PORT}${NC}"
    _log "  ${BOLD}Username:${NC}     ${CYAN}${admin_user}${NC}"
    _log "  ${BOLD}Password:${NC}     ${CYAN}${admin_pass}${NC}"
    _log ""
    _log "  ${BOLD}${YELLOW}⚠️  First time?  Change the default password!${NC}"
    _log "  ${YELLOW}  Go to: ${admin_user} (top right) → Configure → Password${NC}"
    _log ""
    _log "  ${BOLD}Next Steps:${NC}"
    _log "  ${BOLD}1.${NC} Open Jenkins in your browser"
    _log "  ${BOLD}2.${NC} Go to _Admin → Seed-Job → Build Now (discovers projects)"
    _log "  ${BOLD}3.${NC} Add your first project:"
    _log "     ${CYAN}./add-project.sh --name myapp --host 192.168.1.100 --user deployuser${NC}"
    _log ""
    _log "  ${BOLD}Useful Commands:${NC}"
    if [ "$RUNTIME" = "docker" ]; then
        _log "  View logs:   ${GRAY}docker logs -f ${CONTAINER_NAME}${NC}"
        _log "  Stop:        ${GRAY}docker compose down${NC}"
        _log "  Start:       ${GRAY}docker compose up -d${NC}"
        _log "  Restart:     ${GRAY}docker compose restart${NC}"
        _log "  Shell into:  ${GRAY}docker exec -it ${CONTAINER_NAME} bash${NC}"
    else
        _log "  View logs:   ${GRAY}journalctl --user -u jenkins-ansible -f${NC}"
        _log "  Stop:        ${GRAY}systemctl --user stop jenkins-ansible${NC}"
        _log "  Start:       ${GRAY}systemctl --user start jenkins-ansible${NC}"
        _log "  Status:      ${GRAY}systemctl --user status jenkins-ansible${NC}"
    fi
    _log ""
    _log "  ${GRAY}Full setup log: ${LOG_FILE}${NC}"
    _log ""
}

# =============================================================================
# BUILD OFFLINE BUNDLE
# =============================================================================
build_offline_bundle() {
    log_header "Building Offline Bundle"
    log_info "This creates a package you can transfer to machines with no internet."
    log_info "This machine needs internet access for this step."
    _log ""

    local bundle_dir="${SCRIPT_DIR}/offline-bundle"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local final_bundle="${SCRIPT_DIR}/jenkins-ansible-offline-${timestamp}.tar.gz"

    mkdir -p "${bundle_dir}/rpms"
    mkdir -p "${bundle_dir}/pip-wheels"

    # Step 1: Build the Docker image (bakes in all plugins)
    log_step "Building Docker image (all plugins will be included)..."
    MODE="online"
    detect_or_install_runtime
    build_image

    # Step 2: Save Docker image to tarball
    log_step "Saving image to tarball..."
    log_info "This creates a large file (~1.5-2GB)..."
    log_doing "Saving linux/${ARCH} image..."
    if [ "$RUNTIME" = "docker" ]; then
        docker save "${IMAGE_NAME}:${IMAGE_TAG}" | gzip > "${BUNDLE_FILE}"
    else
        podman save "${IMAGE_NAME}:${IMAGE_TAG}" | gzip > "${BUNDLE_FILE}"
    fi
    log_ok "Image saved: $(du -sh "$BUNDLE_FILE" | cut -f1)"

    # Step 3: Build ARM64 image if on amd64
    if [ "$ARCH" = "amd64" ] && command -v docker &>/dev/null && docker buildx version &>/dev/null 2>&1; then
        log_step "Building ARM64 image (for Raspberry Pi)..."
        local arm64_bundle="${bundle_dir}/jenkins-ansible-arm64.tar.gz"
        docker buildx build \
            --platform linux/arm64 \
            --tag "${IMAGE_NAME}:arm64" \
            --output "type=docker,dest=${arm64_bundle}" \
            "$SCRIPT_DIR" 2>&1 | tee -a "$LOG_FILE" || \
            log_warn "ARM64 build failed — amd64 only bundle will be created"
        if [ -f "$arm64_bundle" ]; then
            log_ok "ARM64 image saved: $(du -sh "$arm64_bundle" | cut -f1)"
        fi
    fi

    # Step 4: Download RHEL/OL RPMs
    if command -v dnf &>/dev/null; then
        log_step "Downloading RHEL/Oracle Linux RPMs for offline install..."
        dnf download \
            --resolve \
            --destdir="${bundle_dir}/rpms" \
            podman slirp4netns fuse-overlayfs container-selinux 2>&1 | \
            tee -a "$LOG_FILE" || log_warn "RPM download failed — manual install needed on RHEL/OL"
    else
        log_info "Not on RHEL/OL — skipping RPM download"
        log_info "For RHEL/OL offline install, run this on a RHEL/OL machine:"
        log_info "  dnf download --resolve --destdir=offline-bundle/rpms podman slirp4netns fuse-overlayfs"
    fi

    # Step 5: Download pip wheels
    log_step "Downloading Python/Ansible pip wheels..."
    if command -v pip3 &>/dev/null; then
        pip3 download \
            --dest "${bundle_dir}/pip-wheels" \
            ansible paramiko jinja2 PyYAML netaddr 2>&1 | \
            tee -a "$LOG_FILE" || log_warn "Pip wheel download failed"
        log_ok "Pip wheels downloaded: $(ls -1 "${bundle_dir}/pip-wheels" | wc -l) packages"
    else
        log_warn "pip3 not found — skipping pip wheel download"
    fi

    # Step 6: Package everything
    log_step "Creating final offline bundle archive..."
    tar -czf "$final_bundle" \
        --exclude="${SCRIPT_DIR}/offline-bundle" \
        --exclude="${SCRIPT_DIR}/.git" \
        --exclude="${SCRIPT_DIR}/jenkins_home" \
        -C "$(dirname "$SCRIPT_DIR")" \
        "$(basename "$SCRIPT_DIR")" \
        -C "$SCRIPT_DIR" \
        "offline-bundle" \
        2>&1 | tee -a "$LOG_FILE"

    log_ok "Final bundle: ${final_bundle}"
    log_ok "Bundle size: $(du -sh "$final_bundle" | cut -f1)"
    _log ""
    _log "  ${BOLD}Transfer this bundle to your offline machine:${NC}"
    _log "  ${CYAN}scp ${final_bundle} user@offline-server:/target/path/${NC}"
    _log ""
    _log "  ${BOLD}On the offline machine:${NC}"
    _log "  ${CYAN}tar -xzf jenkins-ansible-offline-${timestamp}.tar.gz${NC}"
    _log "  ${CYAN}cd Jenkins-Ansible${NC}"
    _log "  ${CYAN}./setup.sh --offline${NC}"
    _log ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
main() {
    # Initialize log
    echo "Jenkins + Ansible Hub Setup — $(date)" > "$LOG_FILE"
    echo "Version: ${TOOL_VERSION}" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"

    parse_args "$@"
    print_banner

    # ── Build offline bundle mode ────────────────────────────────────────────
    if [ "$MODE" = "build-bundle" ]; then
        detect_system
        run_preflight_checks
        build_offline_bundle
        SETUP_COMPLETE=true
        return 0
    fi

    # ── Normal setup (online / offline / dry-run) ────────────────────────────

    log_header "Step 1 of 6 — System Detection"
    detect_system

    # Load .env early so port settings are respected during preflight checks
    # (full setup_env_file runs in Step 3 to handle creation/prompts)
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        set -o allexport
        # shellcheck disable=SC1090
        source "${SCRIPT_DIR}/.env"
        set +o allexport
        JENKINS_PORT="${JENKINS_PORT:-8080}"
        AGENT_PORT="${AGENT_PORT:-50000}"
    fi

    log_header "Step 2 of 6 — Pre-Flight Checks"
    run_preflight_checks

    log_header "Step 3 of 6 — Configuration"
    setup_env_file

    log_header "Step 4 of 6 — Container Runtime"
    detect_or_install_runtime

    log_header "Step 5 of 6 — Jenkins Image"
    setup_directories
    if [ "$MODE" = "offline" ]; then
        load_image
    else
        build_image
    fi

    log_header "Step 6 of 6 — Starting Jenkins"
    start_services
    wait_for_jenkins
    trigger_seed_job

    SETUP_COMPLETE=true
    print_success
}

main "$@"
