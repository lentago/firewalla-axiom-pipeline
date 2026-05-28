# firewalla-axiom-pipeline

Ship DNS, connection flow, and TLS handshake logs from a Firewalla Gold SE to [Axiom](https://axiom.co) for long-term retention, search, and dashboarding — at zero recurring cost.

**Authorship:** The Fluent Bit configs, bash scripts, APL queries, and documentation in this repo are co-written with [Claude](https://claude.ai) (Anthropic). I direct the work and review the output; Claude writes the code. I'm an infrastructure operator, not a software engineer — please don't read this repo as a portfolio of coding ability.

## What this does

Your Firewalla app shows you what domains each device visits, but the data rotates off the device quickly. This pipeline captures that same data (Zeek DNS, connection, and SSL logs) and ships it to Axiom's cloud, giving you:

- **30-day searchable history** of every DNS query, flow, and TLS handshake on your network
- **Per-device drill-down** dashboards (select a device, see its domains and TLS SNIs)
- **HTTPS visibility** via SSL/TLS handshake metadata (SNI, cert chain fingerprints) — what was actually connected to, not just looked up
- **Device name resolution** via automated Redis inventory export
- **Firmware-update resilience** using Firewalla's `post_main.d` persistence
- **Self-healing config changes** via a 5-minute GitOps poller — merge a PR to `main`, the Firewalla picks it up
- **~50 MB RAM overhead** on the Firewalla

Total cost: **$0/month** (Axiom free tier: 500 GB/month, 30-day retention)

The same Fluent Bit instance optionally fans out to a LAN Loki receiver (see [§Optional: dual-output to Grafana Cloud](#optional-dual-output-to-grafana-cloud)) — Axiom is the primary, long-retention destination; Loki is the live dashboard pane.

## Architecture

![Pipeline Architecture](docs/architecture.svg)


## Prerequisites

- **Firewalla Gold SE** (Gold Pro or Purple SE should also work — untested)
- **SSH access** enabled (Firewalla app → Settings → Advanced → SSH)
- **Docker** started on the Firewalla (`sudo systemctl start docker && sudo systemctl enable docker`)
- **Axiom account** (free at [app.axiom.co](https://app.axiom.co))

## Quick start

### 1. Create Axiom datasets and API token

1. Sign up at [app.axiom.co](https://app.axiom.co)
2. Create two datasets:
   - `firewalla` (or your preferred name — for log events)
   - `firewalla-devices` (for the device lookup table)
3. Go to **Settings → API Tokens → New API Token**
4. Name it `firewalla-ingest`, grant **Ingest** permission, copy the token

### 2. Clone this repo and configure

```bash
git clone https://github.com/PitziLabs/firewalla-axiom-pipeline.git
cd firewalla-axiom-pipeline

# Create your local env file (not committed to git)
cp env.example .env
nano .env
# Fill in your Axiom dataset names and API token
```

### 3. Place the secrets on the Firewalla

`.env` (your Axiom credentials) is the only thing that has to land on the device by hand — git never sees it. Future config changes flow through GitOps, no SSH required.

```bash
export FW_IP=192.168.1.1   # your Firewalla's LAN address
scp .env pi@${FW_IP}:/home/pi/.firewalla/config/log_shipping.env
```

### 4. Bootstrap

```bash
ssh pi@${FW_IP} 'curl -sSL https://raw.githubusercontent.com/PitziLabs/firewalla-axiom-pipeline/main/scripts/bootstrap.sh | bash'
```

`scripts/bootstrap.sh` clones this repo to `/home/pi/.firewalla/firewalla-axiom-pipeline/`, copies the config tree into `/home/pi/.firewalla/config/`, installs the crontab (which includes the 5-min GitOps poller), and starts the Fluent Bit container. One-time only — after this, the device self-syncs from `main`.

### 5. Verify

```bash
# Container running and shipping
ssh pi@${FW_IP} 'sudo docker logs --tail 20 fluent-bit-axiom'

# GitOps poller has seen origin (look for a recent "Deploy complete" or empty log = up-to-date)
ssh pi@${FW_IP} 'tail -20 /home/pi/.firewalla/config/gitops-sync.log 2>/dev/null || echo "(log empty — clean no-ops)"'
```

Then open Axiom **Stream** view on the `firewalla` dataset; you should see DNS, connection, and SSL events within a minute or two.

## GitOps auto-deploy

Once bootstrapped, the Firewalla keeps itself in sync with `origin/main`. The normal change workflow is: open a PR → merge → wait up to 5 minutes for the device to pick it up.

**How the loop works.** `cron/user_crontab` schedules `scripts/gitops-sync.sh` every 5 minutes. The script:

1. `git fetch origin` in the on-device clone at `/home/pi/.firewalla/firewalla-axiom-pipeline/`.
2. If `HEAD == origin/main`: silent exit.
3. Otherwise: capture a rollback SHA, `git reset --hard origin/main`, classify
   the diff (fluent-bit config? crontab? scripts? docs?), and act only on the
   files that matter.
4. **Validate** any new `fluent-bit/*.conf` via `fluent-bit --dry-run` in a
   throwaway container *before* swapping the live files.
5. On validation pass: copy configs into `/home/pi/.firewalla/config/`, run
   `docker restart fluent-bit-axiom`, reinstall crontab if it changed.
6. On validation fail: `git reset --hard <rollback-sha>` and log the dry-run
   output. The live container keeps running on the last-known-good config.

Typical deploy wall-clock for a config change: **~2 seconds** (dry-run + file copy + container restart). The Loki output sees a sub-3-second backlog flush; Axiom output is uninterrupted.

**Log:** `/home/pi/.firewalla/config/gitops-sync.log` — timestamped, leveled, rotates at 1 MB to `.log.1`. No-ops are suppressed; expect quiet days. The log is the first place to look when a merge didn't seem to take.

**Secrets stay device-local.** `log_shipping.env` is never touched by sync. If you rotate the Axiom token, scp the new env file manually (see [§Manual / break-glass deploy](#manual--break-glass-deploy)).

**Break-glass.** `deploy.sh <fw-ip>` from a workstation still works for the rare case where you need to push from a non-`main` branch (e.g., debugging a poller bug that's blocking the loop). See the appendix.

## File layout

```
firewalla-axiom-pipeline/
├── README.md
├── LICENSE
├── env.example                          # Template for credentials
├── fluent-bit/
│   ├── fluent-bit.conf                  # Main Fluent Bit configuration
│   └── parsers.conf                     # Zeek log parser definitions
├── scripts/
│   ├── start_log_shipping.sh            # Docker bootstrap (post_main.d)
│   ├── device_lookup_export.sh          # Redis → Axiom device inventory
│   ├── device_group_upload.sh           # Group metadata helper
│   ├── fluent_bit_healthcheck.sh        # Wedged-container restarter (cron)
│   ├── gitops-sync.sh                   # 5-min poll → fetch → validate → reload
│   └── bootstrap.sh                     # One-time on-device setup
├── cron/
│   └── user_crontab                     # Persistent cron jobs
├── dashboards/
│   └── axiom-queries.md                 # Saved APL queries for Axiom
├── docs/
│   └── zeek-field-reference.md          # Complete Zeek JSON field reference
└── deploy.sh                            # One-command deploy script
```

## Axiom dashboard setup

See [dashboards/axiom-queries.md](dashboards/axiom-queries.md) for the complete set of APL queries, including:

- Top domains across all devices
- Per-device domain breakdown (with device name resolution)
- DNS activity over time
- Dashboard filter bar configuration for device drill-down

## Optional: dual-output to Grafana Cloud

The shipped `fluent-bit.conf` has **two outputs** active:

| Output | Destination | Purpose |
|---|---|---|
| `[OUTPUT] http` (line ~111) | Axiom HTTPS API | Long-retention search, dashboards, primary durable copy |
| `[OUTPUT] loki` (line ~134) | LAN Loki receiver at `192.168.139.20:3100` | Live dashboards / alerting via Grafana Cloud (relayed by an Alloy container in [homelab-observability](https://github.com/PitziLabs/homelab-observability)) |

The two outputs are independent — each retries on its own, and an outage on one side does not affect the other. `Retry_Limit False` on both means a peer outage self-heals without operator intervention once connectivity returns (the fix from [#43](https://github.com/PitziLabs/firewalla-axiom-pipeline/issues/43)).

If you don't run a LAN Loki receiver, either:
- Edit the Loki block's `Host`/`Port` to point at your own Loki/Promtail/Vector endpoint, or
- Comment out the `[OUTPUT] loki` block entirely.

The Loki output is the one place in this repo where a LAN-specific address (`192.168.139.20`) is baked into config — if you're using this template on a different network, this is the line to change.

## Firewalla internals

This pipeline relies on the following Firewalla data sources:

| Source | Path | Contents |
|--------|------|----------|
| Zeek DNS log | `/bspool/manager/dns.log` | Every DNS query: source IP, domain, query type, response |
| Zeek conn log | `/bspool/manager/conn.log` | Every connection: source, dest, port, bytes, duration |
| Zeek SSL log | `/bspool/manager/ssl.log` | Every TLS handshake: SNI, version, cipher, JA3-style ssl_history, cert chain fingerprints |
| ACL audit log | `/alog/acl-audit.log` | Blocked connections from Firewalla iptables rules (kernel `FW_ADT` lines, syslog-format) |
| Redis device inventory | `redis-cli hgetall host:mac:*` | IP, MAC, device name, DHCP name, interface |

### Persistence across firmware updates

Firewalla uses an overlay filesystem — most changes are wiped on reboot or firmware update. The only reliable persistent paths are under `/home/pi/.firewalla/config/`. Scripts in `post_main.d/` run automatically after every boot and firmware update. Docker containers with `--restart always` survive normal reboots; the `post_main.d` script handles the edge case of a full overlay reset.

### Zeek log format

On recent firmware, Zeek logs are written as **JSON** (not TSV). Key fields in `dns.log`:

- `id.orig_h` — source device IP
- `id.resp_h` — DNS server IP
- `query` — the domain name queried
- `qtype_name` — query type (A, AAAA, CNAME, etc.)
- `answers` — DNS response

Note: field names contain dots (e.g., `id.orig_h`), which requires bracket notation in APL: `parsed["id.orig_h"]`.

For the complete field reference covering all `dns.log` and `conn.log` fields, gotchas, and example raw events, see **[docs/zeek-field-reference.md](docs/zeek-field-reference.md)**.

## Troubleshooting

### A merged PR didn't deploy

The Firewalla's GitOps poller logs to `/home/pi/.firewalla/config/gitops-sync.log`. Tail it after a merge to see why:

```bash
ssh pi@<fw-ip> tail -30 /home/pi/.firewalla/config/gitops-sync.log
```

Expected sequence on a successful config change:

```
[ts] [INFO] Applying N commit(s) <old>..<new>:
[ts] [INFO]   <sha> <commit subject>
[ts] [INFO] Validating new fluent-bit config via dry-run
[ts] [INFO] Dry-run OK
[ts] [INFO] Restarting fluent-bit-axiom
[ts] [INFO] Deploy complete at <sha>
```

Failure modes:

- `Dry-run FAILED — rolling back.` → your new `fluent-bit/*.conf` doesn't parse. The log shows the fluent-bit error. Live container keeps serving on the previous SHA.
- `git fetch failed` → Firewalla can't reach GitHub. Check WAN, then `ssh pi@<fw-ip> 'git -C /home/pi/.firewalla/firewalla-axiom-pipeline ls-remote origin'`.
- `docker: permission denied` → cron's `pi` user lost docker-group access. The script uses `sudo docker` to work around this; if it broke, check `getent group docker` includes `pi` and `sudo -n -l` works for the docker binary.
- Log is empty / nothing happens → the poller cron isn't installed. `ssh pi@<fw-ip> crontab -l | grep gitops-sync`.

### Data stopped flowing

```bash
# Check container status
sudo docker ps -a

# Check for errors
sudo docker logs --tail 50 fluent-bit-axiom

# Restart the container
sudo docker restart fluent-bit-axiom
```

Common causes:
- **HTTP 503 errors**: Axiom outage — restart the container once Axiom is back
- **Container missing**: Firmware update wiped Docker — run `start_log_shipping.sh`
- **No log files**: Check `ls -la /bspool/manager/dns.log` exists
- **/bspool full**: See below — this is the most common issue on busy networks

### /bspool tmpfs full (the #1 gotcha)

Zeek writes to `/bspool`, a **30 MB tmpfs** (RAM disk). Every 3 minutes, Zeek rotates active logs into timestamped copies like `dns.2026-03-11-21-24-00.log`. On a busy network (90+ devices), these rotated files can fill the tmpfs in hours. When it hits 100%, Zeek stops writing entirely and your pipeline goes silent.

Symptoms:
- `df -k /bspool/manager/` shows 100% usage
- `dns.log` has stale timestamps (days old)
- Fluent Bit is running but shipping no new data

Fix:
```bash
# Delete rotated logs
sudo rm /bspool/manager/*.2026-*.log

# Reboot to restart Zeek cleanly (don't use zeekctl directly)
sudo reboot
```

Prevention: The `user_crontab` in this repo includes a cleanup job that runs every 5 minutes, deleting rotated log files older than 5 minutes. Fluent Bit reads from active logs in real time and never needs the rotated copies. If you deployed before this fix was added, update your crontab:

```bash
scp cron/user_crontab pi@<firewalla-ip>:/home/pi/.firewalla/config/
ssh pi@<firewalla-ip> "crontab /home/pi/.firewalla/config/user_crontab"
```

**Important**: Never restart Zeek via `zeekctl restart` on a Firewalla — it doesn't work reliably due to the overlay filesystem. Always use `sudo reboot` instead.

### Container won't start after firmware update

```bash
sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
```

### Fluent Bit running but no data flowing (stale position tracker)

Zeek logs live on a tmpfs that's recreated on every reboot. Fluent Bit tracks
its read position in `.db` files so it doesn't re-read old data. After a reboot,
those position files point to byte offsets in files that no longer exist, so
Fluent Bit silently reads nothing.

The `start_log_shipping.sh` script now automatically wipes the position tracker
on every startup, so this should be self-healing. If you somehow hit it anyway:

```bash
sudo docker rm -f fluent-bit-axiom
sudo rm -rf /home/pi/.firewalla/config/fluent-bit-data/*
sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
```

### Check RAM usage

```bash
sudo docker stats fluent-bit-axiom --no-stream
```

### Verify Zeek logs are being written

```bash
tail -5 /bspool/manager/dns.log
```

## Manual / break-glass deploy

GitOps assumes the Firewalla can reach GitHub and that the poller itself isn't broken. When either of those assumptions fails (or you're bootstrapping the box for the first time without `curl | bash`), `deploy.sh` from the workstation does the full sync:

```bash
cp env.example .env   # fill in your Axiom dataset + token
./deploy.sh <firewalla-ip>
```

What it does, step by step:

1. Validates the local `.env`.
2. SSHs to the Firewalla, creates `/home/pi/.firewalla/config/post_main.d/` and `/home/pi/.firewalla/config/fluent-bit-data/`.
3. `scp`s `fluent-bit/*.conf`, `scripts/*.sh`, `cron/user_crontab`, and `.env` (as `log_shipping.env`) to the device.
4. Sets executable bits.
5. Runs `start_log_shipping.sh` to (re)start the Fluent Bit container.
6. Installs the crontab and runs an initial device export.

`deploy.sh` does **not** clone the repo or install the GitOps poller's target directory. If you used `deploy.sh` to bootstrap from scratch (no `bootstrap.sh`), follow up with:

```bash
ssh pi@<fw-ip> 'git clone https://github.com/PitziLabs/firewalla-axiom-pipeline.git /home/pi/.firewalla/firewalla-axiom-pipeline'
```

After that, the cron poller (already in `user_crontab`) will start syncing every 5 min.

## Contributing

This was built for a specific home network setup (Firewalla Gold SE → Axiom). PRs welcome for:

- Support for other Firewalla models (Purple SE, Gold Pro)
- Additional log sources (ssl.log, http.log, files.log)
- Grafana Cloud as an alternative destination
- IPv6 device name resolution
- Terraform/IaC for Axiom dataset and dashboard provisioning

## Related

- **[PitziLabs/homelab-observability](https://github.com/PitziLabs/homelab-observability)** — Grafana Cloud + Alloy observability stack for the Firewalla home network
- **[PitziLabs/workstation-bootstrap](https://github.com/PitziLabs/workstation-bootstrap)** — Workstation bootstrap scripts for the same homelab environment
- **[PitziLabs/foundry-platform-demo](https://github.com/PitziLabs/foundry-platform-demo)** — Terraform AWS lab — same infrastructure-as-portfolio philosophy

## License

MIT License — see [LICENSE](LICENSE).

## Credits

See the Authorship note at the top — the code in this repo is co-written with [Claude](https://claude.ai) (Anthropic). The work spanned multi-session pair-programming with live debugging on the Firewalla over SSH, Fluent Bit container troubleshooting, Axiom APL query development, and the discovery that Zeek lowercases MACs while Redis stores them uppercase.

## Acknowledgments

- [mbierman's syslog forwarding gist](https://gist.github.com/mbierman/f3d184b65e0f4de6fa75a4a5d5145426) — the OG Firewalla log export reference
- [Firewalla open source repo](https://github.com/firewalla/firewalla) — for understanding the internal data model
- The Firewalla community forum regulars who've been asking for this since 2019
