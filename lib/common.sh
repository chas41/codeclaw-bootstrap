# Shared helpers sourced by every step.
# Keep this tiny — anything with a moving part belongs in a step, not here.

set -euo pipefail

: "${LOG:=/var/log/codeclaw-bootstrap.log}"
: "${CONFIG:=/etc/codeclaw/config.yaml}"
: "${REPO_SHA:=unknown}"
: "${STATE_DIR:=/var/lib/codeclaw-bootstrap}"

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"

# ---- Logging ----
log()     { echo "[$(date -Is)] [${STEP:-?}] $*" | tee -a "$LOG"; }
warn()    { log "WARN: $*"; }
die()     { log "ERROR: $*"; exit 1; }

# ---- Idempotency markers ----
# Every step declares a marker. `already_done <marker>` short-circuits on re-run.
# `mark_done <marker>` records success. Markers are files in $STATE_DIR so they
# survive across re-runs but are tied to the instance's root filesystem (not /data,
# because a restore of /data shouldn't fool us into skipping OS-level install steps).
already_done() { [[ -f "$STATE_DIR/done.$1" ]]; }
mark_done()    { touch "$STATE_DIR/done.$1"; }
clear_done()   { rm -f "$STATE_DIR/done.$1"; }

# ---- Config reader ----
# Thin wrapper so steps don't have to repeat the -r/null dance.
cfg() {
  local path="$1"
  local val
  val=$(yq -r "$path" "$CONFIG" 2>/dev/null || true)
  [[ "$val" == "null" ]] && val=""
  printf '%s' "$val"
}

cfg_required() {
  local path="$1"
  local val
  val=$(cfg "$path")
  [[ -n "$val" ]] || die "missing required config field: $path"
  printf '%s' "$val"
}

# ---- Wait helpers (v1 lessons) ----
wait_for_network() {
  local tries=30
  for i in $(seq 1 "$tries"); do
    if curl -sf --max-time 5 https://archive.ubuntu.com >/dev/null 2>&1; then
      log "network ready (attempt $i)"
      return 0
    fi
    log "network not ready — attempt $i/$tries, sleeping 10s"
    sleep 10
  done
  die "network never came up after $tries attempts"
}

wait_for_apt_lock() {
  local tries=60
  for i in $(seq 1 "$tries"); do
    if ! fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
      log "apt lock free (attempt $i)"
      return 0
    fi
    log "apt lock held — attempt $i/$tries, sleeping 10s"
    sleep 10
  done
  die "apt lock never released"
}

wait_for_device() {
  local dev="$1" tries="${2:-60}"
  for i in $(seq 1 "$tries"); do
    [[ -b "$dev" ]] && return 0
    log "waiting for $dev — attempt $i/$tries"
    sleep 2
  done
  die "device $dev never appeared"
}

# ---- Verified download ----
# Usage: fetch_verified <url> <sha256> <dest>
fetch_verified() {
  local url="$1" sha="$2" dest="$3"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 3 "$url" -o "$tmp" || { rm -f "$tmp"; die "download failed: $url"; }
  echo "${sha}  ${tmp}" | sha256sum -c - >/dev/null || { rm -f "$tmp"; die "sha256 mismatch: $url"; }
  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
}
