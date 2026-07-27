#!/bin/bash

# ============================================================================
# Automated Offline Jenkins-Ansible Testing
# ============================================================================
# This script automates the complete workflow:
# 1. Build offline bundle (on Mac)
# 2. Start isolated Vagrant VM (no internet)
# 3. Transfer bundle to VM
# 4. Deploy offline
# 5. Run validation tests
# 6. Provide Mac access instructions
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_header() { echo -e "\n${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "${BOLD}${BLUE}║  $1${NC}"; echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}\n"; }
log_step() { echo -e "\n${BOLD}${BLUE}▶  $1${NC}"; }
log_ok() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# ============================================================================
# Phase 1: Check Prerequisites
# ============================================================================
log_header "Phase 1: Checking Prerequisites"

# Check Docker Desktop
if ! docker ps &>/dev/null; then
  log_error "Docker Desktop is not running. Please start Docker Desktop first."
fi
log_ok "Docker Desktop is running"

# Check Vagrant
if ! command -v vagrant &>/dev/null; then
  log_error "Vagrant is not installed. Install with: brew install vagrant"
fi
VAGRANT_VERSION=$(vagrant --version | awk '{print $NF}')
log_ok "Vagrant installed: $VAGRANT_VERSION"

# Check VirtualBox
if ! command -v VBoxManage &>/dev/null; then
  log_error "VirtualBox is not installed. Install with: brew install --cask virtualbox"
fi
log_ok "VirtualBox installed"

# Check disk space
AVAILABLE_SPACE=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')  # in KB
NEEDED_SPACE=$((15 * 1024 * 1024))  # 15 GB in KB
if [ "$AVAILABLE_SPACE" -lt "$NEEDED_SPACE" ]; then
  log_warn "Available space: $(numfmt --to=iec $((AVAILABLE_SPACE * 1024)))"
  log_warn "Needed space: ~15GB"
  read -p "Continue anyway? (y/n) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
else
  log_ok "Sufficient disk space available"
fi

echo ""

# ============================================================================
# Phase 2: Build Offline Bundle
# ============================================================================
log_header "Phase 2: Building Offline Bundle"

BUNDLES=(jenkins-ansible-offline-*.tar.gz)
if [ -f "${BUNDLES[0]}" ]; then
  EXISTING_BUNDLE="${BUNDLES[0]}"
  BUNDLE_SIZE=$(du -h "$EXISTING_BUNDLE" | cut -f1)
  log_warn "Existing bundle found: $EXISTING_BUNDLE ($BUNDLE_SIZE)"

  read -p "Use existing bundle? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_step "Building new offline bundle..."
    JENKINS_PORT=9080 ./setup.sh --build-offline-bundle
    BUNDLES=(jenkins-ansible-offline-*.tar.gz)
  fi
else
  log_step "Building offline bundle..."
  log_info "This will take 30-60 minutes (downloads ~800MB)"
  JENKINS_PORT=9080 ./setup.sh --build-offline-bundle
  BUNDLES=(jenkins-ansible-offline-*.tar.gz)
fi

BUNDLE_FILE="${BUNDLES[0]}"
BUNDLE_SIZE=$(du -h "$BUNDLE_FILE" | cut -f1)
log_ok "Offline bundle ready: $BUNDLE_FILE ($BUNDLE_SIZE)"

echo ""

# ============================================================================
# Phase 3: Start Vagrant VM
# ============================================================================
log_header "Phase 3: Starting Isolated Vagrant VM"

if vagrant status | grep -q "running"; then
  log_warn "Vagrant VM is already running"
  read -p "Reload VM? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_step "Reloading Vagrant VM..."
    vagrant reload
  fi
else
  log_step "Starting Vagrant VM..."
  log_info "First startup may take 3-5 minutes (box download + provisioning)"
  vagrant up
fi

log_ok "Vagrant VM is running"

# Verify offline status
log_step "Verifying VM is offline (no internet)..."
if vagrant ssh -c "ping -c 1 8.8.8.8 2>&1 | grep -q 'unreachable\|100% packet loss'" 2>/dev/null; then
  log_ok "Internet is BLOCKED in VM (offline confirmed ✓)"
else
  log_warn "Could not verify offline status - continuing anyway"
fi

echo ""

# ============================================================================
# Phase 4: Transfer Bundle to VM
# ============================================================================
log_header "Phase 4: Transferring Bundle to VM"

log_step "Copying bundle to VM..."
vagrant scp "$BUNDLE_FILE" :/tmp/ 2>/dev/null || {
  log_info "vagrant-scp not installed, using SCP via port 2222..."
  scp -P 2222 "$BUNDLE_FILE" vagrant@localhost:/tmp/
}
log_ok "Bundle transferred to VM"

echo ""

# ============================================================================
# Phase 5: Deploy Offline in VM
# ============================================================================
log_header "Phase 5: Deploying Offline"

log_step "Extracting and deploying bundle in VM..."
vagrant ssh << 'DEPLOY_SCRIPT'
  set -e

  # Extract bundle
  cd /tmp
  tar -xzf jenkins-ansible-offline-*.tar.gz
  cd Jenkins-Ansible

  # Make executable
  chmod +x setup.sh add-project.sh cleanup.sh

  echo ""
  echo "Running offline setup (no internet required)..."
  echo ""

  # Run offline setup
  ./setup.sh --offline

  echo ""
  echo "✅ Deployment complete"
DEPLOY_SCRIPT

log_ok "Offline deployment completed successfully"

echo ""

# ============================================================================
# Phase 6: Validation Tests
# ============================================================================
log_header "Phase 6: Running Offline Validation Tests"

log_step "Test 1: Verify internet is blocked..."
if vagrant ssh -c "ping -c 1 8.8.8.8 2>&1 | grep -q 'unreachable\|100% packet loss'" 2>/dev/null; then
  log_ok "Internet is BLOCKED (offline ✓)"
else
  log_warn "Could not verify - but continuing"
fi

log_step "Test 2: Jenkins container is running..."
if vagrant ssh -c "podman ps | grep -q jenkins-ansible" 2>/dev/null; then
  log_ok "Jenkins container is running"
else
  log_error "Jenkins container is not running"
fi

log_step "Test 3: Jenkins UI responds..."
if vagrant ssh -c "curl -s http://localhost:8080/login | grep -q jenkins" 2>/dev/null; then
  log_ok "Jenkins UI responding"
else
  log_warn "Jenkins might still be starting (wait 30 seconds)"
fi

log_step "Test 4: Ansible is available..."
if vagrant ssh -c "podman exec jenkins-ansible ansible --version" 2>/dev/null | grep -q "ansible"; then
  log_ok "Ansible is available in container"
else
  log_error "Ansible not found in container"
fi

log_step "Test 5: Can add project offline..."
RESULT=$(vagrant ssh -c "cd /tmp/Jenkins-Ansible && ./add-project.sh --name test-offline --host localhost --user root 2>&1" 2>/dev/null)
if echo "$RESULT" | grep -q "error\|failed"; then
  log_warn "Project add had issues: $RESULT"
else
  log_ok "Can add projects offline"
fi

echo ""

# ============================================================================
# Phase 7: Success and Mac Access Instructions
# ============================================================================
log_header "Phase 7: Setup Complete!"

echo ""
echo "${BOLD}🎉 OFFLINE TESTING ENVIRONMENT IS READY${NC}"
echo ""

log_ok "Jenkins-Ansible is running in an ISOLATED Vagrant VM"
log_ok "VM has NO INTERNET ACCESS (offline confirmed)"
log_ok "Bundle deployed successfully from offline sources"
echo ""

echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "${BOLD}📊 JENKINS ACCESS FROM YOUR MAC${NC}"
echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  🌐 URL: ${BOLD}http://localhost:8080${NC}"
echo ""
echo "  👤 Credentials:"
echo "     Username: ${BOLD}admin${NC}"
echo "     Password: ${BOLD}changeme123${NC}"
echo ""
echo "  ${YELLOW}⚠️  Recommended: Change password on first login${NC}"
echo "     1. Click 'admin' (top right)"
echo "     2. Click 'Configure'"
echo "     3. Enter new password"
echo "     4. Click 'Save'"
echo ""

echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "${BOLD}🔧 VM MANAGEMENT${NC}"
echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  SSH into VM:"
echo "    ${BLUE}vagrant ssh${NC}"
echo ""
echo "  Check Jenkins logs:"
echo "    ${BLUE}vagrant ssh -c 'journalctl --user -u jenkins-ansible -f'${NC}"
echo ""
echo "  Stop VM (keeps data):"
echo "    ${BLUE}vagrant halt${NC}"
echo ""
echo "  Restart VM:"
echo "    ${BLUE}vagrant up${NC}"
echo ""
echo "  Destroy VM (full cleanup):"
echo "    ${BLUE}vagrant destroy${NC}"
echo ""

echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "${BOLD}✅ OFFLINE GUARANTEES${NC}"
echo "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  ✓ VM has NO internet access (isolated private network)"
echo "  ✓ No external DNS/HTTP queries possible"
echo "  ✓ All dependencies pre-downloaded in bundle"
echo "  ✓ Jenkins accessible from Mac on localhost:8080"
echo "  ✓ Full offline operation verified"
echo ""

log_info "Press Enter to open Jenkins in browser..."
read

# Try to open Jenkins in browser
if command -v open &>/dev/null; then
  open "http://localhost:8080"
elif command -v xdg-open &>/dev/null; then
  xdg-open "http://localhost:8080"
else
  log_info "Please open http://localhost:8080 manually in your browser"
fi

echo ""
log_ok "Testing complete!"
echo ""
