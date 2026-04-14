#!/usr/bin/env bash
# 10-packages — runtime dependencies.
#
# Installs: apt essentials, Node 22 LTS, rclone, Bitwarden CLI, Playwright
# system deps. Each sub-step has its own "already installed?" check so the
# whole step is cheap on re-run.
#
# Versions are pinned at the top so an upgrade is one-file-one-diff.

source "$CODECLAW_ROOT/lib/common.sh"

MARKER="10-packages.v1"   # bump suffix to force full re-run on version bumps

if already_done "$MARKER"; then
  log "packages already installed (marker: $MARKER)"
  exit 0
fi

# ============================================================================
# Pinned versions
# ============================================================================
NODE_MAJOR=22
# Bitwarden CLI: installed via npm rather than the github release zip.
# Reason: Bitwarden does not publish a linux-arm64 native binary (only
# linux-x64, macos, windows). OCI Ampere instances are aarch64. npm
# installs the pure-JS CLI which runs under Node on any arch, and npm's
# package-lock integrity hashes replace the SHA-pinning ceremony.
BW_VERSION="2024.8.2"
BW_NPM_PKG="@bitwarden/cli@${BW_VERSION}"

# ============================================================================
# 1. apt essentials
# ============================================================================
wait_for_apt_lock

APT_PACKAGES=(
  # General
  unzip
  fail2ban
  jq
  # Playwright system deps for Chromium (Ubuntu 24.04 ARM64)
  libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2
  libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3
  libxrandr2 libgbm1 libasound2t64 libpango-1.0-0 libcairo2
  fonts-liberation
)
log "apt installing: ${APT_PACKAGES[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"

# ============================================================================
# 2. Node 22 LTS from NodeSource
# ============================================================================
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -q "^v${NODE_MAJOR}\."; then
  log "installing Node ${NODE_MAJOR}.x from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  wait_for_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
else
  log "Node already at $(node --version)"
fi

# Let globally-installed node modules be importable by agents.
grep -q '^NODE_PATH=' /etc/environment \
  || echo 'NODE_PATH=/usr/lib/node_modules' >> /etc/environment

# ============================================================================
# 3. rclone (for OCI Object Storage via S3-compatible endpoint)
# ============================================================================
if ! command -v rclone >/dev/null 2>&1; then
  log "installing rclone via official installer"
  curl -fsSL https://rclone.org/install.sh | bash
else
  log "rclone already at $(rclone --version | head -1)"
fi

# ============================================================================
# 4. Bitwarden CLI (npm — no native arm64 binary from upstream)
# ============================================================================
if ! command -v bw >/dev/null 2>&1 || ! bw --version | grep -q "^${BW_VERSION}"; then
  log "installing ${BW_NPM_PKG}"
  npm install -g "$BW_NPM_PKG"
  log "Bitwarden CLI installed: $(bw --version)"
else
  log "Bitwarden CLI already at $(bw --version)"
fi

# ============================================================================
# 5. Playwright + Chromium
# ============================================================================
# Install playwright globally as root (so the `npx playwright` shim is on PATH
# for all users), then download the Chromium cache as the openclaw user so it
# lands in /home/openclaw/.cache/ms-playwright.
if ! command -v playwright >/dev/null 2>&1; then
  log "npm install -g playwright"
  npm install -g playwright
fi

# openclaw user might not exist yet — created in 20-workspace. Defer Chromium
# download to the point where the user exists. The Playwright binary is
# already on PATH, so a later step can invoke `sudo -u openclaw npx playwright
# install chromium`. We do that in 20-workspace, not here.

mark_done "$MARKER"
log "packages OK"

# ============================================================================
# Notes
# ----------------------------------------------------------------------------
# Bitwarden version bumps: edit BW_VERSION and re-run install.sh. npm picks
# up the new version immediately (npm install -g is idempotent). Bump the
# step marker suffix if you want to force the whole 10-packages step to
# re-run — pure BW bumps don't require it.
# ============================================================================
