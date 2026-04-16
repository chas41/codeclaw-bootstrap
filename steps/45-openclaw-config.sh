#!/usr/bin/env bash
# 45-openclaw-config — minimum gateway config required for systemd start.
#
# Why this step exists:
#   On a fresh openclaw install, `openclaw gateway` exits with status 78
#   (EX_CONFIG) and the message:
#       Missing config. Run `openclaw setup` or set gateway.mode=local
#   The systemd unit then crash-loops every 5s. Step 95's "is-active" poll
#   would catch a brief activating window and falsely report success.
#
# What it does:
#   1. `openclaw config set gateway.mode local` — bind loopback, no remote auth.
#   2. (Optional) enable gateway.auth.enabled for defense-in-depth.
#   3. Generate and set gateway.auth.token if not already present.
#
# Why local:
#   We're Tailscale-only (no public IP). Operators reach the dashboard via
#   `ssh -L 18789:localhost:18789 openclaw@oc-codeclaw-<name>` over Tailscale
#   SSH. The gateway never needs to listen on 0.0.0.0.
#
# Idempotency: `openclaw config set` is itself idempotent (writes the same
# value if it already matches). We guard with a `config get` to avoid noisy
# log lines on re-runs and to skip the "Restart the gateway" follow-up
# print on a no-op set.

source "$CODECLAW_ROOT/lib/common.sh"

OPENCLAW_BIN="$(cat "$STATE_DIR/openclaw-bin")"
[[ -x "$OPENCLAW_BIN" ]] || die "openclaw-bin record missing or not executable"

# Helper: read current value (empty string if unset).
oc_get() {
  sudo -u openclaw -H "$OPENCLAW_BIN" config get "$1" 2>/dev/null \
    | tr -d '[:space:]' || true
}

# Helper: set a value if it differs from the desired.
oc_ensure() {
  local key="$1" want="$2" have
  have="$(oc_get "$key")"
  if [[ "$have" == "$want" ]]; then
    log "  $key already = $want"
    return 0
  fi
  log "  setting $key=$want (was: '${have:-<unset>}')"
  sudo -u openclaw -H "$OPENCLAW_BIN" config set "$key" "$want" \
    2>&1 | tee -a "$LOG" >/dev/null
}

log "configuring openclaw for local gateway operation"

# 1. gateway.mode — required for the gateway to start at all.
oc_ensure gateway.mode local

# 2. gateway.auth.enabled — defense-in-depth for the loopback gateway.
#    The CLI may or may not accept this key on every version. Don't die
#    if rejected — step 3 below is what actually secures the gateway.
if sudo -u openclaw -H "$OPENCLAW_BIN" config set gateway.auth.enabled true \
     >/dev/null 2>&1; then
  log "  gateway.auth.enabled=true"
else
  log "  gateway.auth.enabled not accepted by this CLI version — skipping"
fi

# 3. gateway.auth.token — generate explicitly if not already set.
#    Previous versions relied on openclaw auto-generating this on restart,
#    but that left a window where the gateway ran unauthenticated (security
#    audit reported CRITICAL "Gateway auth missing on loopback"). Generate
#    deterministically so every fresh deploy is secure from first start.
existing_token="$(oc_get gateway.auth.token)"
if [[ -n "$existing_token" ]]; then
  log "  gateway.auth.token already set"
else
  new_token="$(openssl rand -hex 32)"
  if sudo -u openclaw -H "$OPENCLAW_BIN" config set gateway.auth.token "$new_token" \
       >/dev/null 2>&1; then
    log "  gateway.auth.token generated and set"
  else
    log "  WARN: could not set gateway.auth.token — verify manually after deploy"
  fi
fi

log "openclaw config OK"
