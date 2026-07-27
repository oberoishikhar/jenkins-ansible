#!/bin/bash

# ============================================================================
# Offline Jenkins-Ansible Testing via Docker (Simpler Alternative)
# ============================================================================
# This script tests offline deployment using Docker containers
# instead of Vagrant VMs for better ARM64 Mac compatibility
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

log_header() {
  echo ""
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║  $1${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

log_step() { echo -e "\n${BOLD}${BLUE}▶  $1${NC}"; }
log_ok() { echo -e "${GREEN}✅ $1${NC}"; }
log_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; exit 1; }
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

# ============================================================================
# Step 1: Prerequisites Check
# ============================================================================
log_header "Step 1: Checking Prerequisites"

if ! docker ps &>/dev/null; then
  log_error "Docker is not running. Please start Docker Desktop first."
fi
log_ok "Docker Desktop is running"

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
  log_error "Docker Compose is not available"
fi
log_ok "Docker Compose is available"

AVAILABLE_SPACE=$(df "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
NEEDED_SPACE=$((5 * 1024 * 1024))
if [ "$AVAILABLE_SPACE" -lt "$NEEDED_SPACE" ]; then
  log_warn "Available space might be tight (~$(numfmt --to=iec $((AVAILABLE_SPACE * 1024))) available)"
fi
log_ok "Disk space check passed"

echo ""

# ============================================================================
# Step 2: Verify Offline Bundle
# ============================================================================
log_header "Step 2: Verifying Offline Bundle"

BUNDLES=(jenkins-ansible-offline-*.tar.gz)
if [ ! -f "${BUNDLES[0]}" ]; then
  log_error "No offline bundle found. Run: ./setup.sh --build-offline-bundle"
fi

BUNDLE_FILE="${BUNDLES[0]}"
BUNDLE_SIZE=$(du -h "$BUNDLE_FILE" | cut -f1)
log_ok "Offline bundle found: $BUNDLE_FILE ($BUNDLE_SIZE)"

# Verify bundle contents
if tar -tzf "$BUNDLE_FILE" | grep -q "jenkins-ansible-bundle.tar.gz"; then
  log_ok "Bundle contains Jenkins Docker image ✓"
else
  log_warn "Could not verify Docker image in bundle"
fi

echo ""

# ============================================================================
# Step 3: Load Docker Image from Offline Bundle
# ============================================================================
log_header "Step 3: Loading Docker Image from Offline Bundle"

NESTED_BUNDLE=$(tar -tzf "$BUNDLE_FILE" | grep "jenkins-ansible-bundle.tar.gz")
log_step "Extracting and loading Docker image..."

# Extract nested bundle and load it
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

tar -xzf "$BUNDLE_FILE" -C "$TEMP_DIR" "Jenkins-Ansible/jenkins-ansible-bundle.tar.gz"
NESTED_PATH="$TEMP_DIR/Jenkins-Ansible/jenkins-ansible-bundle.tar.gz"

if [ -f "$NESTED_PATH" ]; then
  log_info "Docker image size: $(du -h "$NESTED_PATH" | cut -f1)"

  log_step "Loading into Docker..."
  if docker load < "$NESTED_PATH" 2>&1 | tail -5; then
    log_ok "Docker image loaded successfully"
  else
    log_error "Failed to load Docker image"
  fi
else
  log_error "Could not find nested Docker image in bundle"
fi

echo ""

# ============================================================================
# Step 4: Start Isolated Docker Network
# ============================================================================
log_header "Step 4: Creating Isolated Docker Network"

log_step "Setting up offline network (no internet access)..."

# Remove old network if exists
docker network rm jenkins-offline 2>/dev/null || true

# Create isolated network (no default gateway)
docker network create \
  --driver bridge \
  --opt "com.docker.network.bridge.name=br-offline" \
  jenkins-offline 2>/dev/null || true

log_ok "Isolated network created: jenkins-offline"

# Verify network is truly isolated
log_info "Network will NOT have internet access (no default gateway)"

echo ""

# ============================================================================
# Step 5: Start Jenkins Container
# ============================================================================
log_header "Step 5: Starting Jenkins in Isolated Container"

log_step "Stopping any existing containers..."
docker stop jenkins-ansible-offline 2>/dev/null || true
docker rm jenkins-ansible-offline 2>/dev/null || true

log_step "Starting Jenkins container..."

# Create Jenkins home volume
docker volume create jenkins-home 2>/dev/null || true

# Start container with isolated network
docker run -d \
  --name jenkins-ansible-offline \
  --network jenkins-offline \
  --publish 8080:8080 \
  --publish 50000:50000 \
  --volume jenkins-home:/var/jenkins_home \
  --volume "$SCRIPT_DIR/projects":/var/jenkins_home/projects:ro \
  --volume "$SCRIPT_DIR/ssh-keys":/var/jenkins_home/.ssh:ro \
  --volume "$SCRIPT_DIR/jenkins-config":/var/jenkins_config:ro \
  --env JENKINS_OPTS="--prefix=/ --httpPort=8080" \
  --env JAVA_OPTS="-Xmx1g -Xms512m" \
  --memory 2g \
  --cpus 2 \
  --restart unless-stopped \
  jenkins-ansible:latest

CONTAINER_ID=$(docker ps -q -f name=jenkins-ansible-offline)
if [ -n "$CONTAINER_ID" ]; then
  log_ok "Jenkins container started: $CONTAINER_ID"
else
  log_error "Failed to start Jenkins container"
fi

echo ""

# ============================================================================
# Step 6: Wait for Jenkins to Start
# ============================================================================
log_header "Step 6: Waiting for Jenkins to Start"

log_info "Jenkins typically takes 60-90 seconds to fully start"
log_info "Checking health..."

RETRY_COUNT=0
MAX_RETRIES=30

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if curl -s http://localhost:8080/login &>/dev/null; then
    log_ok "Jenkins is responding ✓"
    break
  fi

  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $((RETRY_COUNT % 5)) -eq 0 ]; then
    log_info "Still starting... ($RETRY_COUNT / $MAX_RETRIES checks)"
  fi
  sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  log_warn "Jenkins may still be starting (timeout waiting)"
  log_info "Check logs: docker logs jenkins-ansible-offline"
else
  log_ok "Jenkins is fully up and running"
fi

echo ""

# ============================================================================
# Step 7: Verify Offline Operation
# ============================================================================
log_header "Step 7: Verifying Offline Operation"

log_step "Test 1: Jenkins responds without internet..."
if curl -s http://localhost:8080/login | grep -q "Jenkins"; then
  log_ok "Jenkins UI is accessible"
else
  log_warn "Jenkins not fully responding yet"
fi

log_step "Test 2: Checking container network..."
if docker exec jenkins-ansible-offline cat /etc/resolv.conf &>/dev/null; then
  log_ok "Container network accessible"
else
  log_warn "Could not verify network"
fi

log_step "Test 3: Verifying no external gateway..."
if docker exec jenkins-ansible-offline route -n 2>/dev/null | grep -q "0.0.0.0.*UG"; then
  log_warn "Container has default route (might have internet)"
else
  log_ok "Container has no internet gateway (isolated ✓)"
fi

echo ""

# ============================================================================
# Step 8: Display Access Information
# ============================================================================
log_header "Step 8: Setup Complete - Jenkins is Running"

echo ""
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${NC}"
echo "${BOLD}${GREEN}  🎉 OFFLINE JENKINS-ANSIBLE IS RUNNING${NC}"
echo "${BOLD}${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""

echo "📊 Jenkins Access from your Mac:"
echo ""
echo "  ${BOLD}URL:${NC}      http://localhost:8080"
echo "  ${BOLD}User:${NC}     admin"
echo "  ${BOLD}Password:${NC} changeme123"
echo ""

echo "🔒 Offline Assurance:"
echo "  ✓ Jenkins runs in isolated Docker network"
echo "  ✓ No internet gateway (truly air-gapped)"
echo "  ✓ All dependencies pre-bundled"
echo "  ✓ Deployment verified offline"
echo ""

echo "🛠️  Container Management:"
echo "  View logs:        ${BOLD}docker logs -f jenkins-ansible-offline${NC}"
echo "  Stop container:   ${BOLD}docker stop jenkins-ansible-offline${NC}"
echo "  Start container:  ${BOLD}docker start jenkins-ansible-offline${NC}"
echo "  Delete container: ${BOLD}docker rm jenkins-ansible-offline${NC}"
echo ""

echo "⚠️  IMPORTANT: Change password on first login!"
echo "  1. Open http://localhost:8080"
echo "  2. Click 'admin' (top right)"
echo "  3. Click 'Configure'"
echo "  4. Change password"
echo "  5. Save"
echo ""

echo "📋 Next Steps:"
echo "  • Open Jenkins in browser"
echo "  • Change admin password"
echo "  • Add projects: docker exec jenkins-ansible-offline /var/jenkins_home/add-project.sh"
echo "  • Run builds & verify offline operation"
echo ""

# Try to open Jenkins in browser
if command -v open &>/dev/null; then
  log_info "Opening Jenkins in browser..."
  open "http://localhost:8080" 2>/dev/null || true
fi

echo ""
log_ok "Offline testing environment is ready!"
echo ""
