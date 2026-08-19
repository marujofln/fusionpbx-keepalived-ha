#!/bin/bash
# Keepalived notify script for FreeSWITCH active/passive migration.
#
# keepalived invokes: ka-notify.sh <TYPE> <NAME> <STATE> <PRIORITY>
# TYPE  = GROUP|INSTANCE
# STATE = MASTER|BACKUP|FAULT|STOP|DELETED
#
# MASTER  -> start freeswitch, then sofia recover
# BACKUP/FAULT/STOP -> stop freeswitch on this node

set -u

readonly FS_CLI="${FS_CLI:-/usr/bin/fs_cli}"
readonly SYSTEMCTL="${SYSTEMCTL:-/bin/systemctl}"
readonly LOGGER_TAG="ka-notify"
readonly SERVICE_NAME="${FREESWITCH_SERVICE:-freeswitch}"
readonly DEBUG_LOG="${KA_DEBUG_LOG:-/tmp/ka-debug-3ea613.log}"
readonly GRACE_FILE="${KA_GRACE_FILE:-/tmp/ka-fs-grace-until}"
readonly STARTUP_GRACE_SEC="${KA_STARTUP_GRACE_SEC:-90}"

what="${1:-}"
id="${2:-}"
state="${3:-}"
prio="${4:-}"

log() {
  logger -t "${LOGGER_TAG}" -- "$*"
}

# #region agent log
debug_log() {
  local hyp="$1"
  local msg="$2"
  local data="$3"
  local ts
  ts=$(date +%s%3N 2>/dev/null || date +%s000)
  printf '{"sessionId":"3ea613","runId":"post-fix","hypothesisId":"%s","location":"ka-notify.sh","message":"%s","data":%s,"timestamp":%s,"host":"%s"}\n' \
    "${hyp}" "${msg}" "${data}" "${ts}" "$(hostname)" >>"${DEBUG_LOG}" 2>/dev/null || true
  chmod 666 "${DEBUG_LOG}" 2>/dev/null || true
}

vip_present() {
  ip -o addr show 2>/dev/null | grep -qE 'inet (192\.168\.32\.190|172\.25\.144\.50)/' && echo true || echo false
}
# #endregion

set_startup_grace() {
  local until_ts
  until_ts=$(($(date +%s) + STARTUP_GRACE_SEC))
  echo "${until_ts}" >"${GRACE_FILE}" 2>/dev/null || true
  chmod 666 "${GRACE_FILE}" 2>/dev/null || true
  log "Startup grace until epoch ${until_ts} (${STARTUP_GRACE_SEC}s)"
  # #region agent log
  debug_log "F" "grace_set" "{\"until\":${until_ts},\"graceSec\":${STARTUP_GRACE_SEC}}"
  # #endregion
}

clear_startup_grace() {
  rm -f "${GRACE_FILE}" 2>/dev/null || true
  # #region agent log
  debug_log "F" "grace_cleared" "{\"state\":\"${state}\"}"
  # #endregion
}

run_systemctl() {
  # Prefer direct systemctl when running as root; fall back to passwordless sudo.
  if [[ "$(id -u)" -eq 0 ]]; then
    "${SYSTEMCTL}" "$@"
    return $?
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -n "${SYSTEMCTL}" "$@"
    return $?
  fi
  return 1
}

log "what(${what}) id(${id}) state(${state}) prio(${prio})"
# #region agent log
debug_log "B" "notify_enter" "{\"what\":\"${what}\",\"id\":\"${id}\",\"state\":\"${state}\",\"prio\":\"${prio}\",\"holdsVip\":$(vip_present),\"fsBefore\":\"$(systemctl is-active freeswitch 2>/dev/null || echo unknown)\"}"
# #endregion

case "${state}" in
  MASTER)
    log "Instance went to MASTER: starting ${SERVICE_NAME} and issuing sofia recover"
    # Must set grace BEFORE start: track_script runs in parallel and fs_cli fails until FS is up.
    set_startup_grace
    if ! run_systemctl start "${SERVICE_NAME}"; then
      log "ERROR: failed to start ${SERVICE_NAME}"
      # #region agent log
      debug_log "B" "master_start_failed" "{\"state\":\"MASTER\",\"holdsVip\":$(vip_present)}"
      # #endregion
      exit 1
    fi

    # Brief wait for event_socket to come up before recover.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if "${FS_CLI}" -x "status" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    if "${FS_CLI}" -x "sofia recover" >/dev/null 2>&1; then
      log "sofia recover issued successfully"
    else
      log "WARNING: sofia recover failed or fs_cli not ready yet"
    fi
    # #region agent log
    debug_log "B" "master_done" "{\"state\":\"MASTER\",\"holdsVip\":$(vip_present),\"fsAfter\":\"$(systemctl is-active freeswitch 2>/dev/null || echo unknown)\"}"
    # #endregion
    ;;
  BACKUP|FAULT|STOP)
    clear_startup_grace
    log "Instance went to ${state}: stopping ${SERVICE_NAME}"
    if ! run_systemctl stop "${SERVICE_NAME}"; then
      log "ERROR: failed to stop ${SERVICE_NAME}"
      # #region agent log
      debug_log "C" "stop_failed" "{\"state\":\"${state}\",\"holdsVip\":$(vip_present)}"
      # #endregion
      exit 1
    fi
    # #region agent log
    debug_log "A" "demote_stop_done" "{\"state\":\"${state}\",\"holdsVip\":$(vip_present),\"fsAfter\":\"$(systemctl is-active freeswitch 2>/dev/null || echo unknown)\"}"
    # #endregion
    ;;
  *)
    log "Ignoring notify state=${state}"
    # #region agent log
    debug_log "E" "notify_ignored" "{\"state\":\"${state}\"}"
    # #endregion
    ;;
esac

exit 0
