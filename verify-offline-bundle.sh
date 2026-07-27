#!/usr/bin/env bash
# =============================================================================
# verify-offline-bundle.sh
# =============================================================================
# Verification script for offline bundle deployments
#
# This script runs ON THE TARGET MACHINE (air-gapped) to:
# 1. Verify bundle integrity (checksums)
# 2. Check system requirements
# 3. Validate all components before deployment
#
# USAGE:
#   ./verify-offline-bundle.sh [--bundle-dir ./offline-bundle-*]
#
# =============================================================================

set -euo pipefail

BUNDLE_DIR="${1:-.}"
TIMESTAMP=$(date +%s)
REPORT_FILE="bundle-verification-${TIMESTAMP}.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS=0
WARN=0
FAIL=0

# Logging functions
log()       { echo -e "${BLUE}➜${NC} $*" | tee -a "$REPORT_FILE"; }
log_ok()    { echo -e "${GREEN}✓${NC} $*" | tee -a "$REPORT_FILE"; ((PASS++)); }
log_warn()  { echo -e "${YELLOW}⚠${NC} $*" | tee -a "$REPORT_FILE"; ((WARN++)); }
log_error() { echo -e "${RED}✗${NC} $*" | tee -a "$REPORT_FILE"; ((FAIL++)); }
log_step()  { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$REPORT_FILE"; echo -e "${BOLD}$*${NC}" | tee -a "$REPORT_FILE"; echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$REPORT_FILE"; }

# =============================================================================
# VALIDATION CHECKS
# =============================================================================

validate_bundle_location() {
    log_step "Validating Bundle Location"

    if [ ! -d "$BUNDLE_DIR" ]; then
        log_error "Bundle directory not found: $BUNDLE_DIR"
        exit 1
    fi
    log_ok "Bundle directory exists: $BUNDLE_DIR"

    # Check manifest
    if [ -f "$BUNDLE_DIR/MANIFEST.md" ]; then
        log_ok "Manifest found"
    else
        log_warn "Manifest not found (MANIFEST.md) — bundle may be incomplete"
    fi
}

validate_os() {
    log_step "Validating Target OS"

    local os_id
    os_id=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    local os_version
    os_version=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    local arch
    arch=$(uname -m)

    # Read bundle metadata
    local bundle_os=""
    local bundle_arch=""
    if [ -f "$BUNDLE_DIR/MANIFEST.md" ]; then
        bundle_os=$(grep "^- \*\*Build OS:\*\*" "$BUNDLE_DIR/MANIFEST.md" | head -1 | sed 's/.*OS: \([^ ]*\).*/\1/')
        bundle_arch=$(grep "^- \*\*Arch:\*\*" "$BUNDLE_DIR/MANIFEST.md" | head -1 | sed 's/.*Arch: \([^ ]*\).*/\1/')
    fi

    log "Detected OS: ${os_id} ${os_version}"
    log "Detected Arch: ${arch}"

    if [[ "$os_id" != "ol" && "$os_id" != "rhel" ]]; then
        log_error "Unsupported OS: ${os_id}"
        log_error "  Bundle requires: Oracle Linux or RHEL"
        exit 1
    fi
    log_ok "OS is supported: ${os_id} ${os_version}"

    # Warn on OS mismatch
    if [ -n "$bundle_os" ] && [ "$bundle_os" != "$os_id" ]; then
        log_warn "OS mismatch: Bundle built on ${bundle_os}, target is ${os_id}"
        log_warn "  RPMs may not be compatible — proceed with caution"
    else
        log_ok "OS matches: ${os_id}"
    fi

    # Warn on arch mismatch
    if [ -n "$bundle_arch" ] && [ "$bundle_arch" != "$arch" ]; then
        log_error "Architecture mismatch: Bundle is ${bundle_arch}, target is ${arch}"
        log_error "  This will NOT work — rebuild bundle on correct arch"
        exit 1
    else
        log_ok "Architecture matches: ${arch}"
    fi
}

validate_disk_space() {
    log_step "Validating Disk Space"

    local bundle_size
    bundle_size=$(du -sh "$BUNDLE_DIR" 2>/dev/null | cut -f1 | sed 's/G//' | sed 's/M//')
    local avail_gb
    avail_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//')

    log "Bundle size: ${bundle_size}"
    log "Available space: ${avail_gb}GB"

    if [ "${avail_gb}" -lt 15 ]; then
        log_error "Insufficient space: need 15GB, have ${avail_gb}GB"
        exit 1
    fi
    log_ok "Sufficient disk space"
}

validate_checksums() {
    log_step "Validating File Checksums (Integrity Check)"

    if [ ! -f "$BUNDLE_DIR/CHECKSUMS.sha256" ]; then
        log_warn "Checksums file not found (CHECKSUMS.sha256)"
        log_warn "  Skipping integrity verification"
        return
    fi

    log "Verifying $(wc -l < "$BUNDLE_DIR/CHECKSUMS.sha256") files..."

    cd "$BUNDLE_DIR"
    if sha256sum -c CHECKSUMS.sha256 > /dev/null 2>&1; then
        log_ok "All files verified (checksums match)"
    else
        log_error "Checksum verification FAILED"
        log_error "  Bundle may be corrupted or incomplete"
        sha256sum -c CHECKSUMS.sha256 | grep FAILED || true
        exit 1
    fi
    cd - > /dev/null
}

validate_components() {
    log_step "Validating Bundle Components"

    # Check images
    local image_count
    image_count=$(find "$BUNDLE_DIR/images" -name "*.tar.gz" 2>/dev/null | wc -l)
    if [ "$image_count" -gt 0 ]; then
        log_ok "Container images: ${image_count} found"
        for img in "$BUNDLE_DIR/images"/*.tar.gz; do
            local size
            size=$(du -sh "$img" | cut -f1)
            log "  • $(basename "$img") (${size})"
        done
    else
        log_warn "No container images found"
    fi

    # Check RPMs
    local rpm_count
    rpm_count=$(find "$BUNDLE_DIR/rpms" -name "*.rpm" 2>/dev/null | wc -l)
    if [ "$rpm_count" -gt 0 ]; then
        log_ok "RPM packages: ${rpm_count} found"
        log "  Key packages:"
        for rpm in podman slirp4netns fuse-overlayfs container-selinux; do
            if find "$BUNDLE_DIR/rpms" -name "${rpm}*.rpm" | grep -q .; then
                log "  ✓ ${rpm}"
            else
                log_warn "  ? ${rpm} (may need to be installed separately)"
            fi
        done
    else
        log_warn "No RPM packages found"
    fi

    # Check wheels
    local wheel_count
    wheel_count=$(find "$BUNDLE_DIR/wheels" -name "*.whl" 2>/dev/null | wc -l)
    if [ "$wheel_count" -gt 0 ]; then
        log_ok "Python wheels: ${wheel_count} found"
    else
        log_warn "No Python wheels found"
    fi

    # Check setup scripts
    if [ -f "$BUNDLE_DIR/scripts/setup.sh" ]; then
        log_ok "Setup script found"
    else
        log_warn "Setup script not found (setup.sh)"
    fi
}

check_dependencies() {
    log_step "Checking For Required Tools"

    local missing=0

    for cmd in tar gzip; do
        if command -v "$cmd" &>/dev/null; then
            log_ok "$cmd: available"
        else
            log_error "$cmd: NOT FOUND"
            ((missing++))
        fi
    done

    # Optional but recommended
    for cmd in podman docker sha256sum; do
        if command -v "$cmd" &>/dev/null; then
            log_ok "$cmd: available"
        else
            log_warn "$cmd: NOT FOUND (will be needed later)"
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log_error "Missing required tools"
        exit 1
    fi
}

check_permissions() {
    log_step "Checking Permissions"

    # Check if bundle is readable
    if [ -r "$BUNDLE_DIR" ]; then
        log_ok "Bundle directory: readable"
    else
        log_error "Bundle directory: NOT readable"
        exit 1
    fi

    # Check if we can write to current directory (for logs)
    if [ -w "." ]; then
        log_ok "Current directory: writable"
    else
        log_warn "Current directory: NOT writable (verification report may not save)"
    fi

    # Check for sudo (needed for Podman install)
    if sudo -n true 2>/dev/null; then
        log_ok "Sudo access: available (no password needed)"
    else
        log_warn "Sudo access: password may be required during installation"
    fi
}

# =============================================================================
# READINESS CHECK
# =============================================================================

check_readiness() {
    log_step "Deployment Readiness Assessment"

    if [ "$FAIL" -eq 0 ]; then
        echo -e "\n${BOLD}${GREEN}✅ Bundle Verification PASSED${NC}"
        echo -e "   Status: Ready for deployment"
        echo -e "   Next: Run \`./setup.sh --offline\` to deploy"
    else
        echo -e "\n${BOLD}${RED}❌ Bundle Verification FAILED${NC}"
        echo -e "   Status: Cannot proceed with deployment"
        echo -e "   Failures: $FAIL"
        echo -e "   Please fix issues above and try again"
    fi

    echo -e "\n${BOLD}Summary${NC}"
    echo "   ✓ Passed:  $PASS"
    echo "   ⚠ Warning: $WARN"
    echo "   ✗ Failed:  $FAIL"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Offline Bundle Verification                              ║"
    echo "║  (Target Machine)                                         ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "Report: $REPORT_FILE"
    echo ""

    validate_bundle_location
    validate_os
    validate_disk_space
    validate_checksums
    validate_components
    check_dependencies
    check_permissions
    check_readiness

    echo ""
    echo "Full report saved to: $REPORT_FILE"
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
