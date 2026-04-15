#!/usr/bin/env bash
# 99-smoke — post-start verification.
#
# Services are up (step 95 ensured that). This step verifies they're
# actually doing useful work end-to-end:
#   1. openclaw status          — channel health reported
#   2. gateway HTTP probe        — local HTTP endpoint responds
#   3. force a one-shot sync     — rclone actually succeeds, bucket has
#                                  our workspace prefix afterward
#   4. record completion         — $STATE_DIR/bootstrap-complete
#
# Failures are WARNINGS, not fatal. The services are already running and
# a smoke-check failure is worth flagging but shouldn't itself tear down
# a just-booted instance. Operator inspects the log.

source "$CODECLAW_ROOT/lib/common.sh"

OPENCLAW_BIN="$(cat "$STATE_DIR/openclaw-bin")"
source /data/state/creds/oci-s3.env
BUCKET="$OCI_S3_BUCKET"

issues=0

# ---- 1. openclaw status ---------------------------------------------------
log "smoke: openclaw status"
if sudo -u openclaw -H "$OPENCLAW_BIN" status 2>&1 | tee -a "$LOG"; then
  log "  ✓ status returned 0"
else
  warn "  ✗ 'openclaw status' returned non-zero"
  issues=$((issues + 1))
fi

# ---- 2. Gateway HTTP probe -------------------------------------------------
# OpenClaw 2026.4.x binds the gateway/control UI on 127.0.0.1:18789 (per
# `openclaw status` Dashboard line). Probe the loopback so we don't need
# auth tokens.
GATEWAY_PORT=18789
log "smoke: gateway HTTP probe on localhost:${GATEWAY_PORT}"
if code="$(curl -fsS -o /dev/null -w '%{http_code}' \
            --max-time 5 http://127.0.0.1:${GATEWAY_PORT}/healthz 2>&1)"; then
  log "  ✓ GET /healthz → $code"
else
  # /healthz might not exist — try root path as fallback.
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
            --max-time 5 http://127.0.0.1:${GATEWAY_PORT}/ 2>&1 || echo '000')"
  if [[ "$code" =~ ^[23] ]]; then
    log "  ✓ GET / → $code (no /healthz; root responded)"
  else
    warn "  ✗ gateway HTTP probe failed (code=$code)"
    issues=$((issues + 1))
  fi
fi

# ---- 3. Force a one-shot sync + verify bucket state -----------------------
log "smoke: forcing openclaw-sync.service to confirm end-to-end rclone"
if systemctl start openclaw-sync.service; then
  # Wait for oneshot to finish (up to 2 min).
  deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    state="$(systemctl is-active openclaw-sync.service 2>&1 || true)"
    [[ "$state" == "inactive" || "$state" == "failed" ]] && break
    sleep 2
  done
  result="$(systemctl show openclaw-sync.service -p Result --value)"
  if [[ "$result" == "success" ]]; then
    log "  ✓ openclaw-sync one-shot succeeded"
  else
    warn "  ✗ openclaw-sync result: $result"
    journalctl -u openclaw-sync.service -n 30 --no-pager | tee -a "$LOG"
    issues=$((issues + 1))
  fi
else
  warn "  ✗ failed to start openclaw-sync.service"
  issues=$((issues + 1))
fi

# Verify bucket has our workspace prefix after sync.
log "smoke: verifying bucket has workspace/ prefix"
if sudo -u openclaw -H rclone lsd "oci:${BUCKET}/workspace" >>"$LOG" 2>&1; then
  log "  ✓ oci:${BUCKET}/workspace/ reachable"
else
  warn "  ✗ oci:${BUCKET}/workspace/ not listable — sync may have failed silently"
  issues=$((issues + 1))
fi

# ---- 4. Record completion --------------------------------------------------
cat > "$STATE_DIR/bootstrap-complete" <<EOF
bootstrap_sha=$REPO_SHA
completed_ts=$(date -Is)
openclaw_bin=$OPENCLAW_BIN
openclaw_version=$(sudo -u openclaw -H "$OPENCLAW_BIN" --version 2>&1 | head -1)
smoke_issues=$issues
EOF

# ---- Verdict ---------------------------------------------------------------
if (( issues > 0 )); then
  warn "smoke completed with $issues non-fatal issue(s) — services are up, see $LOG"
  exit 0
fi

log "=== bootstrap complete, all smoke checks passed ==="
log "next: 'sudo -u openclaw bw-unlock' to cache a Bitwarden session (one-time)"
