# =============================================================================
# Jenkins + Ansible Deployment Hub
# =============================================================================
# Multi-architecture build: linux/amd64 (x86 servers) + linux/arm64 (Raspberry Pi)
#
# What's included:
#   - Jenkins LTS (latest stable)
#   - Ansible (via pip) — installed inside the container
#   - All required Jenkins plugins (pre-baked — no internet needed at runtime)
#   - SSH client tools (for Ansible to reach target hosts)
#   - Python 3 + pip (for Ansible)
#   - git, curl, jq, sshpass (utility tools)
# =============================================================================

# BUILDPLATFORM  = the platform where docker build runs (your laptop/server)
# TARGETPLATFORM = the platform this image will RUN on (amd64 or arm64)
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Jenkins official LTS image (Debian-based, supports multi-arch)
FROM jenkins/jenkins:lts-jdk21

# ─── Labels ───────────────────────────────────────────────────────────────────
LABEL maintainer="Your Team"
LABEL description="Jenkins + Ansible Deployment Hub — multi-project CI/CD"
LABEL version="1.0.0"

# ─── Environment Variables ────────────────────────────────────────────────────
# Skip the Jenkins setup wizard (we configure via JCasC)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
               -Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=86400 \
               -Xmx512m"

# Tell Jenkins where our Configuration as Code file lives
ENV CASC_JENKINS_CONFIG=/var/jenkins-config/jenkins.yaml

# ─── Switch to root to install system packages ────────────────────────────────
USER root

# ─── Install System Dependencies ─────────────────────────────────────────────
# We do this in a single RUN layer to keep image size down
RUN set -eux; \
    \
    # Update package lists
    apt-get update -qq; \
    \
    # Install required packages:
    #   python3 / python3-pip   → needed for Ansible
    #   openssh-client          → SSH connections to target hosts
    #   sshpass                 → password-based SSH (for initial setup only)
    #   git                     → fetch playbooks from git repos
    #   curl                    → health checks and API calls
    #   jq                      → parse JSON responses
    #   rsync                   → efficient file transfers
    #   dnsutils                → network troubleshooting (nslookup, dig)
    #   iputils-ping            → basic connectivity checks
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        python3-venv \
        openssh-client \
        sshpass \
        git \
        curl \
        jq \
        rsync \
        dnsutils \
        iputils-ping \
        vim-tiny \
    ; \
    \
    # Clean up apt cache to reduce image size
    rm -rf /var/lib/apt/lists/*; \
    apt-get clean

# ─── Install Ansible via pip ──────────────────────────────────────────────────
# Pin to a specific version for reproducibility
ARG ANSIBLE_VERSION="9.8.0"
# Note: --break-system-packages is required on Debian Trixie (Python 3.13+)
# due to PEP 668. This is safe inside a Docker container — there is no real
# system risk since the container is fully isolated.
RUN set -eux; \
    pip3 install --no-cache-dir --break-system-packages \
        "ansible==${ANSIBLE_VERSION}" \
        "paramiko" \
        "jinja2" \
        "PyYAML" \
        "netaddr" \
    ; \
    \
    # Verify Ansible installed correctly
    ansible --version; \
    ansible-playbook --version

# ─── Configure SSH for Ansible ────────────────────────────────────────────────
# Disable strict host key checking so Ansible can connect to new hosts
# (Operators should add known_hosts entries for production security)
RUN mkdir -p /var/jenkins_home/.ssh && \
    cat >> /etc/ssh/ssh_config << 'EOF'

# Jenkins-Ansible: added by Dockerfile
Host *
    StrictHostKeyChecking accept-new
    ServerAliveInterval 60
    ServerAliveCountMax 3
    ConnectTimeout 30
EOF

# ─── Install Jenkins Plugin Manager CLI ───────────────────────────────────────
# The official Jenkins image ships with jenkins-plugin-cli built in.
# We use that directly — no external JAR download needed.
# (The jenkins-plugin-cli binary is at /usr/local/bin/jenkins-plugin-cli)


# ─── Pre-Install Jenkins Plugins ─────────────────────────────────────────────
# This is the MAGIC step: all plugins are baked INTO the image at build time
# Result: Jenkins starts with all plugins ready — no internet needed at runtime
COPY jenkins-config/plugins.txt /usr/share/jenkins/plugins.txt

RUN set -eux; \
    echo "Installing Jenkins plugins (this takes ~3-5 minutes)..."; \
    jenkins-plugin-cli \
        --plugin-file /usr/share/jenkins/plugins.txt \
        --plugin-download-directory /usr/share/jenkins/ref/plugins/ \
        --view-security-warnings \
    ; \
    echo "Plugins installed successfully"

# ─── Copy Jenkins Configuration Files ────────────────────────────────────────
# These are baked into the image for defaults, but can be overridden by volume mount
RUN mkdir -p /var/jenkins-config
COPY jenkins-config/jenkins.yaml /var/jenkins-config/jenkins.yaml
COPY jenkins-config/seed-job.groovy /var/jenkins-config/seed-job.groovy

# ─── Set Correct Permissions ──────────────────────────────────────────────────
RUN chown -R jenkins:jenkins /var/jenkins_home/.ssh && \
    chmod 700 /var/jenkins_home/.ssh && \
    chown -R jenkins:jenkins /var/jenkins-config && \
    chmod 644 /var/jenkins-config/jenkins.yaml /var/jenkins-config/seed-job.groovy

# ─── Switch back to jenkins user (security best practice) ─────────────────────
USER jenkins

# ─── Expose Ports ─────────────────────────────────────────────────────────────
# 8080  → Jenkins Web UI
# 50000 → Jenkins agent connections (for build agents)
EXPOSE 8080 50000

# ─── Volumes ──────────────────────────────────────────────────────────────────
# /var/jenkins_home  → all Jenkins data (jobs, builds, credentials) — MUST be persisted
# /var/projects      → your Ansible playbooks (mounted from host ./projects/)
# /var/ssh-keys      → SSH private keys for deployments (mounted from host ./ssh-keys/)
# /var/jenkins-config → JCasC config (can be overridden by mounting ./jenkins-config/)
VOLUME ["/var/jenkins_home"]

# ─── Health Check ─────────────────────────────────────────────────────────────
# Docker will report the container as 'healthy' only when Jenkins is actually ready
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD curl -fsS http://localhost:8080/login > /dev/null || exit 1
