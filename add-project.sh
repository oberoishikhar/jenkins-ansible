#!/usr/bin/env bash
# =============================================================================
# add-project.sh — Add a New Project to the Jenkins + Ansible Hub
# =============================================================================
#
# USAGE:
#   ./add-project.sh --name myapp --host 192.168.1.100 --user deployuser
#   ./add-project.sh --name myapp --host 192.168.1.100 --user deployuser --key ./ssh-keys/myapp.pem
#   ./add-project.sh --list
#   ./add-project.sh --help
#
# WHAT THIS DOES:
#   1. Creates the project folder structure in ./projects/<name>/
#   2. Fills in the host/user in the inventory file
#   3. Copies the SSH key to ./ssh-keys/ if provided
#   4. Registers the SSH key in Jenkins credentials
#   5. Triggers the seed job to create the Jenkins pipeline
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()    { echo -e "  ${GREEN}✅ $1${NC}"; }
log_warn()  { echo -e "  ${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "  ${RED}❌ $1${NC}"; }
log_info()  { echo -e "  ${CYAN}ℹ️  $1${NC}"; }
log_doing() { echo -e "  ${BOLD}🔄 $1${NC}"; }
log_step()  { echo -e "\n${BLUE}${BOLD}▶  $1${NC}"; }

# ─── Load .env if it exists ──────────────────────────────────────────────────
[ -f "${SCRIPT_DIR}/.env" ] && { set -o allexport; source "${SCRIPT_DIR}/.env"; set +o allexport; }
JENKINS_PORT="${JENKINS_PORT:-8080}"
JENKINS_ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-changeme123}"
JENKINS_URL="http://localhost:${JENKINS_PORT}"

# ─── Arguments ───────────────────────────────────────────────────────────────
PROJECT_NAME=""
HOST=""
SSH_USER=""
SSH_KEY_PATH=""
DISPLAY_NAME=""
DESCRIPTION=""

print_help() {
    cat << 'HELP'

Usage:
  ./add-project.sh --name <project-name> --host <ip-or-hostname> --user <ssh-user> [options]

Required:
  --name <name>       Short project name (letters, numbers, hyphens only, e.g. myapp)
  --host <host>       Target host IP or hostname (e.g. 192.168.1.100)
  --user <user>       SSH username on the target host (e.g. deployuser)

Optional:
  --key  <path>       Path to SSH private key file (e.g. ./ssh-keys/myapp.pem)
                      If not provided, a new key pair will be generated
  --display <name>    Human-friendly project name (default: project name)
  --description <txt> Short description of the project
  --list              List all existing projects
  --help, -h          Show this help

Examples:
  # Add project with existing SSH key:
  ./add-project.sh --name webapp --host 192.168.1.50 --user deploy --key ./ssh-keys/webapp.pem

  # Add project, auto-generate SSH key:
  ./add-project.sh --name webapp --host 192.168.1.50 --user deploy

  # List all projects:
  ./add-project.sh --list

HELP
}

list_projects() {
    echo ""
    echo -e "${BOLD}Existing Projects:${NC}"
    echo ""
    local found=0
    for dir in "${SCRIPT_DIR}/projects"/*/; do
        local name
        name=$(basename "$dir")
        [ "$name" = "_template" ] && continue
        [ ! -d "$dir" ] && continue
        found=$((found + 1))

        local display="$name"
        local host="(unknown)"
        if [ -f "${dir}/project.yaml" ]; then
            display=$(grep "display_name:" "${dir}/project.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' || echo "$name")
        fi
        if [ -f "${dir}/inventory/hosts.ini" ]; then
            host=$(grep -v '^\[' "${dir}/inventory/hosts.ini" 2>/dev/null | grep -v '^$' | head -1 | awk '{print $1}' || echo "(unknown)")
        fi
        echo -e "  ${GREEN}•${NC} ${BOLD}${name}${NC} (${display}) → ${host}"
    done

    if [ $found -eq 0 ]; then
        echo -e "  ${YELLOW}No projects found yet.${NC}"
        echo -e "  Add one: ./add-project.sh --name myapp --host 192.168.x.x --user deployuser"
    fi
    echo ""
}

parse_args() {
    if [ $# -eq 0 ]; then
        print_help
        exit 0
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)         PROJECT_NAME="$2"; shift;;
            --host)         HOST="$2"; shift;;
            --user)         SSH_USER="$2"; shift;;
            --key)          SSH_KEY_PATH="$2"; shift;;
            --display)      DISPLAY_NAME="$2"; shift;;
            --description)  DESCRIPTION="$2"; shift;;
            --list)         list_projects; exit 0;;
            --help|-h)      print_help; exit 0;;
            *)              log_error "Unknown option: $1"; print_help; exit 1;;
        esac
        shift
    done
}

validate_args() {
    local errors=()

    [ -z "$PROJECT_NAME" ] && errors+=("--name is required")
    [ -z "$HOST" ]         && errors+=("--host is required")
    [ -z "$SSH_USER" ]     && errors+=("--user is required")

    # Validate project name (letters, numbers, hyphens only)
    if [[ -n "$PROJECT_NAME" ]] && ! [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
        errors+=("Project name must contain only letters, numbers, and hyphens (no spaces)")
    fi

    # Check project doesn't already exist
    if [ -d "${SCRIPT_DIR}/projects/${PROJECT_NAME}" ]; then
        errors+=("Project '${PROJECT_NAME}' already exists. Use a different name or delete: projects/${PROJECT_NAME}/")
    fi

    # Validate SSH key if provided
    if [ -n "$SSH_KEY_PATH" ] && [ ! -f "$SSH_KEY_PATH" ]; then
        errors+=("SSH key file not found: ${SSH_KEY_PATH}")
    fi

    if [ ${#errors[@]} -gt 0 ]; then
        echo ""
        log_error "Validation failed:"
        for err in "${errors[@]}"; do
            log_info "  • ${err}"
        done
        echo ""
        exit 1
    fi

    # Set defaults
    DISPLAY_NAME="${DISPLAY_NAME:-${PROJECT_NAME}}"
    DESCRIPTION="${DESCRIPTION:-Deployment pipeline for ${PROJECT_NAME}}"
}

create_project_structure() {
    log_step "Creating project structure for: ${PROJECT_NAME}"

    local project_dir="${SCRIPT_DIR}/projects/${PROJECT_NAME}"
    local template_dir="${SCRIPT_DIR}/projects/_template"

    if [ -d "$template_dir" ]; then
        log_doing "Copying from template..."
        cp -r "$template_dir" "$project_dir"
    else
        log_doing "Creating from scratch (template not found)..."
        mkdir -p "${project_dir}/inventory"
        mkdir -p "${project_dir}/playbooks"
    fi

    log_ok "Directory created: projects/${PROJECT_NAME}/"
}

configure_project() {
    log_step "Configuring project: ${PROJECT_NAME}"

    local project_dir="${SCRIPT_DIR}/projects/${PROJECT_NAME}"
    local credential_id="${PROJECT_NAME}-ssh-key"

    # ─── Write project.yaml ──────────────────────────────────────────────────
    cat > "${project_dir}/project.yaml" << EOF
# =============================================================================
# Project Configuration: ${PROJECT_NAME}
# Generated by add-project.sh on $(date)
# =============================================================================

# Short identifier — must match the folder name exactly
name: "${PROJECT_NAME}"

# Human-friendly name shown in Jenkins
display_name: "${DISPLAY_NAME}"

# Description shown in Jenkins pipeline
description: "${DESCRIPTION}"

# Jenkins Credentials ID for the SSH key (set by add-project.sh)
ssh_credential_id: "${credential_id}"

# Default action when pipeline runs
default_action: deploy

# Git repository for playbooks (optional — leave empty to use local folder)
# When set, Jenkins will git pull before running Ansible
use_git: false
git_repo: ""
git_branch: "main"

# Target host information (reference — actual hosts are in inventory/hosts.ini)
default_host: "${HOST}"
default_user: "${SSH_USER}"
EOF

    log_ok "Created: projects/${PROJECT_NAME}/project.yaml"

    # ─── Write inventory/hosts.ini ───────────────────────────────────────────
    cat > "${project_dir}/inventory/hosts.ini" << EOF
# =============================================================================
# Ansible Inventory — ${PROJECT_NAME}
# =============================================================================
# Add your target hosts here.
# Format: hostname_or_ip  ansible_user=username  [ansible_port=22]
#
# Multiple hosts:
#   192.168.1.101 ansible_user=${SSH_USER}
#   192.168.1.102 ansible_user=${SSH_USER}
#
# With custom SSH port:
#   myserver.local ansible_user=${SSH_USER} ansible_port=2222
# =============================================================================

[deploy_targets]
${HOST} ansible_user=${SSH_USER}

[deploy_targets:vars]
# Connection settings
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30'

# Uncomment below to use sudo on target machine (needed for privileged tasks)
# ansible_become=yes
# ansible_become_method=sudo
EOF

    log_ok "Created: projects/${PROJECT_NAME}/inventory/hosts.ini"

    # ─── Write Jenkinsfile if template didn't have one ───────────────────────
    if [ ! -f "${project_dir}/Jenkinsfile" ]; then
        cat > "${project_dir}/Jenkinsfile" << 'EOF'
// This Jenkinsfile is auto-generated by the seed job from seed-job.groovy
// Edit the seed-job.groovy to change the pipeline structure for all projects
// Or override here for project-specific customization
EOF
        log_ok "Created: projects/${PROJECT_NAME}/Jenkinsfile"
    fi
}

handle_ssh_key() {
    log_step "Setting up SSH key..."

    local key_dest="${SCRIPT_DIR}/ssh-keys/${PROJECT_NAME}.pem"
    local credential_id="${PROJECT_NAME}-ssh-key"

    if [ -n "$SSH_KEY_PATH" ]; then
        # User supplied a key — copy it
        log_doing "Copying SSH key to ssh-keys/${PROJECT_NAME}.pem..."
        cp "$SSH_KEY_PATH" "$key_dest"
        chmod 600 "$key_dest"
        log_ok "SSH key copied: ssh-keys/${PROJECT_NAME}.pem"

    else
        # Generate a new key pair
        log_doing "Generating new SSH key pair for ${PROJECT_NAME}..."
        log_warn "A new key pair will be created. You'll need to add the PUBLIC key to target hosts."

        ssh-keygen -t ed25519 \
            -C "jenkins-ansible-${PROJECT_NAME}" \
            -f "$key_dest" \
            -N "" \
            -q

        chmod 600 "$key_dest"
        chmod 644 "${key_dest}.pub"

        log_ok "Private key: ssh-keys/${PROJECT_NAME}.pem"
        log_ok "Public key:  ssh-keys/${PROJECT_NAME}.pem.pub"
        echo ""
        log_warn "IMPORTANT: Copy the public key to your target host:"
        echo ""
        echo -e "  ${CYAN}ssh-copy-id -i ssh-keys/${PROJECT_NAME}.pem.pub ${SSH_USER}@${HOST}${NC}"
        echo ""
        echo -e "  Or manually add this to ${SSH_USER}@${HOST}:~/.ssh/authorized_keys:"
        cat "${key_dest}.pub"
        echo ""
    fi

    # Register key in Jenkins credentials
    register_credential_in_jenkins "$key_dest" "$credential_id"
}

register_credential_in_jenkins() {
    local key_file=$1
    local credential_id=$2

    log_doing "Registering SSH key in Jenkins credentials..."

    # Check Jenkins is running
    if ! curl -sf --max-time 5 "${JENKINS_URL}/login" > /dev/null 2>&1; then
        log_warn "Jenkins is not running. SSH key saved to ssh-keys/ but NOT registered in Jenkins."
        log_info "Start Jenkins first, then re-run: ./add-project.sh --name ${PROJECT_NAME} --host ${HOST} --user ${SSH_USER} --key ssh-keys/${PROJECT_NAME}.pem"
        return 0
    fi

    # Get CSRF crumb
    local crumb=""
    crumb=$(curl -sf --max-time 10 \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crumb',''))" 2>/dev/null || echo "")

    # Read private key content
    local key_content
    key_content=$(cat "$key_file")

    # Create credential via Jenkins API
    local credential_json
    credential_json=$(cat << JSONEOF
{
  "": "0",
  "credentials": {
    "scope": "GLOBAL",
    "id": "${credential_id}",
    "description": "SSH key for project: ${PROJECT_NAME} (${HOST})",
    "username": "${SSH_USER}",
    "privateKeySource": {
      "stapler-class": "com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey\$DirectEntryPrivateKeySource",
      "privateKey": $(python3 -c "import json,sys; print(json.dumps(open('${key_file}').read()))")
    },
    "stapler-class": "com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey",
    "\$class": "com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey"
  }
}
JSONEOF
)

    local curl_args=(-sf --max-time 15
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}"
        -H "Content-Type: application/x-www-form-urlencoded")
    [ -n "$crumb" ] && curl_args+=(-H "Jenkins-Crumb:${crumb}")

    if curl "${curl_args[@]}" \
        "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
        --data-urlencode "json=${credential_json}" \
        > /dev/null 2>&1; then
        log_ok "SSH key registered in Jenkins (ID: ${credential_id})"
    else
        log_warn "Could not auto-register credential in Jenkins"
        log_info "Register manually:"
        log_info "  Jenkins → Manage Jenkins → Credentials → System → Global → Add Credentials"
        log_info "  Type: SSH Username with private key"
        log_info "  ID: ${credential_id}"
        log_info "  Username: ${SSH_USER}"
        log_info "  Key: paste contents of ssh-keys/${PROJECT_NAME}.pem"
    fi
}

trigger_seed_job() {
    log_step "Updating Jenkins with new project..."

    # Check Jenkins is running
    if ! curl -sf --max-time 5 "${JENKINS_URL}/login" > /dev/null 2>&1; then
        log_warn "Jenkins is not running — skipping seed job trigger"
        log_info "Run the seed job manually after starting Jenkins:"
        log_info "  Jenkins → _Admin → Seed-Job → Build Now"
        return 0
    fi

    local crumb=""
    crumb=$(curl -sf --max-time 10 \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('crumb',''))" 2>/dev/null || echo "")

    local curl_opts=(-sf --max-time 10 \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        -X POST)
    [ -n "$crumb" ] && curl_opts+=(-H "Jenkins-Crumb:${crumb}")

    if curl "${curl_opts[@]}" "${JENKINS_URL}/job/_Admin/job/Seed-Job/build" > /dev/null 2>&1; then
        log_ok "Seed job triggered — check Jenkins in ~30 seconds"
    else
        log_warn "Could not trigger seed job automatically"
        log_info "Trigger manually: Jenkins → _Admin → Seed-Job → Build Now"
    fi
}

print_next_steps() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║  ✅  Project '${PROJECT_NAME}' has been added!               ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Project files:${NC}    projects/${PROJECT_NAME}/"
    echo -e "  ${BOLD}SSH key:${NC}           ssh-keys/${PROJECT_NAME}.pem"
    echo -e "  ${BOLD}Target host:${NC}       ${HOST} (user: ${SSH_USER})"
    echo ""
    echo -e "  ${BOLD}Checklist before running the pipeline:${NC}"

    if [ -z "$SSH_KEY_PATH" ]; then
        echo -e "  ${YELLOW}☐${NC} Copy public key to target host:"
        echo -e "    ${CYAN}ssh-copy-id -i ssh-keys/${PROJECT_NAME}.pem.pub ${SSH_USER}@${HOST}${NC}"
    else
        echo -e "  ${GREEN}☑${NC} SSH key provided"
    fi

    echo -e "  ${YELLOW}☐${NC} Edit the deploy playbook:"
    echo -e "    ${CYAN}open projects/${PROJECT_NAME}/playbooks/deploy.yml${NC}"
    echo -e "  ${YELLOW}☐${NC} Open Jenkins and run the pipeline:"
    echo -e "    ${CYAN}${JENKINS_URL}/job/${PROJECT_NAME}/${NC}"
    echo ""
    echo -e "  ${BOLD}To add another project:${NC}"
    echo -e "  ${CYAN}./add-project.sh --name project2 --host 192.168.1.101 --user deployuser${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  ➕  Add Project — Ansible Hub   ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════╝${NC}"

    parse_args "$@"
    validate_args
    create_project_structure
    configure_project
    handle_ssh_key
    trigger_seed_job
    print_next_steps
}

main "$@"
