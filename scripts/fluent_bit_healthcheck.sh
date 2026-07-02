#!/bin/bash
# =============================================================================
# Fluent Bit Health Check
#
# Runs every 5 minutes via cron. Checks if Fluent Bit has successfully
# flushed data to Axiom recently. If it's only producing errors (or no
# output at all), restarts the container to clear wedged state.
#
# Catches all known failure modes:
#   - DNS resolution failures wedging the connection pool
#   - Axiom outage recovery (503s resolved but flushes stuck)
#   - Stale connections after network changes
#   - Container running but silently doing nothing
#
# Install location: /home/pi/.firewalla/config/fluent_bit_healthcheck.sh
# =============================================================================

set -euo pipefail

CONTAINER_NAME="fluent-bit-axiom"
LOGFILE="/home/pi/.firewalla/config/fluent-bit-healthcheck.log"
CHECK_WINDOW="5m"
ENV_FILE="/home/pi/.firewalla/config/log_shipping.env"
readonly LOG_MAX_BYTES=1048576

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [healthcheck] $1" >> "$LOGFILE"
}

rotate_log() {
    if [[ -f "$LOGFILE" ]]; then
        local size
        size=$(stat -c%s "$LOGFILE")
        if (( size >= LOG_MAX_BYTES )); then
            mv "$LOGFILE" "${LOGFILE}.1"
        fi
    fi
}

rotate_log

# ── Load environment variables ────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# ── Emit restart metric to Axiom (fire-and-forget) ────────────────────────────
emit_restart_metric() {
    local reason="$1"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [ -z "${AXIOM_API_TOKEN:-}" ] || [ -z "${AXIOM_DATASET:-}" ]; then
        return 0
    fi

    curl --silent --max-time 5 \
        -H "Authorization: Bearer ${AXIOM_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "[{\"_time\":\"${timestamp}\",\"event_type\":\"health_check_restart\",\"reason\":\"${reason}\"}]" \
        "https://api.axiom.co/v1/datasets/${AXIOM_DATASET}/ingest" \
        >/dev/null 2>&1 &
}

# --- Is the container even running? ------------------------------------------
if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    log "Container not running — starting via post_main.d script"
    emit_restart_metric "container_not_running"
    sudo /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh 2>&1 | tee -a "$LOGFILE" >/dev/null
    exit 0
fi

# --- Get recent logs ---------------------------------------------------------
RECENT_LOGS=$(sudo docker logs --since "$CHECK_WINDOW" "$CONTAINER_NAME" 2>&1)

# --- No output at all = suspicious -------------------------------------------
# Fluent Bit should produce SOMETHING every flush interval (10s).
# 5 minutes of silence means it's frozen or the container is wedged.
if [ -z "$RECENT_LOGS" ]; then
    log "WARNING: No output in last ${CHECK_WINDOW} — restarting"
    emit_restart_metric "no output in last ${CHECK_WINDOW}"
    sudo docker restart "$CONTAINER_NAME" >> "$LOGFILE" 2>&1
    log "Container restarted (reason: no output)"
    exit 0
fi

# --- Check for successful activity -------------------------------------------
# Fluent Bit doesn't log successful flushes at "warn" level, but it DOES
# stay quiet when things are working. Errors are loud. So the logic is:
#   - If we see errors AND nothing else → stuck
#   - If we see only the startup banner → just restarted, give it time
#   - If we see errors mixed with normal operation → recovering, leave it

ERROR_COUNT=$(echo "$RECENT_LOGS" | grep -c '\[error\]' 2>/dev/null || echo 0)
WARN_COUNT=$(echo "$RECENT_LOGS" | grep -c '\[ warn\]' 2>/dev/null || echo 0)
# shellcheck disable=SC2034  # tracked for future use
RETRY_COUNT=$(echo "$RECENT_LOGS" | grep -c 'retry in' 2>/dev/null || echo 0)

# If there are retries happening, Fluent Bit is actively trying but failing
# Check if ALL recent lines are errors/warnings (no successful flushes)
TOTAL_LINES=$(echo "$RECENT_LOGS" | grep -v '^\s*$' | wc -l)
ERROR_LINES=$((ERROR_COUNT + WARN_COUNT))

# --- Decision logic ----------------------------------------------------------

# If the only output is the startup banner, it just restarted — skip
if echo "$RECENT_LOGS" | grep -q "Fluent Bit v" && [ "$ERROR_COUNT" -eq 0 ]; then
    # Healthy or just started — no action needed
    exit 0
fi

# If there are zero errors, everything is fine
if [ "$ERROR_COUNT" -eq 0 ]; then
    exit 0
fi

# If errors make up more than 80% of all output lines, it's stuck
if [ "$TOTAL_LINES" -gt 0 ]; then
    ERROR_RATIO=$((ERROR_LINES * 100 / TOTAL_LINES))
    if [ "$ERROR_RATIO" -gt 80 ]; then
        log "WARNING: ${ERROR_RATIO}% error rate (${ERROR_LINES}/${TOTAL_LINES} lines) — restarting"
        log "Last errors: $(echo "$RECENT_LOGS" | grep '\[error\]' | tail -3)"
        emit_restart_metric "high error rate: ${ERROR_RATIO}% (${ERROR_LINES}/${TOTAL_LINES} lines)"
        sudo docker restart "$CONTAINER_NAME" >> "$LOGFILE" 2>&1
        log "Container restarted (reason: high error rate)"
        exit 0
    fi
fi

# Errors present but not dominant — Fluent Bit is probably recovering on its own
log "INFO: ${ERROR_COUNT} errors in last ${CHECK_WINDOW} but container appears to be recovering"
