# -*- mode: ruby -*-
# vi: set ft=ruby :

# ============================================================================
# Vagrant Configuration for Offline Jenkins-Ansible Testing
# ============================================================================
# CRITICAL: This VM starts COMPLETELY CLEAN with NO Podman pre-installed
#
# Purpose: Test that setup.sh --offline can:
#   1. Install Podman from the offline bundle
#   2. Load Jenkins image from bundle
#   3. Start Jenkins via systemd
#   4. All without internet access
#
# This validates the ACTUAL production deployment process
# ============================================================================

Vagrant.configure("2") do |config|

  # Box: Generic Oracle Linux 9
  # Clean image - no pre-installed packages beyond basics
  config.vm.box = "generic/oracle9"

  # ── Networking ──────────────────────────────────────────────────────────────

  config.vm.network "forwarded_port", guest: 22, host: 2222, auto_correct: true

  config.vm.network "private_network", type: "dhcp"

  # Port forwarding for Jenkins UI (accessible from Mac for testing)
  config.vm.network "forwarded_port", guest: 8080, host: 8080,
    protocol: "tcp",
    auto_correct: true

  # Port forwarding for Jenkins agents
  config.vm.network "forwarded_port", guest: 50000, host: 50000,
    protocol: "tcp",
    auto_correct: true

  # ── VM Resources ────────────────────────────────────────────────────────────
  config.vm.provider "virtualbox" do |vb|
    vb.name = "jenkins-ansible-offline-test"
    vb.memory = 4096
    vb.cpus = 2
    vb.gui = false
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
  end

  # ── Hostname ────────────────────────────────────────────────────────────────
  config.vm.hostname = "jenkins-ansible-offline"

  # ── Provisioning: MINIMAL (no Podman pre-install) ───────────────────────────
  # The setup.sh --offline script must handle everything offline
  config.vm.provision "shell", inline: <<-SHELL
    set -e

    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Provisioning Clean Oracle Linux 9                         ║"
    echo "║  (NO Podman - testing offline installation)                ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Update system
    echo "📦 Updating system packages..."
    sudo dnf update -y > /dev/null 2>&1 || true

    # Install ONLY basic tools - NOT Podman
    echo "📦 Installing basic tools (NOT Podman)..."
    sudo dnf install -y \
      git \
      curl \
      wget \
      vim \
      htop \
      tar \
      gzip \
      openssh-clients \
      > /dev/null 2>&1

    echo ""
    echo "✅ System provisioning complete"
    echo ""

    # Verify Podman is NOT installed
    if command -v podman &>/dev/null; then
      echo "❌ ERROR: Podman should NOT be pre-installed!"
      echo "   The setup.sh --offline script must install it offline"
      exit 1
    else
      echo "✅ Podman is NOT installed (as intended)"
    fi

    echo ""
    echo "🌐 Network status:"
    IP=$(hostname -I | awk '{print $1}')
    echo "  VM IP: $IP"
    echo ""

    echo "⚠️  Internet Access Test:"
    if timeout 2 ping -c 1 8.8.8.8 &>/dev/null; then
      echo "  ⚠️  WARNING: Internet is REACHABLE"
    else
      echo "  ✅ Internet is BLOCKED (expected for offline test)"
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "📋 NEXT STEPS:"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "From your Mac:"
    echo "  vagrant ssh"
    echo ""
    echo "Inside the VM:"
    echo "  cd /vagrant"
    echo "  ./setup.sh --offline"
    echo ""
    echo "This tests the ACTUAL offline deployment process:"
    echo "  1. Podman installation (offline)"
    echo "  2. Image loading from bundle"
    echo "  3. Jenkins startup via systemd"
    echo "  4. All without internet"
    echo ""
  SHELL

  # ── SSH Configuration ───────────────────────────────────────────────────────
  config.ssh.username = "vagrant"
  config.ssh.password = "vagrant"

  # ── Synced Folders ──────────────────────────────────────────────────────────
  config.vm.synced_folder ".", "/vagrant",
    type: "virtualbox",
    mount_options: ["dmode=755", "fmode=644"]

end
