#!/bin/bash
# =============================================================================
# Firewalla Gold SE — Log Shipping Persistence Script
#
# Install location: /home/pi/.firewalla/config/post_main.d/start_log_shipping.sh
#
# Firewalla runs all scripts in post_main.d/ after every boot and firmware
# update. This ensures the Fluent Bit container is always running.
# =============================================================================

set -euo pipefail

CONFIG_DIR="/home/pi/.firewalla/config"
ENV_FILE="${CONFIG_DIR}/log_shipping.env"
CONTAINER_NAME="fluent-bit-axiom"
IMAGE="fluent/fluent-bit:latest"

# --- Load environment variables ----------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
else
    echo "[log-shipping] WARNING: $ENV_FILE not found. Create it with:"
    echo "  AXIOM_DATASET=firewalla"
    echo "  AXIOM_API_TOKEN=xaat-your-token-here"
    exit 1
fi

# --- Validate required env vars ----------------------------------------------
if [ -z "${AXIOM_DATASET:-}" ] || [ -z "${AXIOM_API_TOKEN:-}" ]; then
    echo "[log-shipping] ERROR: AXIOM_DATASET and AXIOM_API_TOKEN must be set in $ENV_FILE"
    exit 1
fi

# Grafana Cloud Loki creds are optional — if unset, the direct Loki output just
# fails at runtime and retries (Axiom is unaffected). Warn so it isn't silent.
if [ -z "${GRAFANA_CLOUD_LOGS_HOST:-}" ] || [ -z "${GRAFANA_CLOUD_LOGS_USER:-}" ] || [ -z "${GRAFANA_CLOUD_LOGS_TOKEN:-}" ]; then
    echo "[log-shipping] WARNING: GRAFANA_CLOUD_LOGS_{HOST,USER,TOKEN} not all set — the direct Loki output will be inactive (Axiom unaffected)."
fi

# --- Wait for Docker ---------------------------------------------------------
echo "[log-shipping] Waiting for Docker daemon..."
for _i in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

if ! docker info >/dev/null 2>&1; then
    echo "[log-shipping] ERROR: Docker not available after 60 seconds."
    exit 1
fi

# --- Create data directory for position tracking -----------------------------
mkdir -p "${CONFIG_DIR}/fluent-bit-data"

# --- Wipe stale position tracking data ---------------------------------------
# Zeek logs live on a tmpfs that's recreated on every reboot. If Fluent Bit's
# position tracker (*.db files) references byte offsets in files that no longer
# exist, it silently reads nothing. This was the #1 cause of "data stopped
# flowing" in production — hit it 3 times before adding this fix.
echo "[log-shipping] Clearing stale position tracking data..."
rm -f "${CONFIG_DIR}/fluent-bit-data"/*.db
rm -f "${CONFIG_DIR}/fluent-bit-data"/*.offset

# --- Pull image if needed ----------------------------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[log-shipping] Pulling Fluent Bit image (first run)..."
    docker pull "$IMAGE"
fi

# --- Stop existing container -------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[log-shipping] Stopping existing ${CONTAINER_NAME} container..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# --- Start Fluent Bit --------------------------------------------------------
echo "[log-shipping] Starting Fluent Bit → Axiom pipeline..."
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart always \
    --network host \
    -e AXIOM_DATASET="${AXIOM_DATASET}" \
    -e AXIOM_API_TOKEN="${AXIOM_API_TOKEN}" \
    -e GRAFANA_CLOUD_LOGS_HOST="${GRAFANA_CLOUD_LOGS_HOST:-}" \
    -e GRAFANA_CLOUD_LOGS_USER="${GRAFANA_CLOUD_LOGS_USER:-}" \
    -e GRAFANA_CLOUD_LOGS_TOKEN="${GRAFANA_CLOUD_LOGS_TOKEN:-}" \
    -v "${CONFIG_DIR}/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro" \
    -v "${CONFIG_DIR}/parsers.conf:/fluent-bit/etc/parsers.conf:ro" \
    -v "${CONFIG_DIR}/fluent-bit-data:/fluent-bit/data" \
    -v "/bspool/manager:/logs/zeek:ro" \
    -v "/alog:/logs/alog:ro" \
    "$IMAGE"

echo "[log-shipping] Fluent Bit running. Dataset: ${AXIOM_DATASET}"
echo "[log-shipping] Check status: docker logs ${CONTAINER_NAME}"
