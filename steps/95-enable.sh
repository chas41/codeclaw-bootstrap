#!/usr/bin/env bash
# 95-enable — enable + start services and timers.
#
# Runs only after step 90's doctor gate passes. Order matters:
#   1. gateway service (long-running) — enable + start, wait for active
#   2. sync timer — enable (first fire is 2min after boot per unit)
#   3. snapshot timer — enable (fires at 03:00 UTC)
#
# Gateway readiness:
#   We wait up to 60s for systemd to report "active (running)". If the
#   gateway crash-loops, `is-active` will eventually return "failed" or
#   "activating" — both non-terminal, so we poll with a hard timeout.
#   Deeper probing (HTTP health endpoint, channel connectivity) is step
#   99's job.
#
# Re-runnable:
#   systemctl enable --now is idempotent. On re-run, if the gateway is
#   already running we just re-confirm it's healthy. No marker needed.

source "$CODECLAW_ROOT/lib/common.sh"

# ---- 1. Gateway -----------------------------------------------------------
log "enabling + starting openclaw-gateway.service"
systemctl enable --now openclaw-gateway.service

# Poll for active state with a hard 60s budget.
deadline=$(( $(date +%s) + 60 ))
state=""
while (( $(date +%s) < deadline )); do
  state="$(systemctl is-active openclaw-gateway.service 2>&1 || true)"
  case "$state" in
    active)      break ;;
    failed)      break ;;
    activating|deactivating|inactive) sleep 2 ;;
    *)           sleep 2 ;;
  esac
done

if [[ "$state" != "active" ]]; then
  warn "openclaw-gateway is '$state' after 60s — dumping recent journal"
  journalctl -u openclaw-gateway.service -n 100 --no-pager 2>&1 | tee -a "$LOG"
  die "gateway did not reach active state — refusing to enable timers"
fi
log "openclaw-gateway is active"

# ---- 2. Live-sync timer ---------------------------------------------------
log "enabling openclaw-sync.timer"
systemctl enable --now openclaw-sync.timer

# Quick sanity check — timer should be active (waiting).
timer_state="$(systemctl is-active openclaw-sync.timer 2>&1 || true)"
[[ "$timer_state" == "active" ]] \
  || die "openclaw-sync.timer not active (state=$timer_state)"
log "openclaw-sync.timer enabled (next fire: $(systemctl show openclaw-sync.timer -p NextElapseUSecRealtime --value))"

# ---- 3. Snapshot timer ----------------------------------------------------
log "enabling openclaw-snapshot.timer"
systemctl enable --now openclaw-snapshot.timer

timer_state="$(systemctl is-active openclaw-snapshot.timer 2>&1 || true)"
[[ "$timer_state" == "active" ]] \
  || die "openclaw-snapshot.timer not active (state=$timer_state)"
log "openclaw-snapshot.timer enabled (next fire: $(systemctl show openclaw-snapshot.timer -p NextElapseUSecRealtime --value))"

# ---- 4. Summary -----------------------------------------------------------
log "=== services enabled ==="
systemctl --no-pager status openclaw-gateway.service \
          openclaw-sync.timer openclaw-snapshot.timer 2>&1 \
  | tee -a "$LOG" >/dev/null
log "enable OK"
