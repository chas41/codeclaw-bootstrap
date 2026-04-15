#!/usr/bin/env bash
# 70-hooks — nightly tarball snapshot + log rotation.
#
# Complements step 60's live rclone sync with a durable point-in-time
# snapshot. Live sync is "what the workspace looks like right now"; a
# snapshot is "what the workspace looked like on 2026-04-14 at 03:00 UTC".
#
# Why both?
#   - Live sync protects against instance loss (fresh instance pulls
#     current workspace on boot via step 80).
#   - Snapshots protect against corruption or accidental deletion — if an
#     agent nukes its own memory, the live sync dutifully pushes the
#     deletion to the bucket. Snapshots let us roll back.
#
# What this step installs:
#   /usr/local/bin/openclaw-snapshot       tarball + upload + retention
#   openclaw-snapshot.service              oneshot
#   openclaw-snapshot.timer                daily at 03:00 UTC
#   /etc/logrotate.d/openclaw              rotate /var/log/codeclaw*, gateway logs
#
# Retention: 14 daily (rolling) + weekly promotion. Implemented as
# lifecycle logic in the script (list + prune), not as OCI bucket lifecycle
# rules — that way the rule lives with the code in one repo.

source "$CODECLAW_ROOT/lib/common.sh"

MARKER="70-hooks.v1"

WORKSPACE="$(cfg_required .workspace_root)"

# ============================================================================
# 1. Snapshot script at /usr/local/bin/openclaw-snapshot
# ============================================================================
cat > /usr/local/bin/openclaw-snapshot <<'SNAPEOF'
#!/usr/bin/env bash
# openclaw-snapshot — nightly tarball of /data/state + /data/workspace
# to oci:${BUCKET}/snapshots/daily/YYYY-MM-DD.tar.zst plus retention prune.
# Rendered by codeclaw-bootstrap 70-hooks.
set -euo pipefail

source /data/state/creds/oci-s3.env

WORKSPACE="${WORKSPACE:-/data/workspace}"
BUCKET="$OCI_S3_BUCKET"
STAMP="$(date -u +%Y-%m-%d)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE="$TMP/openclaw-${STAMP}.tar.zst"

# Snapshot state + workspace.
# - Exclude files/uploads (bucket-authoritative — no point re-archiving)
# - Exclude caches + node_modules (restorable, bloats archive)
# - Use zstd for speed; -T0 uses all cores.
tar \
  --exclude="${WORKSPACE#/}/files/uploads" \
  --exclude='*/node_modules' \
  --exclude='*/.cache' \
  --exclude='*/ms-playwright' \
  --zstd \
  -cf "$ARCHIVE" \
  -C / \
  "data/state" \
  "${WORKSPACE#/}"

SIZE="$(stat -c %s "$ARCHIVE")"
echo "snapshot size: $SIZE bytes"

# Upload as daily.
rclone copyto "$ARCHIVE" "oci:${BUCKET}/snapshots/daily/openclaw-${STAMP}.tar.zst"

# On Sundays, also promote to weekly.
if [[ "$(date -u +%u)" == "7" ]]; then
  rclone copyto "$ARCHIVE" \
    "oci:${BUCKET}/snapshots/weekly/openclaw-${STAMP}.tar.zst"
fi

# ---- Retention prune ------------------------------------------------------
# Keep last 14 daily + last 8 weekly. rclone's lsjson sorts by ModTime; we
# use --min-age as a simple rolling cutoff since names are date-stamped.
rclone delete "oci:${BUCKET}/snapshots/daily"  --min-age 14d || true
rclone delete "oci:${BUCKET}/snapshots/weekly" --min-age 56d || true

echo "snapshot $STAMP OK"
SNAPEOF
chmod 0755 /usr/local/bin/openclaw-snapshot
log "wrote /usr/local/bin/openclaw-snapshot"

# ============================================================================
# 2. openclaw-snapshot.service + .timer
# ============================================================================
cat > /etc/systemd/system/openclaw-snapshot.service <<SVCEOF
[Unit]
Description=OpenClaw nightly tarball snapshot to OCI bucket
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=openclaw
Group=openclaw
EnvironmentFile=/data/state/creds/oci-s3.env
ExecStart=/usr/local/bin/openclaw-snapshot
# Tarball of a multi-GB workspace can take a while over residential-tier
# egress. 30min is generous but not infinite.
TimeoutStartSec=30m

StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-snapshot
SVCEOF

cat > /etc/systemd/system/openclaw-snapshot.timer <<TMREOF
[Unit]
Description=Daily openclaw snapshot at 03:00 UTC
Requires=openclaw-snapshot.service

[Timer]
# 03:00 UTC — late enough that a late-night session has quiesced, early
# enough that morning operators see yesterday's snapshot.
OnCalendar=*-*-* 03:00:00
# If the instance was down at 03:00, still run once it boots.
Persistent=true
# Jitter up to 15min so a whole fleet doesn't hit the bucket simultaneously.
RandomizedDelaySec=15m
Unit=openclaw-snapshot.service

[Install]
WantedBy=timers.target
TMREOF
log "wrote /etc/systemd/system/openclaw-snapshot.{service,timer}"

# ============================================================================
# 3. logrotate
# ============================================================================
# /var/log/codeclaw-bootstrap.log can grow unbounded over many re-runs.
# OpenClaw's own logs go to journald (systemd) and don't need rotation,
# but anything under /data/state/logs/ does — those are JSONL streams the
# gateway writes directly.
cat > /etc/logrotate.d/openclaw <<'LREOF'
# Rendered by codeclaw-bootstrap 70-hooks.
/var/log/codeclaw-bootstrap.log {
    # /var/log is drwxrwxr-x root:syslog on Ubuntu. logrotate considers that
    # "insecure" (group-writable by a non-root group) and skips unless told
    # explicitly which user to rotate as. Running as root is correct here —
    # the log is owned by root and lives under system /var/log.
    su root root
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}

/data/state/logs/*.jsonl {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su openclaw openclaw
    create 0600 openclaw openclaw
}
LREOF
log "wrote /etc/logrotate.d/openclaw"

# Smoke-test the logrotate config. --debug does a dry run; fails fast on
# syntax errors rather than silently breaking rotations weeks later.
if ! logrotate --debug /etc/logrotate.d/openclaw >>"$LOG" 2>&1; then
  die "logrotate config is invalid — see $LOG"
fi

# ============================================================================
# 4. Reload systemd — but do not enable the new timer (step 95).
# ============================================================================
systemctl daemon-reload

mark_done "$MARKER"
log "hooks OK"
