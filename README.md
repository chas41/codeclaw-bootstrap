# codeclaw-bootstrap

Idempotent first-boot installer for codeclaw-v2 OpenClaw instances.

Invoked by cloud-init on first boot. Also re-runnable any time — every step
is a separate script with its own idempotency check, so a partial run can
be resumed by simply running `install.sh` again.

## Why separate from codeclaw-v2

The infra repo (`codeclaw-v2`) handles Terraform/OCI. This repo handles
everything above the OS — OpenClaw, acpx, systemd units, workspace layout,
backups. Decoupled so Terraform can rebuild infra without touching
installation, and OpenClaw upgrades don't require a Terraform apply.

## Layout

```
codeclaw-bootstrap/
├── README.md
├── install.sh           Orchestrator — sources lib/common.sh, runs steps/ in order
├── lib/
│   └── common.sh        Shared helpers: log/die, markers, cfg, wait_for_*
└── steps/
    ├── 00-preflight.sh  Network/apt ready, yq install, required config fields, /data mounted
    ├── 10-packages.sh   apt deps, Node 22, rclone, Bitwarden CLI, Playwright
    ├── 20-workspace.sh  openclaw user, /data layout, symlinks, Chromium cache
    ├── 30-openclaw.sh   OpenClaw CLI (version-resolved + recorded)
    ├── 31-acpx.sh       acpx CLI (version-resolved + recorded)
    ├── 40-creds.sh      Render creds + rclone.conf from config.yaml
    ├── 50-skills.sh     ClawHub skills from config.skills.extra[]
    ├── 60-systemd.sh    openclaw-gateway.service + openclaw-sync.{service,timer}
    ├── 70-hooks.sh      Nightly snapshot timer + logrotate
    ├── 80-restore.sh    Auto-restore from OCI snapshot if fresh instance
    ├── 90-doctor.sh     Hard gate — nine check categories
    ├── 95-enable.sh     systemctl enable --now (gateway, then timers)
    └── 99-smoke.sh      Post-start probes + completion marker
```

## Entry point

```
install.sh [--config /etc/codeclaw/config.yaml] [--sha <git-sha>]
           [--only STEP[,STEP...]] [--skip STEP[,STEP...]] [--reset]
```

- `--config` path to `config.yaml` (default `/etc/codeclaw/config.yaml`,
  rendered by Terraform and dropped in place by cloud-init)
- `--sha` git SHA of this bootstrap checkout (recorded in logs and at
  `$STATE_DIR/provenance` for audit)
- `--only 30,31` run only these numbered steps (debugging)
- `--skip 80` skip a step (e.g. skip restore on a known-fresh deploy)
- `--reset` clear all idempotency markers (force full re-run)

## Contract

`install.sh` guarantees:

1. **Idempotent.** A second run on a healthy instance converges to no-op
   except for reads, log lines, and credentials (which re-render so
   `config.yaml` stays authoritative on rotation).
2. **Resumable.** Each step carries its own marker under
   `/var/lib/codeclaw-bootstrap/done.<marker>`; a partial run resumes from
   the last failed step.
3. **Logs everything** to `/var/log/codeclaw-bootstrap.log` with
   timestamps and step tags.
4. **Exits non-zero** on unrecoverable errors, and only those — warnings
   for degradable conditions don't fail the run.

## Inputs (config.yaml)

Rendered by Terraform, delivered via cloud-init to
`/etc/codeclaw/config.yaml`. Required fields validated at preflight:

```yaml
instance_name: oc-codeclaw-<name>
workspace_root: /data/workspace
openclaw:
  version: "2026.4.14"            # explicit pin; recorded on first install
openrouter:
  inference_key: <injected>
  mgmt_key: <injected>
backup:
  bucket: <oci-bucket-name>
  namespace: <tenancy-namespace>
  access_key_id: <injected>
  secret_access_key: <injected>
  region: <oci-region>             # e.g. us-phoenix-1
agent:
  id: primary
  dm_scope: per-channel-peer
  exec_host: sandbox
  browser_profile: user

# Optional
skills:
  extra:                           # ClawHub slugs; bundled skills are free
    - name: some-skill
      version: "1.2.3"             # omit for latest
channels:
  telegram:
    enabled: true
    bot_token: <injected>
bitwarden:
  server_url: <self-hosted-url>    # only if not bitwarden.com
```

## Layout on disk (after bootstrap)

```
/data/state/                       Durable runtime state (symlinked to ~openclaw/.openclaw)
  agents/<id>/sessions/*.jsonl
  logs/gateway.jsonl
  creds/
    openrouter.env                 EnvironmentFile= for gateway
    oci-s3.env                     rclone + backup scripts
/data/workspace/                   Agent-visible workspace (symlinked to ~openclaw/workspace)
  memory/YYYY-MM-DD.md
  MEMORY.md
  skills/                          ClawHub-installed skills (bundled skills live in the npm pkg)
  files/
    uploads/                       Bucket-authoritative (inbound from operators)
/var/lib/codeclaw-bootstrap/       Bootstrap state (markers, recorded paths, provenance)
  done.<marker>
  openclaw-version
  openclaw-bin
  acpx-version
  acpx-bin
  provenance
  restore-provenance               (only if step 80 restored)
  bootstrap-complete               (only if step 99 succeeded)
/var/log/codeclaw-bootstrap.log    Full run log (rotated weekly, 8 kept)
/etc/systemd/system/
  openclaw-gateway.service
  openclaw-sync.service
  openclaw-sync.timer              10min
  openclaw-snapshot.service
  openclaw-snapshot.timer          03:00 UTC daily
/usr/local/bin/
  openclaw-sync                    Live sync script
  openclaw-snapshot                Nightly tarball script
  bw-unlock                        Operator-run Bitwarden session helper
```

## Backup / restore model

Two complementary mechanisms, both to the same OCI bucket:

- **Live sync** (10 min): one-way `rclone sync` per subtree. Outbound
  `memory/`, `files/` (excluding `uploads/`), `MEMORY.md`. Inbound
  `files/uploads/` (bucket-authoritative). No bisync — deliberately
  picking a direction per subtree is safer.
- **Nightly snapshot** (03:00 UTC): `tar --zstd -T0` of `/data/state` +
  `$WORKSPACE` (excluding `uploads/`, `node_modules`, `.cache`,
  `ms-playwright`). Uploaded to `snapshots/daily/`; Sunday also promoted
  to `snapshots/weekly/`. Retention: 14 daily, 8 weekly, pruned via
  `rclone delete --min-age` — logic lives with the code.

On a fresh instance, step 80 auto-extracts the newest daily snapshot
before services start. Step 95 then enables the sync timer which pulls
any delta since the snapshot was taken.

## Invariants

Step 00 (preflight) enforces:

- `config.yaml` has every required field. Missing fields fail fast here,
  not mysteriously three steps later.
- `/data` is a mountpoint. If the 100GB data volume isn't attached, a
  "successful" bootstrap would silently put workspace on the 50GB root
  disk and lose everything on rebuild.
- `workspace_root` is under `/data`. Same reason.

Step 90 (doctor) enforces, before any service runs:

- Binaries present at their recorded paths (the `/usr/bin` vs
  `/usr/local/bin` v1 landmine).
- Credential files 0600, openclaw-owned, non-empty.
- `rclone lsd oci:${bucket}` works end-to-end.
- All systemd unit files pass `systemd-analyze verify`.
- `openclaw doctor` reports clean.

If step 90 fails, step 95 does NOT run — no restart-looping gateway.

## Operator one-time setup

After `install.sh` completes, one interactive step remains (NOT done by
bootstrap — requires master password + 2FA):

```
sudo -u openclaw bw-unlock
```

This caches `BW_SESSION` at `~openclaw/.config/openclaw/bw-session` for
later systemd `EnvironmentFile=` use.

## Provenance

Every run records:

- `$STATE_DIR/provenance` — git SHA, timestamp, config path, instance name.
- `$STATE_DIR/bootstrap-complete` — sha, completion ts, openclaw version,
  smoke-issue count.
- `$STATE_DIR/restore-provenance` — if step 80 restored, records the
  source snapshot filename + bucket.

## Debug workflow

Rerun a single step:

```
sudo /opt/codeclaw-bootstrap/install.sh --only 60
```

Force everything to re-run:

```
sudo /opt/codeclaw-bootstrap/install.sh --reset
```

Inspect a failure:

```
tail -200 /var/log/codeclaw-bootstrap.log
journalctl -u openclaw-gateway.service -n 100
```

## Version bumps

- **OpenClaw**: edit `config.yaml.openclaw.version` and re-run. Step 30
  detects the delta and upgrades in place.
- **acpx**: same pattern, `config.yaml.acpx.version`.
- **Node / rclone**: edit the pinned constants at the top of
  `steps/10-packages.sh` and bump the `MARKER` suffix (e.g. `.v1` → `.v2`)
  to force a re-run of the step.
- **Bitwarden CLI**: edit `BW_VERSION` in `steps/10-packages.sh`. Installed
  via `npm install -g @bitwarden/cli@${BW_VERSION}` (upstream doesn't ship
  a native linux-arm64 binary, so the JS CLI is the portable option).
- **yq**: edit `YQ_VERSION` + `YQ_SHA` in `steps/00-preflight.sh`.
