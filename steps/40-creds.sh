#!/usr/bin/env bash
# 40-creds — render credentials from config.yaml to disk.
#
# What lives where:
#
#   /data/state/creds/openrouter.env   OPENROUTER_API_KEY, OPENROUTER_MGMT_KEY
#   /data/state/creds/oci-s3.env       S3 creds for backup scripts
#   ~openclaw/.config/rclone/rclone.conf   rclone remote "oci" -> OCI S3 endpoint
#
# All files are 0600 openclaw:openclaw. Systemd units in step 60 load the
# .env files via EnvironmentFile=. Backup cron in step 70 reads oci-s3.env.
#
# Bitwarden login is NOT performed here — master password + 2FA is
# interactive and belongs to the operator runbook. We just make sure the bw
# binary is on PATH (step 10) and drop a helper script the operator runs
# once per instance to unlock and cache a session key.
#
# Re-runnable: every write is `install -m 0600` which overwrites atomically.
# Marker skipped intentionally — credentials may rotate; letting the step
# run each invocation ensures config.yaml is authoritative.

source "$CODECLAW_ROOT/lib/common.sh"

CREDS_DIR=/data/state/creds
install -d -o openclaw -g openclaw -m 0700 "$CREDS_DIR"

# ---- OpenRouter -----------------------------------------------------------
OR_INFERENCE="$(cfg_required .openrouter.inference_key)"
OR_MGMT="$(cfg_required .openrouter.mgmt_key)"

# Write atomically via temp file in same dir — avoids a half-written file
# being read by a concurrent systemd restart.
tmp="$(mktemp --tmpdir="$CREDS_DIR" .openrouter.XXXX)"
cat > "$tmp" <<EOF
# Rendered by 40-creds from config.yaml. Do not edit — next bootstrap run
# will overwrite. Update via config.yaml and re-run install.sh.
OPENROUTER_API_KEY=$OR_INFERENCE
OPENROUTER_MGMT_KEY=$OR_MGMT
EOF
chown openclaw:openclaw "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$CREDS_DIR/openrouter.env"
log "wrote $CREDS_DIR/openrouter.env"

# ---- OCI S3 (object storage) ---------------------------------------------
S3_BUCKET="$(cfg_required .backup.bucket)"
S3_NAMESPACE="$(cfg_required .backup.namespace)"
S3_AK="$(cfg_required .backup.access_key_id)"
S3_SK="$(cfg_required .backup.secret_access_key)"
S3_REGION="$(cfg_required .backup.region)"
S3_ENDPOINT="https://${S3_NAMESPACE}.compat.objectstorage.${S3_REGION}.oraclecloud.com"

tmp="$(mktemp --tmpdir="$CREDS_DIR" .oci-s3.XXXX)"
cat > "$tmp" <<EOF
# Rendered by 40-creds from config.yaml. Do not edit.
# Consumed by backup cron (step 70) and any ad-hoc rclone invocations.
AWS_ACCESS_KEY_ID=$S3_AK
AWS_SECRET_ACCESS_KEY=$S3_SK
AWS_DEFAULT_REGION=$S3_REGION
OCI_S3_BUCKET=$S3_BUCKET
OCI_S3_NAMESPACE=$S3_NAMESPACE
OCI_S3_ENDPOINT=$S3_ENDPOINT
EOF
chown openclaw:openclaw "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$CREDS_DIR/oci-s3.env"
log "wrote $CREDS_DIR/oci-s3.env"

# ---- rclone config (openclaw user) ----------------------------------------
# rclone reads ~/.config/rclone/rclone.conf by default. We render it once
# here so `rclone lsd oci:` works without env-var gymnastics.
#
# Provider = Other + force_path_style = true: OCI's S3-compat endpoint
# requires path-style addressing (virtual-host doesn't resolve under
# namespace subdomains). v1 lesson.
RCLONE_DIR=/home/openclaw/.config/rclone
install -d -o openclaw -g openclaw -m 0700 "$RCLONE_DIR"

tmp="$(mktemp --tmpdir="$RCLONE_DIR" .rclone.XXXX)"
cat > "$tmp" <<EOF
# Rendered by 40-creds. Do not edit — re-run bootstrap to update.
[oci]
type = s3
provider = Other
env_auth = false
access_key_id = $S3_AK
secret_access_key = $S3_SK
endpoint = $S3_ENDPOINT
region = $S3_REGION
force_path_style = true
no_check_bucket = true
EOF
chown openclaw:openclaw "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$RCLONE_DIR/rclone.conf"
log "wrote $RCLONE_DIR/rclone.conf"

# ---- Verify rclone can see the bucket -------------------------------------
# Cheap sanity check — catches typos in namespace/region early. `rclone lsd`
# lists directories at the root, which for the bucket means top-level
# "folders". Exit code is what we care about; output goes to the log.
log "verifying rclone -> oci:${S3_BUCKET}"
if sudo -u openclaw -H rclone lsd "oci:${S3_BUCKET}" >>"$LOG" 2>&1; then
  log "rclone reach-test OK"
else
  warn "rclone could not list oci:${S3_BUCKET} — check credentials/endpoint; step 90 will re-test"
fi

# ---- Bitwarden unlock helper ----------------------------------------------
# We deliberately do NOT store the master password. Instead, drop a helper
# that the operator runs once per instance:
#
#   sudo -u openclaw bw-unlock
#
# It prompts for the master password, caches a BW_SESSION in the openclaw
# user's shell env, and configures the server URL from config (if present).
HELPER=/usr/local/bin/bw-unlock
BW_SERVER="$(cfg .bitwarden.server_url)"
cat > "$HELPER" <<BWEOF
#!/usr/bin/env bash
# bw-unlock — interactive Bitwarden login/unlock for the openclaw user.
# Rendered by codeclaw-bootstrap/40-creds. Run as: sudo -u openclaw bw-unlock
set -euo pipefail
[[ "\$(id -un)" == "openclaw" ]] || { echo "run as openclaw" >&2; exit 1; }
${BW_SERVER:+bw config server "$BW_SERVER" >/dev/null}
if ! bw status | grep -q '"status":"unlocked"'; then
  if bw status | grep -q '"status":"unauthenticated"'; then
    bw login
  fi
  BW_SESSION="\$(bw unlock --raw)"
  mkdir -p /home/openclaw/.config/openclaw
  umask 077
  printf 'export BW_SESSION=%q\n' "\$BW_SESSION" \
    > /home/openclaw/.config/openclaw/bw-session
  echo "BW_SESSION cached at ~/.config/openclaw/bw-session"
  echo "Source it in systemd via EnvironmentFile= or in shell via source."
else
  echo "Bitwarden vault already unlocked."
fi
BWEOF
chmod 0755 "$HELPER"
log "wrote $HELPER (operator runs this once; not invoked by bootstrap)"

log "creds OK"
