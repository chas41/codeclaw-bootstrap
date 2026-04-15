#!/usr/bin/env bash
# 31-acpx — install the acpx CLI (agent control plane executor).
#
# Mirrors step 30-openclaw. Version resolution:
#   1. If config.yaml has acpx.version, use that (explicit pin).
#   2. Else, if $STATE_DIR/acpx-version exists from a prior run, reuse it.
#   3. Else, resolve `npm view acpx version` and record it.
#
# Like openclaw: on first boot we pin to "latest at first-boot time", every
# re-run uses the same version, and bumps require editing config.yaml or
# deleting $STATE_DIR/acpx-version.
#
# Doctor posture: acpx doctor exists in 2026.4.x. Run WITHOUT --fix —
# diagnostic-only. Step 90 is the real gate.

source "$CODECLAW_ROOT/lib/common.sh"

VERSION_FILE="$STATE_DIR/acpx-version"

# ---- Resolve desired version ----------------------------------------------
desired="$(cfg .acpx.version)"

if [[ -z "$desired" ]] && [[ -f "$VERSION_FILE" ]]; then
  desired="$(cat "$VERSION_FILE")"
  log "reusing previously-recorded version: $desired"
fi

if [[ -z "$desired" ]]; then
  log "resolving latest acpx version from npm"
  desired="$(npm view acpx version 2>/dev/null)"
  [[ -n "$desired" ]] || die "npm view acpx version returned empty"
  log "latest acpx: $desired"
fi

echo "$desired" > "$VERSION_FILE"
log "target version: $desired"

# ---- Check current install -------------------------------------------------
# Substring match on --version output (same rationale as step 30-openclaw:
# build-sha suffix breaks naive field extraction).
current_output=""
if command -v acpx >/dev/null 2>&1; then
  current_output="$(acpx --version 2>/dev/null | head -1)"
fi

if [[ "$current_output" == *"$desired"* ]]; then
  log "acpx already at $desired — skipping npm install"
else
  if [[ -n "$current_output" ]]; then
    log "upgrading acpx ($current_output) → $desired"
  else
    log "installing acpx $desired (first install)"
  fi
  npm install -g "acpx@${desired}"
fi

# ---- Resolve binary path (v1 lesson, same as openclaw) --------------------
# npm on Ubuntu installs to /usr/bin, NOT /usr/local/bin. Systemd units
# hardcoding the wrong path silently break on service restart. Resolve and
# record now — step 60 (systemd) reads this.
ACPX_BIN="$(command -v acpx)"
[[ -x "$ACPX_BIN" ]] || die "acpx binary not found after install"
echo "$ACPX_BIN" > "$STATE_DIR/acpx-bin"
log "acpx binary: $ACPX_BIN"

# ---- Verify version ---------------------------------------------------------
installed_output="$(acpx --version | head -1)"
[[ "$installed_output" == *"$desired"* ]] \
  || die "version mismatch after install: wanted $desired, got '$installed_output'"

# ---- Doctor: diagnose only, DO NOT --fix ----------------------------------
# Same posture as step 30 — surface issues to the log but don't gate here.
# Step 90 is the real gate.
if "$ACPX_BIN" doctor --help >/dev/null 2>&1; then
  log "running 'acpx doctor' (diagnostic only, no --fix)"
  # stdin from /dev/null — see 30-openclaw.sh for rationale.
  sudo -u openclaw -H "$ACPX_BIN" doctor </dev/null 2>&1 | tee -a "$LOG" || true
else
  log "acpx doctor subcommand not available on this version — skipping"
fi

log "acpx install OK (version=$desired, bin=$ACPX_BIN)"
