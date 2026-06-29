#!/usr/bin/env bash
# =============================================================================
# GitOps poller for firewalla-axiom-pipeline.
#
# Runs every 5 min from user_crontab. Fetches origin/main, compares to HEAD,
# and on divergence: validates the new fluent-bit config via `docker run
# --dry-run`, swaps live files in /home/pi/.firewalla/config/, restarts the
# container (only if its inputs changed), and reinstalls crontab (only if
# cron/user_crontab changed). Rolls back to the pre-sync SHA on validation
# failure — the live container keeps running on the last-known-good config.
#
# Modeled on lentago/homeassistant-config scripts/gitops-sync.sh. See issue
# #45 for the design rationale.
# =============================================================================
set -euo pipefail

readonly CLONE_PATH="/home/pi/.firewalla/firewalla-axiom-pipeline"
readonly LIVE_DIR="/home/pi/.firewalla/config"
readonly LOCK_FILE="${LIVE_DIR}/.gitops-sync.lock"
readonly LOG_FILE="${LIVE_DIR}/gitops-sync.log"
readonly LOG_MAX_BYTES=1048576
readonly CONTAINER_NAME="fluent-bit-axiom"
readonly IMAGE="fluent/fluent-bit:latest"

log() {
  local level="$1"; shift
  local ts line
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  line="[$ts] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE"
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE")
    if (( size >= LOG_MAX_BYTES )); then
      mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
}

# Validate a candidate fluent-bit config tree by running fluent-bit --dry-run
# against it in a throwaway container. Returns 0 on success, non-zero with
# stderr captured to $2 on failure.
dryrun_fluent_bit() {
  local src_dir="$1" err_out="$2"
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now so the trap sees the right path
  trap "rm -rf '$tmp'" RETURN
  cp "$src_dir/fluent-bit.conf" "$tmp/fluent-bit.conf"
  cp "$src_dir/parsers.conf"    "$tmp/parsers.conf"
  # Env vars in the config (${AXIOM_DATASET}, ${AXIOM_API_TOKEN}) must be set
  # for the dry-run to parse — values don't matter, no network is touched.
  # sudo: cron's pi user lacks docker-socket access without it. The redirect
  # writes to a pi-owned tmp file so it doesn't need sudo (SC2024 false positive).
  # shellcheck disable=SC2024
  sudo docker run --rm \
    -v "$tmp:/fluent-bit/etc:ro" \
    -e AXIOM_DATASET=dryrun \
    -e AXIOM_API_TOKEN=dryrun \
    "$IMAGE" \
    /fluent-bit/bin/fluent-bit -c /fluent-bit/etc/fluent-bit.conf --dry-run \
    > "$err_out" 2>&1
}

main() {
  rotate_log

  cd "$CLONE_PATH"

  local current_branch
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "$current_branch" != "main" ]]; then
    log ERROR "Expected branch 'main', got '${current_branch}'. Aborting to avoid deploying wrong branch."
    exit 1
  fi

  local rollback_sha
  rollback_sha=$(git rev-parse HEAD)

  if ! git fetch --quiet origin; then
    log ERROR "git fetch failed — check network or SSH access"
    exit 1
  fi

  if ! git rev-parse --verify "origin/main" > /dev/null 2>&1; then
    log ERROR "origin/main not found after fetch."
    exit 1
  fi

  local remote_sha
  remote_sha=$(git rev-parse origin/main)

  if [[ "$rollback_sha" == "$remote_sha" ]]; then
    # no-op; suppress to keep the log focused on actual deploys
    exit 0
  fi

  local commit_count delta
  commit_count=$(git rev-list --count HEAD..origin/main)
  delta=$(git log --oneline HEAD..origin/main)
  log INFO "Applying ${commit_count} commit(s) ${rollback_sha:0:7}..${remote_sha:0:7}:"
  while IFS= read -r line; do
    log INFO "  ${line}"
  done <<< "$delta"

  local changed_files
  changed_files=$(git diff --name-only "${rollback_sha}..${remote_sha}")

  git reset --hard "$remote_sha"

  # --- Classify the diff -----------------------------------------------------
  local touched_fluent_bit=false
  local touched_crontab=false
  local touched_scripts=false
  local relevant_changes=false

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      fluent-bit/*.conf)
        touched_fluent_bit=true
        relevant_changes=true
        ;;
      cron/user_crontab)
        touched_crontab=true
        relevant_changes=true
        ;;
      scripts/gitops-sync.sh|scripts/bootstrap.sh)
        # The poller and bootstrap scripts run from the clone, not the live
        # dir, so a `git reset --hard` already installed the new version.
        ;;
      scripts/*.sh)
        touched_scripts=true
        relevant_changes=true
        ;;
      docs/*|*.md|LICENSE|.github/*|.gitignore|env.example)
        # No-op: not deployed to the live config dir.
        ;;
      *)
        log WARN "Routing: ${f} not in any known deploy target — skipping"
        ;;
    esac
  done <<< "$changed_files"

  if [[ "$relevant_changes" == false ]]; then
    log INFO "No file in this delta is deployed to live — nothing to apply."
    exit 0
  fi

  # --- Validate fluent-bit config BEFORE touching live files -----------------
  if [[ "$touched_fluent_bit" == true ]]; then
    local dryrun_log
    dryrun_log=$(mktemp)
    log INFO "Validating new fluent-bit config via dry-run"
    if ! dryrun_fluent_bit "${CLONE_PATH}/fluent-bit" "$dryrun_log"; then
      log ERROR "Dry-run FAILED — rolling back. Output:"
      while IFS= read -r line; do
        log ERROR "  ${line}"
      done < "$dryrun_log"
      rm -f "$dryrun_log"
      git reset --hard "$rollback_sha"
      log INFO "Rolled back to ${rollback_sha:0:7}. Live container untouched."
      exit 1
    fi
    rm -f "$dryrun_log"
    log INFO "Dry-run OK"
  fi

  # --- Apply ----------------------------------------------------------------
  if [[ "$touched_fluent_bit" == true ]]; then
    cp "${CLONE_PATH}/fluent-bit/fluent-bit.conf" "${LIVE_DIR}/fluent-bit.conf"
    cp "${CLONE_PATH}/fluent-bit/parsers.conf"    "${LIVE_DIR}/parsers.conf"
    log INFO "Restarting ${CONTAINER_NAME}"
    if ! sudo docker restart "$CONTAINER_NAME" > /dev/null; then
      log ERROR "docker restart ${CONTAINER_NAME} failed — manual intervention needed"
      exit 1
    fi
  fi

  if [[ "$touched_scripts" == true ]]; then
    # device_lookup_export.sh and fluent_bit_healthcheck.sh live directly in
    # config/. start_log_shipping.sh lives in config/post_main.d/.
    mkdir -p "${LIVE_DIR}/post_main.d"
    [[ -f "${CLONE_PATH}/scripts/device_lookup_export.sh" ]]    && cp "${CLONE_PATH}/scripts/device_lookup_export.sh"    "${LIVE_DIR}/device_lookup_export.sh"
    [[ -f "${CLONE_PATH}/scripts/device_group_upload.sh"   ]]   && cp "${CLONE_PATH}/scripts/device_group_upload.sh"     "${LIVE_DIR}/device_group_upload.sh"
    [[ -f "${CLONE_PATH}/scripts/fluent_bit_healthcheck.sh" ]]  && cp "${CLONE_PATH}/scripts/fluent_bit_healthcheck.sh"  "${LIVE_DIR}/fluent_bit_healthcheck.sh"
    [[ -f "${CLONE_PATH}/scripts/start_log_shipping.sh"     ]]  && cp "${CLONE_PATH}/scripts/start_log_shipping.sh"      "${LIVE_DIR}/post_main.d/start_log_shipping.sh"
    chmod +x "${LIVE_DIR}"/*.sh "${LIVE_DIR}/post_main.d/"*.sh 2>/dev/null || true
    log INFO "Synced scripts to ${LIVE_DIR}"
  fi

  if [[ "$touched_crontab" == true ]]; then
    cp "${CLONE_PATH}/cron/user_crontab" "${LIVE_DIR}/user_crontab"
    crontab "${LIVE_DIR}/user_crontab"
    log INFO "Reinstalled crontab"
  fi

  log INFO "Deploy complete at ${remote_sha:0:7}"
}

# Acquire exclusive lock — silent exit if a prior run is still going
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

main
