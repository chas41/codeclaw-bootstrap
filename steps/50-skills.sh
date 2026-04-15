#!/usr/bin/env bash
# 50-skills — install ClawHub skills listed in config.yaml.
#
# Skill model (v1 inspection, 2026-04-14):
#   - OpenClaw ships ~50 skills BUNDLED in the npm package, installed at
#     /usr/lib/node_modules/openclaw/skills/ by step 30. Those come for
#     free; nothing to do here.
#   - ClawHub (docs.openclaw.ai/cli/skills) is the registry for additional
#     skills. `openclaw skills install <name>` pulls them into the active
#     workspace. That's the ONLY install mechanism — no git cloning.
#   - Readiness ≠ installation. Many bundled skills report "needs setup"
#     because they want API keys/CLIs the operator must configure. Step 50
#     does not attempt to "fix" needs-setup skills. It logs the readiness
#     table and moves on; step 90 decides whether the overall posture is
#     acceptable.
#
# Config schema:
#   skills:
#     extra:
#       - name: some-clawhub-skill       # required, ClawHub slug
#         version: "1.2.3"               # optional; omit for latest
#
# Idempotency:
#   - `openclaw skills install` is itself idempotent (no-op if already at
#     target version). Re-runnable cheaply. No marker needed; config drives.
#
# Runs install commands AS openclaw via sudo -u openclaw so installed
# skills land in the openclaw-owned workspace, not root's.

source "$CODECLAW_ROOT/lib/common.sh"

OPENCLAW_BIN="$(cat "$STATE_DIR/openclaw-bin" 2>/dev/null || command -v openclaw)"
[[ -x "$OPENCLAW_BIN" ]] || die "openclaw binary not found (step 30 should have recorded it)"

# ---- Record bundled inventory ---------------------------------------------
# Snapshot what ships bundled so the log has a record of the baseline for
# this openclaw version. Purely informational.
log "bundled skill inventory (openclaw skills list):"
sudo -u openclaw -H "$OPENCLAW_BIN" skills list 2>&1 | tee -a "$LOG" >/dev/null || \
  warn "openclaw skills list failed — continuing"

# ---- Install ClawHub skills from .skills.extra[] --------------------------
extra_count="$(yq '.skills.extra | length // 0' "$CONFIG")"
log "user-defined ClawHub skills: $extra_count"

installed=0
failed=0
for (( i=0; i<extra_count; i++ )); do
  name="$(yq ".skills.extra[$i].name" "$CONFIG")"
  version="$(yq ".skills.extra[$i].version // \"\"" "$CONFIG")"

  if [[ -z "$name" || "$name" == "null" ]]; then
    warn "skills.extra[$i]: missing name — skipping"
    failed=$((failed + 1))
    continue
  fi

  if [[ -n "$version" && "$version" != "null" ]]; then
    target="${name}@${version}"
  else
    target="$name"
  fi

  log "installing ClawHub skill: $target"
  # openclaw skills install is idempotent per upstream docs. Tee to log
  # for audit trail; don't die on failure (step 90 gates).
  if sudo -u openclaw -H "$OPENCLAW_BIN" skills install "$target" \
       2>&1 | tee -a "$LOG" >/dev/null; then
    installed=$((installed + 1))
  else
    warn "  failed to install $target"
    failed=$((failed + 1))
  fi
done

# ---- Readiness check -------------------------------------------------------
# `openclaw skills check` surfaces which skills are ready vs missing deps.
# This is the right place to see the full posture. Log only; do not gate.
log "running 'openclaw skills check' (report only, not a gate):"
sudo -u openclaw -H "$OPENCLAW_BIN" skills check 2>&1 | tee -a "$LOG" >/dev/null || \
  warn "openclaw skills check exited non-zero — inspect log"

log "skills OK (extra_installed=$installed failed=$failed)"
