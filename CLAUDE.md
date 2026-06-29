# CLAUDE.md — AI Assistant Guide for firewalla-axiom-pipeline

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a
brief self-introduction as **Axiom Pipeline Claude** — builder of the
Firewalla → Axiom log-shipping configs (Fluent Bit + gitops sync). The
appliance itself and on-device operations are Home Claude's turf — see
`~/CLAUDE.md`. One sentence is plenty; don't make a meal of it.

## What This Project Does

A log-shipping pipeline that captures DNS queries, connection flows, and ACL block events from a **Firewalla Gold SE** appliance and sends them to **Axiom** for 30-day searchable retention and dashboarding. Uses Axiom's free tier (500 GB/month) for zero recurring cost.

### Data Flow

```
Firewalla Zeek logs (dns/conn/ssl) + acl-audit ──► Fluent Bit (Docker) ──┬─► Axiom "firewalla" dataset           (HTTP output, primary)
                                                                          └─► LAN Loki receiver :3100             (loki output, optional)
                                                                                                                  └─► Grafana Cloud Loki
                                                                                                                       (via Alloy on LXC 105)
Redis device inventory ──► device_lookup_export.sh ──► Axiom "firewalla-devices" dataset
```

The Loki output is independent of the HTTP output — either path runs alone. The optional Loki receiver in our homelab is the Alloy container in [lentago/homelab-observability](https://github.com/lentago/homelab-observability); other consumers (Promtail, Vector, a self-hosted Loki) work too.

## Tech Stack

- **Fluent Bit** — Log collection agent (runs as Docker container on Firewalla)
- **Bash** — All scripts use `set -euo pipefail`
- **Zeek** — Log format (JSON on recent Firewalla firmware)
- **Redis** — Device inventory source on the Firewalla appliance
- **Axiom** — Cloud log analytics (APL query language, Kusto-like)
- **Docker** — Container runtime on Firewalla

## Project Structure

```
firewalla-axiom-pipeline/
├── CLAUDE.md                       # This file
├── README.md                       # User-facing docs, setup, troubleshooting
├── LICENSE                         # MIT
├── deploy.sh                       # Break-glass workstation deploy via SSH
├── env.example                     # Template for .env (AXIOM_DATASET, AXIOM_API_TOKEN)
├── .gitignore                      # Excludes .env, *.log, /tmp/
├── fluent-bit/
│   ├── fluent-bit.conf             # Inputs + Axiom output + Loki output
│   └── parsers.conf                # Zeek timestamp parser
├── scripts/
│   ├── bootstrap.sh                # One-time on-device clone + cron install
│   ├── gitops-sync.sh              # 5-min poll → fetch → validate → reload
│   ├── start_log_shipping.sh       # Docker bootstrap; lives in post_main.d/ on device
│   ├── fluent_bit_healthcheck.sh   # Cron-driven wedged-container restarter
│   ├── device_lookup_export.sh     # Redis → Axiom device inventory
│   └── device_group_upload.sh      # Group metadata helper
├── cron/
│   └── user_crontab                # Device export, log cleanup, healthcheck, gitops poll
├── dashboards/
│   └── axiom-queries.md            # APL queries for Axiom dashboards
└── docs/
    ├── architecture.svg            # Pipeline diagram
    └── zeek-field-reference.md     # Zeek JSON field reference
```

## Key Entry Points

| File | Purpose | Runs Where |
|------|---------|------------|
| `scripts/bootstrap.sh` | One-time on-device setup (clone + cron + container start) | Firewalla (manual, once) |
| `scripts/gitops-sync.sh` | Poll origin/main, validate, swap live files, restart container | Firewalla (cron, every 5 min) |
| `scripts/start_log_shipping.sh` | Starts Fluent Bit container; auto-runs after firmware updates | Firewalla (`post_main.d/`) |
| `scripts/fluent_bit_healthcheck.sh` | Restart wedged container based on log error rate | Firewalla (cron, every 5 min) |
| `scripts/device_lookup_export.sh` | Exports device names from Redis to Axiom | Firewalla (cron, hourly) |
| `fluent-bit/fluent-bit.conf` | Defines log inputs + Axiom HTTP output + LAN Loki output | Inside Fluent Bit container |
| `deploy.sh` | Break-glass workstation push (when GitOps is unusable) | Developer machine |

## Coding Conventions

### Bash Scripts
- Always start with `#!/usr/bin/env bash` and `set -euo pipefail`
- Log messages use bracketed prefixes: `[log-shipping]`, `[device-lookup]`
- Section headers use comment dividers: `# ── Section Name ──`
- Environment variables: `UPPER_SNAKE_CASE`
- Exit code `1` for all errors, with descriptive messages
- Validate preconditions early (e.g., check `.env` exists, Docker available)

### Fluent Bit Config
- INI-style format with `[INPUT]`, `[FILTER]`, `[OUTPUT]` sections
- Sensitive values via `${ENV_VAR}` substitution (never hardcoded)
- Each input gets a unique `Tag` for routing: `zeek.dns`, `zeek.conn`, `firewalla.acl`
- Metadata added via `record_modifier` filters

### Axiom / APL Queries
- Dataset names: `firewalla` (logs), `firewalla-devices` (device lookup)
- Bracket notation for dotted Zeek fields: `parsed["id.orig_h"]`
- Device enrichment via `join kind=leftouter` on device lookup dataset
- Filter bar parameters declared with `declare query_parameters()`

## Important Paths (on Firewalla)

| Path | Description |
|------|-------------|
| `/home/pi/.firewalla/config/` | Persistent config dir (survives firmware updates) |
| `/home/pi/.firewalla/config/post_main.d/` | Auto-run scripts after boot/firmware update |
| `/home/pi/.firewalla/firewalla-axiom-pipeline/` | On-device git clone managed by `gitops-sync.sh` |
| `/home/pi/.firewalla/config/gitops-sync.log` | GitOps poller log (1 MB rotation → `.log.1`) |
| `/home/pi/.firewalla/config/.gitops-sync.lock` | flock file preventing concurrent poller runs |
| `/bspool/manager/dns.log` | Zeek DNS log (tmpfs, 30 MB limit) |
| `/bspool/manager/conn.log` | Zeek connection log |
| `/alog/acl-audit.log` | Firewalla ACL block log (kernel iptables FW_ADT lines) |
| `/home/pi/.firewalla/config/log_shipping.env` | Deployed .env file on device (NEVER in git) |

## Environment Variables

Defined in `.env` (copied from `env.example`), never committed to git:

| Variable | Example | Used By |
|----------|---------|---------|
| `AXIOM_DATASET` | `firewalla` | fluent-bit.conf, device_lookup_export.sh |
| `AXIOM_API_TOKEN` | `xaat-...` | fluent-bit.conf, device_lookup_export.sh |
| `AXIOM_LOOKUP_DATASET` | `firewalla-devices` | device_lookup_export.sh |

## Development Workflow

### Making Changes
1. Edit config/scripts on a branch, open a PR, merge to `main`.
2. The Firewalla's GitOps poller picks up the change within 5 min — no SSH
   required for routine config changes.
3. Check `/home/pi/.firewalla/config/gitops-sync.log` to confirm the apply,
   and Axiom Stream view / Grafana for the data result.

### GitOps auto-deploy (the normal path)
`scripts/gitops-sync.sh` runs every 5 min from `cron/user_crontab`. It
fetches `origin/main`, validates any new `fluent-bit/*.conf` via
`fluent-bit --dry-run` in a throwaway container, then swaps live files in
`/home/pi/.firewalla/config/` and restarts `fluent-bit-axiom` only if the
relevant files changed. Validation failure → `git reset --hard` to the
rollback SHA; the live container is never disturbed by a bad commit.

`.env` / `log_shipping.env` is device-local and never touched by sync.

### Deployment (`deploy.sh`) — break-glass only
Workstation-driven push for the rare cases GitOps can't help (Firewalla
offline from GitHub, bad commit blocking the poller, first-time bootstrap
without `bootstrap.sh`). Steps:
1. Validates `.env` exists locally
2. Creates persistent directories on Firewalla via SSH
3. Copies all config files and scripts via SCP
4. Copies `.env` as `log_shipping.env`
5. Sets executable permissions on scripts
6. Runs `start_log_shipping.sh` to (re)start the container
7. Installs cron jobs from `cron/user_crontab`
8. Runs initial device lookup export

### Common Troubleshooting
- **No data in Axiom**: Check `docker logs fluent-bit-axiom` for auth errors
- **No data in Loki only (Axiom still flowing)**: Check `sudo ss -tn | grep :3100` for connections to the Alloy LXC. If absent and not retrying, restart fluent-bit: `sudo docker restart fluent-bit-axiom`. The pre-#43 cause (`Retry_Limit 3` on the Loki output giving up silently) is fixed; if you see it recur, suspect a different stuck-state.
- **A merged PR didn't deploy**: Tail `/home/pi/.firewalla/config/gitops-sync.log`. Look for `Dry-run FAILED` (bad config — rollback already happened, fix the PR), `git fetch failed` (WAN/GitHub), or nothing at all (poller cron not installed — `crontab -l | grep gitops-sync`).
- **bspool full**: The 5-min cron cleanup job handles rotated logs; verify it's running
- **Device names missing**: Run `device_lookup_export.sh` manually and check HTTP status

## Guidelines for AI Assistants

- **Never hardcode secrets** — use environment variables via `.env`
- **Preserve firmware-update resilience** — all persistent files go under `/home/pi/.firewalla/config/`
- **Keep resource usage low** — Firewalla is an appliance with limited RAM (~50 MB budget for this pipeline)
- **Maintain the strict bash style** — `set -euo pipefail`, prefixed log messages, early validation
- **Don't add dependencies** — the Firewalla has limited packages; only `bash`, `docker`, `curl`, `redis-cli`, `ssh`, `git`, `flock` are available
- **Test deploy.sh changes carefully** — it runs over SSH on a production network appliance
- **Keep .env out of git** — it's in `.gitignore`; use `env.example` as the template
- **Axiom free tier constraints** — 500 GB/month ingest, 30-day retention; avoid high-cardinality explosions
- **Cron + docker on Firewalla needs `sudo`** — the `pi` user is in the docker group via PAM at login, but cron sessions don't inherit it (this bit us in #48). Any new script invoked from `user_crontab` that touches docker must use `sudo docker`, not bare `docker`.
- **Retry_Limit on every fluent-bit OUTPUT is `False`** — finite retries with a long peer outage silently stop the output forever (#43). On-disk buffering bounds the backlog; leave the limit unbounded.
- **Changes to `scripts/gitops-sync.sh` itself need extra care** — a bug in the poller can either stop the loop or break future deploys. The `scripts/gitops-sync.sh|scripts/bootstrap.sh` case branch in the file classifier exists specifically so a script-only PR doesn't trigger a fluent-bit dry-run + restart. When changing the script, the safe rollout is: scp the new version to the on-device clone out-of-band, then merge the PR — that way the running poller picks up the fix immediately instead of needing one more cycle.

PR workflow + auto-merge arming protocol is fleet-wide; see `~/repos/CLAUDE.md`.

## CI/CD

- **ShellCheck** (`.github/workflows/shellcheck.yml`): Static analysis on every
  non-draft PR. Severity: warning+. Required status check.
- **Claude Code Review** (`.github/workflows/claude-code-review.yml`): Automated
  review focused on appliance safety, secret handling, dependency creep, and
  bash correctness. Required status check.
- **Claude Code** (`.github/workflows/claude.yml`): Triggered by `@claude` in
  issues/PR comments. Implements changes, creates PRs with auto-merge.
- **Auto-merge**: PRs merge automatically when ShellCheck and review pass.
