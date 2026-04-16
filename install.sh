#!/usr/bin/env bash
# codeclaw-bootstrap — idempotent, re-runnable installer.
#
# Invoked by cloud-init on first boot. Also re-runnable any time to converge
# state. Every step is a separate script under steps/; each is idempotent
# and logs to /var/log/codeclaw-bootstrap.log.
#
# Usage:
#   install.sh [--config /etc/codeclaw/config.yaml] [--sha <git-sha>]
#              [--only STEP[,STEP...]] [--skip STEP[,STEP...]] [--reset]
#
# Flags:
#   --config   path to config.yaml (default: /etc/codeclaw/config.yaml)
#   --sha      git SHA of this bootstrap checkout (provenance in logs)
#   --only     run only these step numbers, comma-separated (e.g. 30,31)
#   --skip     skip these step numbers
#   --reset    clear all idempotency markers (force full re-run)

set -euo pipefail

CONFIG="${CODECLAW_CONFIG:-/etc/codeclaw/config.yaml}"
REPO_SHA="${CODECLAW_BOOTSTRAP_SHA:-}"
ONLY=""
SKIP=""
RESET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --sha)    REPO_SHA="$2"; shift 2 ;;
    --only)   ONLY="$2"; shift 2 ;;
    --skip)   SKIP="$2"; shift 2 ;;
    --reset)  RESET=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default REPO_SHA to the git HEAD of this checkout if not provided.
if [[ -z "$REPO_SHA" ]]; then
  REPO_SHA="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo "unknown")"
fi

export CONFIG REPO_SHA
export LOG=/var/log/codeclaw-bootstrap.log
export STATE_DIR=/var/lib/codeclaw-bootstrap
export CODECLAW_ROOT="$HERE"

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

STEP="orchestrator"

log "==========================================================="
log "codeclaw-bootstrap starting"
log "  sha    = $REPO_SHA"
log "  config = $CONFIG"
log "  state  = $STATE_DIR"
log "  only   = ${ONLY:-<all>}"
log "  skip   = ${SKIP:-<none>}"
log "  reset  = $RESET"
log "==========================================================="

[[ -r "$CONFIG" ]] || die "config not readable: $CONFIG"

if (( RESET == 1 )); then
  log "resetting idempotency markers"
  rm -f "$STATE_DIR"/done.*
fi

# Step list — numeric prefix preserves order. Edit this when adding steps.
STEPS=(
  00-preflight
  10-packages
  20-workspace
  30-openclaw
  31-acpx
  40-creds
  45-openclaw-config
  50-skills
  60-systemd
  70-hooks
  80-restore
  90-doctor
  95-enable
  99-smoke
)

should_run() {
  local step="$1" num="${step%%-*}"
  if [[ -n "$ONLY" ]] && ! echo ",$ONLY," | grep -q ",$num,"; then
    return 1
  fi
  if [[ -n "$SKIP" ]] && echo ",$SKIP," | grep -q ",$num,"; then
    return 1
  fi
  return 0
}

for step in "${STEPS[@]}"; do
  if ! should_run "$step"; then
    log "skip $step (filter)"
    continue
  fi
  script="$HERE/steps/${step}.sh"
  [[ -x "$script" ]] || die "missing or non-executable step: $script"
  log ">>> $step"
  STEP="$step" bash "$script" || die "$step failed — see $LOG"
  log "<<< $step"
done

STEP="orchestrator"
log "codeclaw-bootstrap complete (sha=$REPO_SHA)"
