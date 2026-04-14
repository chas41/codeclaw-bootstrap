#!/usr/bin/env bash
# 60-systemd — install systemd units for gateway + live sync.
#
# What this step installs (but does NOT enable — step 95 enables if
# step 90's doctor gate passes):
#
#   openclaw-gateway.service   long-running OpenClaw gateway (Telegram
#                              polling + HTTP). Restart=always.
#   openclaw-sync.service      oneshot rclone of workspace to OCI bucket.
#   openclaw-sync.timer        fires openclaw-sync every 10 minutes.
#
# (Nightly tarball snapshot + logrotate land in step 70. acpx is a CLI
# subcommand invoked by gateway, not a daemon — no unit.)
#
# v2 layout (per roadmap):
#   /data/state/     → openclaw state (agents, logs, creds)
#   /data/workspace/ → agent-visible filesystem (memory, skills, files)
#
# v1 lesson baked in: npm installs openclaw to /usr/bin OR /usr/local/bin
# depending on nodejs source. Step 30 recorded the real path in
# $STATE_DIR/openclaw-bin — we template it into the ExecStart here so a
# service restart never breaks over a path mismatch.

source "$CODECLAW_ROOT/lib/common.sh"

MARKER="60-systemd.v1"
# Re-render is cheap and config may change, so we don't use the marker to
# skip. It exists purely to record that we've touched systemd at least once
# on this host (for provenance). We ALWAYS re-render unit files to keep
# them in sync with config, then daemon-reload.

OPENCLAW_BIN="$(cat "$STATE_DIR/openclaw-bin" 2>/dev/null)"
[[ -n "$OPENCLAW_BIN" && -x "$OPENCLAW_BIN" ]] \
  || die "openclaw binary path missing — run step 30 first"

WORKSPACE="$(cfg_required .workspace_root)"

# ============================================================================
# 1. Live-sync script at /usr/local/bin/openclaw-sync
# ============================================================================
# One-way rclone sync pattern (NOT bisync):
#   outbound: local workspace  →  bucket (authoritative for memory/files)
#   inbound:  bucket:uploads/  →  local files/uploads (authoritative direction)
#
# Rationale: bisync is a foot-cannon. Easier to reason about and safer to
# pick a direction per subtree. Per step 20's layout comment, uploads/ is
# bucket-authoritative (humans drop files into the bucket, agent reads),
# everything else is local-authoritative (agent writes, we push).
cat > /usr/local/bin/openclaw-sync <<'SYNCEOF'
#!/usr/bin/env bash
# openclaw-sync — live sync of /data/workspace with OCI bucket.
# Invoked by openclaw-sync.service (every 10min). Must be idempotent and
# fast. Rendered by codeclaw-bootstrap 60-systemd.
set -euo pipefail

# Source OCI endpoint + bucket. rclone itself reads credentials from
# ~openclaw/.config/rclone/rclone.conf (step 40).
source /data/state/creds/oci-s3.env

WORKSPACE="${WORKSPACE:-/data/workspace}"
BUCKET="$OCI_S3_BUCKET"

# Push local → bucket (memory, MEMORY.md, files except uploads/).
# --exclude uploads/ keeps the bucket-authoritative subtree from being
# overwritten by a local stale copy.
rclone sync "$WORKSPACE/memory"      "oci:${BUCKET}/workspace/memory"   --fast-list
rclone sync "$WORKSPACE/files"       "oci:${BUCKET}/workspace/files" \
    --exclude 'uploads/**' --fast-list
[[ -f "$WORKSPACE/MEMORY.md" ]] && \
  rclone copyto "$WORKSPACE/MEMORY.md" "oci:${BUCKET}/workspace/MEMORY.md"

# Pull bucket → local for uploads/ (bucket-authoritative subtree).
rclone sync "oci:${BUCKET}/workspace/files/uploads" \
            "$WORKSPACE/files/uploads" --fast-list

exit 0
SYNCEOF
chmod 0755 /usr/local/bin/openclaw-sync
log "wrote /usr/local/bin/openclaw-sync"

# ============================================================================
# 2. openclaw-gateway.service
# ============================================================================
cat > /etc/systemd/system/openclaw-gateway.service <<GATEOF
[Unit]
Description=OpenClaw Gateway (HTTP + channel polling)
Documentation=https://docs.openclaw.ai/cli/gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw

# OPENROUTER_API_KEY + OPENROUTER_MGMT_KEY from rendered config (step 40).
EnvironmentFile=/data/state/creds/openrouter.env
Environment=HOME=/home/openclaw
Environment=NODE_ENV=production

# OpenClaw resolves its config via ~/.openclaw, which step 20 symlinked to
# /data/state. No explicit --config needed.
ExecStart=${OPENCLAW_BIN} gateway

Restart=always
RestartSec=5
# Enough time for rclone'd state to flush on stop.
TimeoutStopSec=30

# --- Security hardening (v2 layout) ---
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/data/state ${WORKSPACE} /home/openclaw
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-gateway

[Install]
WantedBy=multi-user.target
GATEOF
log "wrote /etc/systemd/system/openclaw-gateway.service"

# ============================================================================
# 3. openclaw-sync.service (oneshot) + .timer (every 10min)
# ============================================================================
cat > /etc/systemd/system/openclaw-sync.service <<SYNCSVCEOF
[Unit]
Description=OpenClaw workspace <-> OCI bucket live sync
After=network-online.target openclaw-gateway.service
Wants=network-online.target

[Service]
Type=oneshot
User=openclaw
Group=openclaw
# rclone reads creds from ~openclaw/.config/rclone/rclone.conf (step 40).
EnvironmentFile=/data/state/creds/oci-s3.env
ExecStart=/usr/local/bin/openclaw-sync

# If a sync is stuck (e.g. bucket unreachable), don't pile up invocations.
TimeoutStartSec=5m

StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-sync
SYNCSVCEOF
log "wrote /etc/systemd/system/openclaw-sync.service"

cat > /etc/systemd/system/openclaw-sync.timer <<SYNCTIMEOF
[Unit]
Description=Run openclaw-sync every 10 minutes
Requires=openclaw-sync.service

[Timer]
# Start 2min after boot so the gateway has a chance to land first.
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=30s
Persistent=true
Unit=openclaw-sync.service

[Install]
WantedBy=timers.target
SYNCTIMEOF
log "wrote /etc/systemd/system/openclaw-sync.timer"

# ============================================================================
# 4. systemd reload — but do NOT enable/start yet.
# ============================================================================
# Enable + start happens in step 95, only after step 90's doctor gate
# passes. This step is write-only so that a partial bootstrap run doesn't
# leave a broken service restarting forever.
log "systemctl daemon-reload"
systemctl daemon-reload

mark_done "$MARKER"
log "systemd units written (not enabled — step 95 enables)"
