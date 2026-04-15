#!/usr/bin/env bash
# 20-workspace — openclaw user + /data layout + symlinks + Chromium cache.
#
# Invariant: every durable artifact lives on /data so it survives instance
# recreation. The /home/openclaw directory holds only symlinks + caches that
# can be recreated.
#
# Layout (per ROADMAP log-location conventions):
#
#   /data/state/                     ← runtime state (sessions, gateway logs)
#     agents/<agentId>/sessions/*.jsonl
#     logs/gateway.jsonl
#     logs/diagnostics.jsonl
#   /data/workspace/                 ← workspace_root from config.yaml
#     memory/YYYY-MM-DD.md
#     MEMORY.md
#     skills/
#     files/                         ← rclone live-sync staging
#       uploads/                     ← bucket-authoritative (inbound)
#
#   /home/openclaw/.openclaw  → /data/state
#   /home/openclaw/workspace  → /data/workspace

source "$CODECLAW_ROOT/lib/common.sh"

MARKER="20-workspace.v2"  # v2: write sudoers unconditionally (cloud-init creates user)
if already_done "$MARKER"; then
  log "workspace already laid out"
  exit 0
fi

WORKSPACE=$(cfg_required .workspace_root)
[[ "$WORKSPACE" == /data/* ]] || die "workspace_root must be under /data"

# ---- openclaw user ---------------------------------------------------------
# Cloud-init may have already created the user via its `users:` block, so
# create-if-missing. Sudoers file is written unconditionally — it's
# idempotent (same content) and the cloud-init path doesn't write our
# canonical filename (it writes /etc/sudoers.d/90-cloud-init-users instead).
if ! id -u openclaw >/dev/null 2>&1; then
  log "creating openclaw user"
  useradd --create-home --shell /bin/bash openclaw
else
  log "openclaw user already exists"
fi

# Passwordless sudo — needed for systemctl restart in operator runbook.
# Step 90 checks for /etc/sudoers.d/openclaw specifically, so always (re)write.
echo 'openclaw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/openclaw
chmod 440 /etc/sudoers.d/openclaw

# SSH authorized_keys: cloud-init put the instance's SSH key on the default
# `ubuntu` user. Copy to openclaw so operators can reach this account over
# Tailscale SSH too.
if [[ -f /home/ubuntu/.ssh/authorized_keys ]]; then
  install -d -o openclaw -g openclaw -m 0700 /home/openclaw/.ssh
  install -o openclaw -g openclaw -m 0600 \
    /home/ubuntu/.ssh/authorized_keys /home/openclaw/.ssh/authorized_keys
fi

# ---- /data directory tree --------------------------------------------------
install -d -o openclaw -g openclaw -m 0700 /data/state
install -d -o openclaw -g openclaw -m 0700 /data/state/agents
install -d -o openclaw -g openclaw -m 0700 /data/state/logs

install -d -o openclaw -g openclaw -m 0755 "$WORKSPACE"
install -d -o openclaw -g openclaw -m 0700 "$WORKSPACE/memory"
install -d -o openclaw -g openclaw -m 0755 "$WORKSPACE/skills"
install -d -o openclaw -g openclaw -m 0755 "$WORKSPACE/files"
install -d -o openclaw -g openclaw -m 0755 "$WORKSPACE/files/uploads"

# ---- Symlinks into openclaw's home ----------------------------------------
# -f so re-runs don't complain about existing symlinks.
ln -sfn /data/state       /home/openclaw/.openclaw
ln -sfn "$WORKSPACE"      /home/openclaw/workspace
chown -h openclaw:openclaw /home/openclaw/.openclaw /home/openclaw/workspace

# ---- Playwright Chromium cache (deferred from step 10) --------------------
# Install as openclaw user so cache lives at ~/.cache/ms-playwright, which is
# where Playwright's own resolver looks when openclaw later runs `page.goto`.
if ! sudo -u openclaw test -d /home/openclaw/.cache/ms-playwright/chromium-*; then
  log "downloading Chromium cache for openclaw user"
  sudo -u openclaw -H bash -c 'npx --yes playwright install chromium' \
    >>"$LOG" 2>&1 || warn "playwright install chromium failed — agents that drive Chrome will need this manually"
else
  log "Chromium cache already present for openclaw user"
fi

# ---- Disable unnecessary services (v1 carry-over) --------------------------
# These run by default on Ubuntu cloud images and we don't use any of them.
for svc in rpcbind rpcbind.socket iscsid iscsid.socket ModemManager; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

mark_done "$MARKER"
log "workspace OK"
