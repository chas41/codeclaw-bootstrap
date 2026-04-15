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
# `openclaw --version` prints something like:
#   openclaw 2026.4.14 (323493f)
# We match the desired version as a substring rather than trying to pick a
# specific field — the build-sha suffix and field ordering have changed
# across releases and the only invariant we care about is "the expected
# version number appears in the output".
current_output=""
if command -v openclaw >/dev/null 2>&1; then
  current_output="$(openclaw --version 2>/dev/null | head -1)"
fi

if [[ "$current_output" == *"$desired"* ]]; then
  log "openclaw already at $desired — skipping npm install"
else
  if [[ -n "$current_output" ]]; then
    log "upgrading openclaw ($current_output) → $desired"
  else
    log "installing openclaw $desired (first install)"
  fi
  npm install -g "openclaw@${desired}"
fi

# ---- Resolve binary path (v1 lesson) --------------------------------------
# npm on Ubuntu installs to /usr/bin, NOT /usr/local/bin. Systemd units
# hardcoding the wrong path silently break on service restart. Resolve and
# record now — step 60 (systemd) reads this.
OPENCLAW_BIN="$(command -v openclaw)"
[[ -x "$OPENCLAW_BIN" ]] || die "openclaw binary not found after install"
echo "$OPENCLAW_BIN" > "$STATE_DIR/openclaw-bin"
log "openclaw binary: $OPENCLAW_BIN"

# ---- Verify version ---------------------------------------------------------
installed_output="$(openclaw --version | head -1)"
[[ "$installed_output" == *"$desired"* ]] \
  || die "version mismatch after install: wanted $desired, got '$installed_output'"

# ---- Doctor: diagnose only, DO NOT --fix ----------------------------------
# Run doctor without --fix to surface any issues to the log. Failures here
# don't block this step; step 90 is the real gate.
#
# stdin redirected from /dev/null: `openclaw doctor` may emit interactive
# prompts (e.g. "Generate and configure a gateway token now?") — with no
# TTY it treats them as "No" / declined and continues.
log "running 'openclaw doctor' (diagnostic only, no --fix)"
sudo -u openclaw -H "$OPENCLAW_BIN" doctor </dev/null 2>&1 | tee -a "$LOG" || true

log "openclaw install OK (version=$desired, bin=$OPENCLAW_BIN)"
