#!/usr/bin/env bash
# =============================================================================
# Firewalla System Metrics Exporter
#
# Collects host-level and per-Zeek-process metrics, then ships to Axiom as
# system_metrics events in the primary log dataset.
#
# Run every 5 minutes via cron. Each run posts a JSON batch containing:
#   - One event per Zeek process  (metric_scope="zeek_process")
#   - One box-level snapshot      (metric_scope="host")
#
# No docker calls, no sudo required — ps/free/df/awk all run as pi.
#
# Install location: /home/pi/.firewalla/config/system_metrics_export.sh
# =============================================================================

set -euo pipefail

CONFIG_DIR="/home/pi/.firewalla/config"
ENV_FILE="${CONFIG_DIR}/log_shipping.env"
TMPFILE="/tmp/system_metrics.json"

# ── Load environment variables ───────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

if [ -z "${AXIOM_DATASET:-}" ]; then
    echo "[system-metrics] ERROR: AXIOM_DATASET not set"
    exit 1
fi

if [ -z "${AXIOM_API_TOKEN:-}" ]; then
    echo "[system-metrics] ERROR: AXIOM_API_TOKEN not set"
    exit 1
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Collect host metrics ─────────────────────────────────────────────────────
MEM_TOTAL=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
MEM_USED=$(free -m 2>/dev/null | awk '/^Mem:/{print $3}')
MEM_AVAILABLE=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}')
LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
BSPOOL_PCT=$(df /bspool 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}' || echo "0")

# Count worker processes (zeek -i <iface> implies a worker).
# grep -c prints "0" itself on no match (exiting 1) — `|| true` satisfies
# pipefail without appending a second "0" line, which would corrupt the JSON.
ZEEK_WORKER_COUNT=$(ps -eo args 2>/dev/null \
    | grep -c '/usr/local/zeek/bin/[z]eek.*-i ' || true)

# ── Build JSON batch ──────────────────────────────────────────────────────────
printf '[' > "$TMPFILE"
FIRST=true

# One event per Zeek process
while IFS= read -r line; do
    [ -z "$line" ] && continue

    PID=$(echo "$line" | awk '{print $1}')
    RSS=$(echo "$line" | awk '{print $2}')
    VSZ=$(echo "$line" | awk '{print $3}')
    CPU=$(echo "$line" | awk '{print $4}')
    ARGS=$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":""); print ""}')

    # Determine role and interface from command-line arguments
    IFACE=""
    if echo "$ARGS" | grep -q ' -i '; then
        ROLE="worker"
        tmp="${ARGS##* -i }"
        IFACE="${tmp%% *}"
    elif echo "$ARGS" | grep -qi "proxy"; then
        ROLE="proxy"
    else
        ROLE="manager"
    fi

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        printf ',' >> "$TMPFILE"
    fi

    printf '{"_time":"%s","event_type":"system_metrics","metric_scope":"zeek_process","role":"%s","iface":"%s","pid":%s,"rss_kb":%s,"vsz_kb":%s,"cpu_pct":%s}' \
        "$TIMESTAMP" "$ROLE" "$IFACE" "$PID" "$RSS" "$VSZ" "$CPU" >> "$TMPFILE"

done < <(ps -eo pid,rss,vsz,%cpu,args 2>/dev/null \
    | grep '/usr/local/zeek/bin/[z]eek' || true)

# Box-level host event
if [ "$FIRST" = true ]; then
    FIRST=false
else
    printf ',' >> "$TMPFILE"
fi

printf '{"_time":"%s","event_type":"system_metrics","metric_scope":"host","mem_total_mb":%s,"mem_used_mb":%s,"mem_available_mb":%s,"swap_used_mb":%s,"load1":%s,"bspool_used_pct":%s,"zeek_worker_count":%s}' \
    "$TIMESTAMP" \
    "${MEM_TOTAL:-0}" "${MEM_USED:-0}" "${MEM_AVAILABLE:-0}" "${SWAP_USED:-0}" \
    "${LOAD1:-0}" "${BSPOOL_PCT:-0}" "${ZEEK_WORKER_COUNT:-0}" >> "$TMPFILE"

printf ']' >> "$TMPFILE"

# ── Ship to Axiom ─────────────────────────────────────────────────────────────
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.axiom.co/v1/datasets/${AXIOM_DATASET}/ingest" \
    -H "Authorization: Bearer ${AXIOM_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"$TMPFILE" \
    --compressed)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    ZEEK_PROC_COUNT=$(grep -c '"metric_scope":"zeek_process"' "$TMPFILE" || true)
    echo "[system-metrics] Exported ${ZEEK_PROC_COUNT} Zeek process(es) + 1 host event to ${AXIOM_DATASET} (workers=${ZEEK_WORKER_COUNT})"
else
    echo "[system-metrics] ERROR: HTTP ${HTTP_CODE}"
    echo "[system-metrics] Response: ${HTTP_BODY}"
fi

rm -f "$TMPFILE"
