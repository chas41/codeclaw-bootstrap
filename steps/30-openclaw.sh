#!/usr/bin/env bash
# 30-openclaw — install the OpenClaw CLI.
#
# Version resolution:
#   1. If config.yaml has openclaw.version, use that (explicit pin).
#   2. Else, if $STATE_DIR/openclaw-version exists from a prior run, reuse it
#      (stable across re-runs).
#   3. Else, resolve `npm view openclaw version` and record it.
#
# This means: on first boot, we pin to "latest at first-boot time". Every
# re-run uses the same version. Bumping requires either editing config.yaml
# or deleting $STATE_DIR/openclaw-version then re-running.
#
# Note on `openclaw doctor --fix`: the 2026.4.5 multi-account Telegram
# migration bug only affected in-place upgrades of existing agent config.
# Fresh builds have nothing to migrate, and the bug is fixed in later
# releases anyway. Here we still run doctor WITHOUT --fix because on a fresh
# workspace there is nothing to fix — diagnostic-only is the right posture.
# Step 90 is the real gate.

source "$CODECLAW_ROOT/lib/common.sh"

VERSION_FILE="$STATE_DIR/openclaw-version"

# ---- Resolve desired version ----------------------------------------------
desired="$(cfg .openclaw.version)"

if [[ -z "$desired" ]] && [[ -f "$VERSION_FILE" ]]; then
  desired="$(cat "$VERSION_FILE")"
  log "reusing previously-recorded version: $desired"
fi

if [[ -z "$desired" ]]; then
  log "resolving latest openclaw version from npm"
  desired="$(npm view openclaw version 2>/dev/null)"
  [[ -n "$desired" ]] || die "npm view openclaw version returned empty"
  log "latest openclaw: $desired"
fi

echo "$desired" > "$VERSION_FILE"
log "target version: $desired"

# ---- Check current install -------------------------------------------------
current=""
if command -v openclaw >/dev/null 2>&1; then
  current="$(openclaw --version 2>/dev/null | head -1 | awk '{print $NF}')"
fi

if [[ "$current" == "$desired" ]]; then
  log "openclaw already at $desired — no install needed"
  exit 0
fi

if [[ -n "$current" ]]; then
  log "upgrading openclaw $current → $desired"
else
  log "installing openclaw $desired (first install)"
fi

npm install -g "openclaw@${desired}"

# ---- Resolve binary path (v1 lesson) --------------------------------------
# npm on Ubuntu installs to /usr/bin, NOT /usr/local/bin. Systemd units
# hardcoding the wrong path silently break on service restart. Resolve and
# record now — step 60 (systemd) reads this.
OPENCLAW_BIN="$(command -v openclaw)"
[[ -x "$OPENCLAW_BIN" ]] || die "openclaw binary not found after install"
echo "$OPENCLAW_BIN" > "$STATE_DIR/openclaw-bin"
log "openclaw binary: $OPENCLAW_BIN"

# ---- Verify version ---------------------------------------------------------
installed="$(openclaw --version | head -1 | awk '{print $NF}')"
[[ "$installed" == "$desired" ]] \
  || die "version mismatch after install: wanted $desired, got $installed"

# ---- Doctor: diagnose only, DO NOT --fix ----------------------------------
# Run doctor without --fix to surface any issues to the log. Failures here
# don't block this step; step 90 is the real gate.
log "running 'openclaw doctor' (diagnostic only, no --fix)"
sudo -u openclaw -H "$OPENCLAW_BIN" doctor 2>&1 | tee -a "$LOG" || true

log "openclaw install OK (version=$desired, bin=$OPENCLAW_BIN)"
