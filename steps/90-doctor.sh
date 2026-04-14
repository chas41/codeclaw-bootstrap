#!/usr/bin/env bash
# 90-doctor — hard gate before we enable services in step 95.
#
# Runs a battery of checks covering every prior step's output. Unlike
# earlier steps' "warn and continue" posture, failures here are fatal —
# this is the line of defense that stops step 95 from starting a broken
# gateway in a restart loop.
#
# Design notes:
#   - Collect ALL failures, report together at the end, then die. Bailing
#     on the first failure just forces another round-trip; a full report
#     lets an operator fix everything in one pass.
#   - Every check is read-only. Doctor does not mutate state.
#   - `openclaw doctor` is the authoritative check for OpenClaw's own
#     health — we defer to it and only bubble its exit status up.

source "$CODECLAW_ROOT/lib/common.sh"

# No marker — doctor must run every time to gate step 95.

FAILURES=()
fail() { FAILURES+=("$1"); warn "  ✗ $1"; }
ok()   { log  "  ✓ $1"; }

# ---- 1. Binaries at recorded paths ----------------------------------------
log "check: recorded binary paths"
for bin_file in openclaw-bin acpx-bin; do
  path_file="$STATE_DIR/$bin_file"
  if [[ ! -f "$path_file" ]]; then
    fail "missing $path_file (earlier step didn't record it)"
    continue
  fi
  p="$(cat "$path_file")"
  if [[ -x "$p" ]]; then
    ok "$bin_file → $p"
  else
    fail "$bin_file points to non-executable: $p"
  fi
done

# ---- 2. openclaw + acpx respond to --version ------------------------------
log "check: CLI version probes"
OPENCLAW_BIN="$(cat "$STATE_DIR/openclaw-bin" 2>/dev/null || command -v openclaw)"
ACPX_BIN="$(cat "$STATE_DIR/acpx-bin" 2>/dev/null || command -v acpx)"

if v="$(sudo -u openclaw -H "$OPENCLAW_BIN" --version 2>&1)"; then
  ok "openclaw --version: $(echo "$v" | head -1)"
else
  fail "openclaw --version failed: $v"
fi

if v="$(sudo -u openclaw -H "$ACPX_BIN" --version 2>&1)"; then
  ok "acpx --version: $(echo "$v" | head -1)"
else
  fail "acpx --version failed: $v"
fi

# ---- 3. Credential files: present, 0600, non-empty ------------------------
log "check: credential files"
for f in /data/state/creds/openrouter.env /data/state/creds/oci-s3.env \
         /home/openclaw/.config/rclone/rclone.conf; do
  if [[ ! -f "$f" ]]; then
    fail "missing: $f"
    continue
  fi
  if [[ ! -s "$f" ]]; then
    fail "empty: $f"
    continue
  fi
  mode="$(stat -c %a "$f")"
  owner="$(stat -c %U "$f")"
  if [[ "$mode" != "600" ]]; then
    fail "wrong mode on $f: $mode (want 600)"
  elif [[ "$owner" != "openclaw" ]]; then
    fail "wrong owner on $f: $owner (want openclaw)"
  else
    ok "$f (0600 openclaw)"
  fi
done

# ---- 4. rclone can reach the bucket ---------------------------------------
log "check: rclone → OCI bucket"
source /data/state/creds/oci-s3.env
if sudo -u openclaw -H rclone lsd "oci:${OCI_S3_BUCKET}" >>"$LOG" 2>&1; then
  ok "rclone lsd oci:${OCI_S3_BUCKET}"
else
  fail "rclone cannot list oci:${OCI_S3_BUCKET} — check creds/endpoint"
fi

# ---- 5. Workspace layout + symlinks ---------------------------------------
log "check: workspace layout"
WORKSPACE="$(cfg_required .workspace_root)"
for d in /data/state /data/state/agents /data/state/logs \
         "$WORKSPACE" "$WORKSPACE/memory" "$WORKSPACE/skills" \
         "$WORKSPACE/files" "$WORKSPACE/files/uploads"; do
  if [[ ! -d "$d" ]]; then
    fail "missing directory: $d"
  fi
done
[[ -L /home/openclaw/.openclaw ]]  || fail "missing symlink /home/openclaw/.openclaw"
[[ -L /home/openclaw/workspace ]]  || fail "missing symlink /home/openclaw/workspace"
# Dereference — symlink should resolve onto /data.
[[ "$(readlink -f /home/openclaw/.openclaw)" == /data/state ]] \
  || fail "/home/openclaw/.openclaw does not resolve to /data/state"
[[ "$(readlink -f /home/openclaw/workspace)" == "$(readlink -f "$WORKSPACE")" ]] \
  || fail "/home/openclaw/workspace does not resolve to $WORKSPACE"

# ---- 6. openclaw user + sudoers -------------------------------------------
log "check: openclaw user"
if id -u openclaw >/dev/null 2>&1; then
  ok "openclaw user exists (uid=$(id -u openclaw))"
else
  fail "openclaw user missing"
fi
[[ -f /etc/sudoers.d/openclaw ]] || fail "missing /etc/sudoers.d/openclaw"

# ---- 7. systemd unit files validate ---------------------------------------
log "check: systemd units"
for unit in openclaw-gateway.service \
            openclaw-sync.service openclaw-sync.timer \
            openclaw-snapshot.service openclaw-snapshot.timer; do
  path="/etc/systemd/system/$unit"
  if [[ ! -f "$path" ]]; then
    fail "missing unit file: $path"
    continue
  fi
  if systemd-analyze verify "$path" >>"$LOG" 2>&1; then
    ok "$unit validates"
  else
    fail "systemd-analyze verify failed for $unit — see $LOG"
  fi
done

# ---- 8. openclaw doctor (authoritative) -----------------------------------
log "check: openclaw doctor (authoritative — no --fix)"
if sudo -u openclaw -H "$OPENCLAW_BIN" doctor 2>&1 | tee -a "$LOG"; then
  ok "openclaw doctor reports clean"
else
  fail "openclaw doctor reports issues — see log above"
fi

# ---- 9. Data volume ---------------------------------------------------------
# If the root disk fills up, everything breaks in creative ways. 85% is a
# reasonable warn threshold; 95% is a fail threshold.
log "check: disk usage"
root_pct="$(df --output=pcent / | tail -1 | tr -d ' %')"
data_pct="$(df --output=pcent /data | tail -1 | tr -d ' %')"
if (( root_pct >= 95 )); then fail "/ is ${root_pct}% full (>=95%)"
elif (( root_pct >= 85 )); then warn "/ is ${root_pct}% full (>=85%) — monitor"
else ok "/ is ${root_pct}% full"; fi
if (( data_pct >= 95 )); then fail "/data is ${data_pct}% full (>=95%)"
elif (( data_pct >= 85 )); then warn "/data is ${data_pct}% full (>=85%) — monitor"
else ok "/data is ${data_pct}% full"; fi

# ---- Verdict ---------------------------------------------------------------
if (( ${#FAILURES[@]} > 0 )); then
  warn "=== doctor FAILED with ${#FAILURES[@]} issue(s) ==="
  for f in "${FAILURES[@]}"; do
    warn "  - $f"
  done
  die "doctor gate failed — step 95 will NOT run. Fix above and re-run."
fi

log "doctor OK — all checks passed"
