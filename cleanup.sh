#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Jenkins + Ansible Setup Removal
# =============================================================================
#
# This script cleanly uninstalls the Jenkins + Ansible deployment hub.
# It works on: macOS (Docker Desktop), RHEL 8/9, Oracle Linux 8/9
#
# USAGE:
#   ./cleanup.sh                    Interactive cleanup (asks before deleting)
#   ./cleanup.sh --force            Remove everything without prompting
#   ./cleanup.sh --containers-only  Stop & remove containers only (keep configs)
#   ./cleanup.sh --dry-run          Show what would be deleted, don't delete it
#   ./cleanup.sh --help             Show this help
#
# =============================================================================

set -euo pipefail

# ─── Script Location ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Constants ───────────────────────────────────────────────────────────────
CONTAINER_NAME="jenkins-ansible"
IMAGE_NAME="jenkins-ansible"
IMAGE_TAG="latest"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
LOG_FILE="${SCRIPT_DIR}/cleanup.log"

# ─── Cleanup Flags ───────────────────────────────────────────────────────────
MODE="interactive"              # interactive | force | containers-only | dry-run
RUNTIME=""                      # detected: docker | podman
OS_TYPE=""                      # detected: macos | rhel | oracle
CLEANUP_CONTAINERS=true
CLEANUP_IMAGES=false
CLEANUP_DIRECTORIES=false
CLEANUP_RUNTIME=false

# ─── Detection ───────────────────────────────────────────────────────────────
INSTALLED_PODMAN=false
RUNNING_CONTAINERS=""

# =============================================================================
# COLORS & FORMATTING
# =============================================================================
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
# HELP TEXT
# =============================================================================
print_help() {
    cat << 'HELP'

Jenkins + Ansible Hub — Cleanup Script

USAGE:
  ./cleanup.sh [options]

OPTIONS:
  (no options)              Interactive mode — shows what will be deleted and asks
  --force                   Remove everything without prompting (use with caution!)
  --containers-only         Stop & remove only containers (keep configuration)
  --dry-run                 Show what would be deleted without doing it
  --help, -h                Show this help

EXAMPLES:
  # Interactive cleanup (shows what will be deleted, asks before each step):
  ./cleanup.sh

  # Remove everything without asking (careful!):
  ./cleanup.sh --force

  # Just stop the Jenkins container (keep configs for later restart):
  ./cleanup.sh --containers-only

  # See what would be deleted:
  ./cleanup.sh --dry-run

WHAT GETS CLEANED UP:
  - Jenkins Docker/Podman container (running or stopped)
  - Jenkins image (docker-ansible:latest)
  - Systemd service (if using Podman)
  - Configuration files (jenkins-config/)
  - SSH keys directory (ssh-keys/)
  - Project configurations (projects/)
  - Environment configuration (.env)

What is NOT deleted:
  - Docker/Podman runtime (unless explicitly installed by setup.sh)
  - Setup script files (setup.sh, cleanup.sh, docker-compose.yml, etc.)
  - Setup logs (setup.log)

HELP
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)               MODE="force";;
            --containers-only)     MODE="containers-only";;
            --dry-run)             MODE="dry-run";;
            --help|-h)             print_help; exit 0;;
            *)
                log_error "Unknown option: $1"
                log_info "Run ./cleanup.sh --help for usage"
                exit 1
                ;;
        esac
        shift
    done
}

# =============================================================================
# SYSTEM DETECTION
# =============================================================================
detect_system() {
    log_step "Detecting your system..."

    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    elif [ -f /etc/oracle-release ]; then
        OS_TYPE="oracle"
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
    else
        log_error "Unsupported operating system"
        exit 1
    fi

    log_ok "Operating System: ${OS_TYPE}"
}

# =============================================================================
# DETECT CONTAINER RUNTIME
# =============================================================================
detect_runtime() {
    log_step "Detecting container runtime..."

    if command -v podman &>/dev/null; then
        RUNTIME="podman"
        log_ok "Podman detected"
    elif command -v docker &>/dev/null; then
        RUNTIME="docker"
        log_ok "Docker detected"
    else
        log_warn "No container runtime found (Docker/Podman)"
        log_info "Nothing to clean up"
        return 1
    fi
}

# =============================================================================
# DETECT WHAT'S INSTALLED
# =============================================================================
detect_installations() {
    log_step "Checking what's installed..."

    if [ "$RUNTIME" = "docker" ]; then
        # Check for running/stopped containers
        if docker ps -a --filter "name=${CONTAINER_NAME}" -q 2>/dev/null | grep -q .; then
            RUNNING_CONTAINERS=$(docker ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}}")
            log_ok "Found container(s): ${RUNNING_CONTAINERS}"
            CLEANUP_CONTAINERS=true
        fi

        # Check for image
        if docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" &>/dev/null 2>&1; then
            log_ok "Found image: ${IMAGE_NAME}:${IMAGE_TAG}"
            CLEANUP_IMAGES=true
        fi

    else
        # Podman
        if podman ps -a --filter "name=${CONTAINER_NAME}" -q 2>/dev/null | grep -q .; then
            RUNNING_CONTAINERS=$(podman ps -a --filter "name=${CONTAINER_NAME}" --format "{{.Names}}")
            log_ok "Found container(s): ${RUNNING_CONTAINERS}"
            CLEANUP_CONTAINERS=true
        fi

        # Check for image
        if podman image inspect "${IMAGE_NAME}:${IMAGE_TAG}" &>/dev/null 2>&1; then
            log_ok "Found image: ${IMAGE_NAME}:${IMAGE_TAG}"
            CLEANUP_IMAGES=true
        fi

        # Check for systemd service
        if systemctl --user list-units --type=service --all 2>/dev/null | grep -q "jenkins-ansible"; then
            log_ok "Found systemd service: jenkins-ansible"
            CLEANUP_DIRECTORIES=true
        fi
    fi

    # Check for configuration directories
    local has_config=false
    [ -d "${SCRIPT_DIR}/jenkins-config" ] && has_config=true && log_ok "Found: jenkins-config/"
    [ -d "${SCRIPT_DIR}/ssh-keys" ] && has_config=true && log_ok "Found: ssh-keys/"
    [ -d "${SCRIPT_DIR}/projects" ] && has_config=true && log_ok "Found: projects/"
    [ -f "${SCRIPT_DIR}/.env" ] && has_config=true && log_ok "Found: .env"

    if $has_config; then
        CLEANUP_DIRECTORIES=true
    fi
}

# =============================================================================
# PROMPT FUNCTIONS
# =============================================================================
confirm_action() {
    local prompt=$1
    local default=${2:-"n"}

    if [ "$MODE" = "force" ]; then
        return 0
    fi

    if [ "$MODE" = "dry-run" ]; then
        return 0
    fi

    while true; do
        if [ "$default" = "y" ]; then
            read -p "  ${YELLOW}${prompt} [Y/n]${NC} " response
            response=${response:-"y"}
        else
            read -p "  ${YELLOW}${prompt} [y/N]${NC} " response
            response=${response:-"n"}
        fi

        case "$response" in
            [yY][eE][sS]|[yY]) return 0;;
            [nN][oO]|[nN]) return 1;;
            *) echo "  Please answer 'y' or 'n'";;
        esac
    done
}

# =============================================================================
# CLEANUP STEPS
# =============================================================================

cleanup_docker_containers() {
    if [ ! "$CLEANUP_CONTAINERS" = true ]; then
        return 0
    fi

    log_step "Stopping and removing Docker containers..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would remove containers: ${RUNNING_CONTAINERS}"
        return 0
    fi

    if ! confirm_action "Remove Docker container(s)? (${RUNNING_CONTAINERS})"; then
        log_warn "Skipping container removal"
        return 0
    fi

    # Stop docker-compose services
    if [ -f "$COMPOSE_FILE" ]; then
        log_doing "Stopping docker-compose services..."
        if docker compose -f "$COMPOSE_FILE" down 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Docker compose services stopped"
        else
            log_warn "Could not stop docker-compose (may already be stopped)"
        fi
    fi

    # Force remove any remaining containers
    for container in $RUNNING_CONTAINERS; do
        log_doing "Removing container: ${container}..."
        if docker rm -f "$container" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Container removed: ${container}"
        else
            log_warn "Could not remove container: ${container}"
        fi
    done
}

cleanup_docker_images() {
    if [ ! "$CLEANUP_IMAGES" = true ] || [ "$RUNTIME" != "docker" ]; then
        return 0
    fi

    log_step "Removing Docker images..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would remove image: ${IMAGE_NAME}:${IMAGE_TAG}"
        return 0
    fi

    if ! confirm_action "Remove Docker image? (${IMAGE_NAME}:${IMAGE_TAG})"; then
        log_warn "Skipping image removal"
        return 0
    fi

    log_doing "Removing image: ${IMAGE_NAME}:${IMAGE_TAG}..."
    if docker rmi -f "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Image removed: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        log_warn "Could not remove image (may not exist)"
    fi
}

cleanup_podman_services() {
    if [ ! "$CLEANUP_CONTAINERS" = true ] || [ "$RUNTIME" != "podman" ]; then
        return 0
    fi

    log_step "Stopping and removing Podman containers..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would remove containers: ${RUNNING_CONTAINERS}"
        return 0
    fi

    if ! confirm_action "Remove Podman container(s)? (${RUNNING_CONTAINERS})"; then
        log_warn "Skipping container removal"
        return 0
    fi

    # Stop systemd service
    if systemctl --user is-active --quiet jenkins-ansible 2>/dev/null; then
        log_doing "Disabling systemd service jenkins-ansible..."
        if systemctl --user disable --now jenkins-ansible 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Systemd service disabled"
        else
            log_warn "Could not disable systemd service"
        fi
    fi

    # Remove quadlet files
    local quadlet_dir="${HOME}/.config/containers/systemd"
    if [ -f "${quadlet_dir}/jenkins-ansible.container" ]; then
        log_doing "Removing quadlet configuration..."
        rm -f "${quadlet_dir}/jenkins-ansible.container"
        rm -f "${quadlet_dir}/jenkins_home.volume"
        systemctl --user daemon-reload 2>/dev/null || true
        log_ok "Quadlet files removed"
    fi

    # Force remove any remaining containers
    for container in $RUNNING_CONTAINERS; do
        log_doing "Removing container: ${container}..."
        if podman rm -f "$container" 2>&1 | tee -a "$LOG_FILE"; then
            log_ok "Container removed: ${container}"
        else
            log_warn "Could not remove container: ${container}"
        fi
    done
}

cleanup_podman_images() {
    if [ ! "$CLEANUP_IMAGES" = true ] || [ "$RUNTIME" != "podman" ]; then
        return 0
    fi

    log_step "Removing Podman images..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would remove image: ${IMAGE_NAME}:${IMAGE_TAG}"
        return 0
    fi

    if ! confirm_action "Remove Podman image? (${IMAGE_NAME}:${IMAGE_TAG})"; then
        log_warn "Skipping image removal"
        return 0
    fi

    log_doing "Removing image: ${IMAGE_NAME}:${IMAGE_TAG}..."
    if podman rmi -f "${IMAGE_NAME}:${IMAGE_TAG}" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Image removed: ${IMAGE_NAME}:${IMAGE_TAG}"
    else
        log_warn "Could not remove image (may not exist)"
    fi
}

cleanup_configuration_files() {
    if [ ! "$CLEANUP_DIRECTORIES" = true ]; then
        return 0
    fi

    log_step "Removing configuration files and directories..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Would remove:"
        [ -d "${SCRIPT_DIR}/jenkins-config" ] && log_info "  - jenkins-config/"
        [ -d "${SCRIPT_DIR}/ssh-keys" ] && log_info "  - ssh-keys/"
        [ -d "${SCRIPT_DIR}/projects" ] && log_info "  - projects/"
        [ -f "${SCRIPT_DIR}/.env" ] && log_info "  - .env"
        return 0
    fi

    if ! confirm_action "Remove configuration files? (jenkins-config/, ssh-keys/, projects/, .env)"; then
        log_warn "Skipping configuration removal"
        return 0
    fi

    if [ -d "${SCRIPT_DIR}/jenkins-config" ]; then
        log_doing "Removing jenkins-config/..."
        rm -rf "${SCRIPT_DIR}/jenkins-config"
        log_ok "Removed: jenkins-config/"
    fi

    if [ -d "${SCRIPT_DIR}/ssh-keys" ]; then
        log_doing "Removing ssh-keys/..."
        rm -rf "${SCRIPT_DIR}/ssh-keys"
        log_ok "Removed: ssh-keys/"
    fi

    if [ -d "${SCRIPT_DIR}/projects" ]; then
        log_doing "Removing projects/..."
        rm -rf "${SCRIPT_DIR}/projects"
        log_ok "Removed: projects/"
    fi

    if [ -f "${SCRIPT_DIR}/.env" ]; then
        log_doing "Removing .env..."
        rm -f "${SCRIPT_DIR}/.env"
        log_ok "Removed: .env"
    fi
}

cleanup_podman_installation() {
    # Only prompt if Podman exists and was possibly installed by setup.sh
    if [ "$RUNTIME" != "podman" ] || [ ! -d /etc/containers ]; then
        return 0
    fi

    log_step "Podman cleanup option..."

    if [ "$MODE" = "dry-run" ]; then
        log_info "DRY RUN: Could optionally remove Podman (not automated)"
        return 0
    fi

    if confirm_action "Remove Podman? (Optional — only if you don't use it for other things)"; then
        log_warn "Podman removal is manual — it requires sudo and package manager commands"
        log_info "To remove Podman on RHEL/Oracle Linux, run:"
        log_info "  sudo dnf remove -y podman podman-compose slirp4netns fuse-overlayfs"
        log_info "To clean up Podman data, run:"
        log_info "  rm -rf ~/.local/share/containers ~/.config/containers"
    fi
}

# =============================================================================
# PRINT SUMMARY
# =============================================================================
print_summary() {
    _log ""

    if [ "$MODE" = "dry-run" ]; then
        _log "${BOLD}${CYAN}═════════════════════════════════════════════════════════${NC}"
        _log "${BOLD}${CYAN}  DRY RUN COMPLETE — Nothing was actually deleted${NC}"
        _log "${BOLD}${CYAN}═════════════════════════════════════════════════════════${NC}"
    else
        _log "${BOLD}${GREEN}═════════════════════════════════════════════════════════${NC}"
        _log "${BOLD}${GREEN}  Cleanup Complete!${NC}"
        _log "${BOLD}${GREEN}═════════════════════════════════════════════════════════${NC}"
    fi
    _log ""

    if [ "$MODE" = "containers-only" ]; then
        log_info "Containers have been stopped and removed"
        log_info "Configuration files are preserved in case you want to restart"
        log_info "To restart: docker-compose up -d  (or  systemctl --user start jenkins-ansible)"
    else
        log_info "Jenkins + Ansible setup has been removed from this system"
        log_info "Setup files (setup.sh, docker-compose.yml, etc.) are still here if needed"
        log_info "Logs are saved to: ${LOG_FILE}"
    fi

    _log ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
main() {
    # Initialize log
    echo "Jenkins + Ansible Hub Cleanup — $(date)" > "$LOG_FILE"
    echo "Mode: ${MODE}" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"

    _log ""
    _log "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    _log "${BOLD}${MAGENTA}║  🧹  Jenkins + Ansible Hub Cleanup Utility               ║${NC}"
    _log "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    _log ""
    _log "  ${GRAY}Log file: ${LOG_FILE}${NC}"
    _log "  ${GRAY}Mode:     ${MODE}${NC}"
    _log "  ${GRAY}Started:  $(date)${NC}"
    _log ""

    if [ "$MODE" = "dry-run" ]; then
        _log "  ${YELLOW}${BOLD}DRY RUN MODE — Nothing will actually be deleted${NC}"
        _log ""
    fi

    parse_args "$@"
    detect_system

    if ! detect_runtime; then
        log_error "No container runtime found"
        exit 1
    fi

    detect_installations

    if [ "$CLEANUP_CONTAINERS" = false ] && [ "$CLEANUP_IMAGES" = false ] && [ "$CLEANUP_DIRECTORIES" = false ]; then
        log_warn "Nothing to clean up"
        log_info "Jenkins + Ansible setup is not found on this system"
        exit 0
    fi

    log_blank

    # Show what will be cleaned
    log_header "Items to Clean Up"
    [ "$CLEANUP_CONTAINERS" = true ] && _log "  • Containers"
    [ "$CLEANUP_IMAGES" = true ] && _log "  • Docker/Podman images"
    [ "$CLEANUP_DIRECTORIES" = true ] && _log "  • Configuration files (jenkins-config/, ssh-keys/, projects/, .env)"

    log_blank

    # Cleanup steps
    if [ "$RUNTIME" = "docker" ]; then
        cleanup_docker_containers
        cleanup_docker_images
    else
        cleanup_podman_services
        cleanup_podman_images
    fi

    if [ "$MODE" != "containers-only" ]; then
        cleanup_configuration_files
        cleanup_podman_installation
    fi

    print_summary
}

main "$@"
