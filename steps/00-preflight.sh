#!/usr/bin/env bash
# 00-preflight — verify the environment before we touch anything.
#
# What this step does:
#   1. Wait for network (v1 lesson: apt-get update lies on DNS failure).
#   2. Wait for apt lock (cloud-init races unattended-upgrades).
#   3. Confirm required CLI tools exist (or install them via apt).
#   4. Validate config.yaml has every required field.
#   5. Confirm /data is mounted (workspace MUST live on data volume).
#
# Re-runnable: safe to run any time. The network + apt-lock waits are cheap
# on a healthy instance. Binary checks and config validation must pass every
# run — they're not markered.

source "$CODECLAW_ROOT/lib/common.sh"

# --- Wait for apt + network ---
wait_for_network
wait_for_apt_lock

# --- Install minimal bootstrap toolchain if missing ---
# `yq` is not in Ubuntu 24.04 default repos — fetch the Go rewrite from its
# official github releases. apt's `yq` is a different Python tool with
# incompatible syntax; using it here silently produces wrong config values.
need_apt=()
for b in curl jq git ufw xfsprogs ca-certificates gnupg; do
  command -v "$b" >/dev/null 2>&1 || need_apt+=("$b")
done
if (( ${#need_apt[@]} > 0 )); then
  log "installing apt deps: ${need_apt[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_apt[@]}"
fi

if ! command -v yq >/dev/null 2>&1; then
  log "installing yq (Go rewrite) from github"
  # Verified from upstream checksums file (column 18 = SHA-256) on 2026-04-14.
  # To rotate: curl -sL https://github.com/mikefarah/yq/releases/download/<ver>/checksums
  # then pick the SHA-256 column per checksums_hashes_order.
  YQ_VERSION="v4.44.3"
  YQ_SHA="0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156"
  fetch_verified \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_arm64" \
    "$YQ_SHA" \
    /usr/local/bin/yq
fi

# --- systemctl present (we'll need it everywhere) ---
command -v systemctl >/dev/null || die "systemctl missing — not a systemd host?"

# --- Required config fields ---
# Each of these is referenced downstream. Failing here means the step that
# needs the field won't mysteriously crash with 'unbound variable'.
required=(
  .instance_name
  .workspace_root
  .openrouter.inference_key
  .openrouter.mgmt_key
  .backup.bucket
  .backup.namespace
  .backup.access_key_id
  .backup.secret_access_key
  .backup.region
  .agent.id
  .agent.dm_scope
  .agent.exec_host
  .agent.browser_profile
)
for f in "${required[@]}"; do
  cfg_required "$f" >/dev/null
done

INSTANCE=$(cfg_required .instance_name)
WORKSPACE=$(cfg_required .workspace_root)
log "instance=$INSTANCE workspace=$WORKSPACE"

# --- Invariant: workspace on data volume ---
# The whole point of the 100GB data volume is that workspace survives
# instance recreation. If /data isn't mounted, a "successful" bootstrap would
# quietly put everything on the root disk and we'd lose it on rebuild.
mountpoint -q /data || die "/data not mounted — refusing to continue"

case "$WORKSPACE" in
  /data/*) : ;;
  *) die "workspace_root ($WORKSPACE) is not under /data — data loss risk on rebuild" ;;
esac

# --- Record provenance ---
cat > "$STATE_DIR/provenance" <<EOF
bootstrap_sha=$REPO_SHA
bootstrap_ts=$(date -Is)
config_path=$CONFIG
instance_name=$INSTANCE
EOF

log "preflight OK"
