#!/usr/bin/env bash
# 80-restore — on a fresh instance, auto-restore state from the most
# recent snapshot in OCI.
#
# When does this step do anything?
#   - On a BRAND-NEW instance (no prior state on this host), AND
#   - The bucket has at least one snapshot under snapshots/daily/.
#
# When does it skip?
#   - Re-run on a healthy instance (state already present) → skip.
#   - First-ever instance for this name (empty bucket) → skip, start fresh.
#
# Why restore matters:
#   The whole point of the 100GB data volume + bucket backups is that
#   instance recreation is cheap. Terraform blows away the VM, re-creates
#   it, cloud-init runs bootstrap, and we come back up WITH OUR STATE.
#   Without this step, a recreate would come up empty.
#
# Snapshot vs live-sync:
#   - Snapshot restore is comprehensive (covers /data/state including
#     creds/logs/agent sessions, plus /data/workspace) but may be up to
#     24h stale.
#   - Step 95 then starts openclaw-sync.timer which pulls the live bucket
#     state into /data/workspace, closing the gap to current.
#
# This step is destructive to an empty workspace only. We REFUSE to run
# if the workspace looks non-empty — in that case, operator must decide.

source "$CODECLAW_ROOT/lib/common.sh"

MARKER="80-restore.v1"
if already_done "$MARKER"; then
  log "restore already completed — skipping"
  exit 0
fi

WORKSPACE="$(cfg_required .workspace_root)"

# ---- Detect "fresh instance" ----------------------------------------------
# Signals that state is present and we should NOT restore over it:
#   - /data/state/agents has any subdirectory, or
#   - $WORKSPACE/memory has any .md files, or
#   - $WORKSPACE/MEMORY.md exists with non-zero size.
fresh=1
if [[ -d /data/state/agents ]] && \
   [[ -n "$(ls -A /data/state/agents 2>/dev/null || true)" ]]; then
  fresh=0
fi
if [[ -d "$WORKSPACE/memory" ]] && \
   compgen -G "$WORKSPACE/memory/*.md" >/dev/null; then
  fresh=0
fi
if [[ -s "$WORKSPACE/MEMORY.md" ]]; then
  fresh=0
fi

if (( fresh == 0 )); then
  log "workspace/state non-empty — not a fresh instance; skipping restore"
  mark_done "$MARKER"
  exit 0
fi

# ---- Look for a snapshot in the bucket -------------------------------------
source /data/state/creds/oci-s3.env
BUCKET="$OCI_S3_BUCKET"

log "checking oci:${BUCKET}/snapshots/daily for a snapshot to restore"
# lsjson returns [] on empty dir. Sort by ModTime desc, take newest.
newest_json="$(sudo -u openclaw -H rclone lsjson \
    "oci:${BUCKET}/snapshots/daily" \
    --files-only 2>/dev/null || echo '[]')"

newest_name="$(echo "$newest_json" \
    | jq -r 'sort_by(.ModTime) | reverse | .[0].Name // empty')"

if [[ -z "$newest_name" ]]; then
  log "no snapshots in bucket — starting fresh (no restore needed)"
  mark_done "$MARKER"
  exit 0
fi

log "newest snapshot: $newest_name — restoring"

# ---- Download + extract ---------------------------------------------------
# Download as openclaw so bucket creds/rclone config are usable.
TMPDIR_R="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_R"' EXIT
archive="$TMPDIR_R/$newest_name"

sudo -u openclaw -H rclone copyto \
    "oci:${BUCKET}/snapshots/daily/$newest_name" "$archive" \
    --stats=15s --stats-one-line 2>&1 | tee -a "$LOG" >/dev/null \
    || die "rclone download failed for $newest_name"

# Verify it's a non-empty zstd tarball before nuking any state.
[[ -s "$archive" ]] || die "downloaded snapshot is empty: $archive"
file "$archive" | grep -q 'Zstandard' \
  || die "downloaded file is not zstd-compressed: $(file "$archive")"

# Extract as root (paths span /data owned by openclaw; tar preserves perms).
log "extracting $archive into /"
tar --zstd -xf "$archive" -C / >>"$LOG" 2>&1 \
  || die "tar extraction failed"

# Ownership correction — tar preserves uids from the snapshot host, which
# *should* match (openclaw=1001 typically) but we don't rely on that.
chown -R openclaw:openclaw /data/state "$WORKSPACE"

# Quick sanity probe. Agent sessions dir is the clearest marker of a real
# state restore.
if [[ -d /data/state/agents ]] && \
   [[ -n "$(ls -A /data/state/agents 2>/dev/null || true)" ]]; then
  log "restore OK — agent state present in /data/state/agents"
else
  warn "restore extracted but /data/state/agents is empty (was the snapshot stateful?)"
fi

# Record what we restored for the audit trail.
{
  echo "restored_from=$newest_name"
  echo "restored_ts=$(date -Is)"
  echo "bucket=$BUCKET"
} > "$STATE_DIR/restore-provenance"

mark_done "$MARKER"
log "restore OK (from $newest_name)"
