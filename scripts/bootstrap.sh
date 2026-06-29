#!/usr/bin/env bash
# =============================================================================
# One-time bootstrap of firewalla-axiom-pipeline on a fresh Firewalla.
#
# Run ON the Firewalla as user `pi`. Prereqs:
#   - /home/pi/.firewalla/config/log_shipping.env already exists with the
#     Axiom dataset/token (manually scp'd from a workstation — this script
#     never touches secrets).
#   - Network access to GitHub.
#
# After bootstrap, scripts/gitops-sync.sh runs every 5 min from cron and
# keeps the on-device config in sync with origin/main. See README §GitOps
# auto-deploy.
# =============================================================================
set -euo pipefail

readonly REPO_URL="https://github.com/lentago/firewalla-axiom-pipeline.git"
readonly CLONE_PATH="/home/pi/.firewalla/firewalla-axiom-pipeline"
readonly LIVE_DIR="/home/pi/.firewalla/config"
readonly ENV_FILE="${LIVE_DIR}/log_shipping.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy your env.example → log_shipping.env"
  echo "       and fill in AXIOM_DATASET / AXIOM_API_TOKEN before bootstrapping."
  exit 1
fi

if [[ -d "$CLONE_PATH/.git" ]]; then
  echo "[bootstrap] Repo already cloned at ${CLONE_PATH}, fetching latest..."
  git -C "$CLONE_PATH" fetch --quiet origin
  git -C "$CLONE_PATH" reset --hard origin/main
else
  echo "[bootstrap] Cloning ${REPO_URL} → ${CLONE_PATH}"
  git clone --quiet "$REPO_URL" "$CLONE_PATH"
fi

mkdir -p "${LIVE_DIR}/post_main.d"

echo "[bootstrap] Installing config files into ${LIVE_DIR}"
cp "${CLONE_PATH}/fluent-bit/fluent-bit.conf"          "${LIVE_DIR}/fluent-bit.conf"
cp "${CLONE_PATH}/fluent-bit/parsers.conf"             "${LIVE_DIR}/parsers.conf"
cp "${CLONE_PATH}/scripts/device_lookup_export.sh"     "${LIVE_DIR}/device_lookup_export.sh"
cp "${CLONE_PATH}/scripts/device_group_upload.sh"      "${LIVE_DIR}/device_group_upload.sh"
cp "${CLONE_PATH}/scripts/fluent_bit_healthcheck.sh"   "${LIVE_DIR}/fluent_bit_healthcheck.sh"
cp "${CLONE_PATH}/scripts/start_log_shipping.sh"       "${LIVE_DIR}/post_main.d/start_log_shipping.sh"
cp "${CLONE_PATH}/cron/user_crontab"                   "${LIVE_DIR}/user_crontab"
chmod +x "${LIVE_DIR}"/*.sh "${LIVE_DIR}/post_main.d/"*.sh "${CLONE_PATH}/scripts/"*.sh

echo "[bootstrap] Installing crontab (includes GitOps poller)"
crontab "${LIVE_DIR}/user_crontab"

echo "[bootstrap] Starting fluent-bit container"
sudo "${LIVE_DIR}/post_main.d/start_log_shipping.sh"

echo
echo "[bootstrap] Done. GitOps poll runs every 5 min."
echo "[bootstrap] Tail the log with: tail -f ${LIVE_DIR}/gitops-sync.log"
