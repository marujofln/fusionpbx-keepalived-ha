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

what="${1:-}"
id="${2:-}"
state="${3:-}"
prio="${4:-}"

log() {
  logger -t "${LOGGER_TAG}" -- "$*"
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

case "${state}" in
  MASTER)
    log "Instance went to MASTER: starting ${SERVICE_NAME} and issuing sofia recover"
    if ! run_systemctl start "${SERVICE_NAME}"; then
      log "ERROR: failed to start ${SERVICE_NAME}"
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
    ;;
  BACKUP|FAULT|STOP)
    log "Instance went to ${state}: stopping ${SERVICE_NAME}"
    if ! run_systemctl stop "${SERVICE_NAME}"; then
      log "ERROR: failed to stop ${SERVICE_NAME}"
      exit 1
    fi
    ;;
  *)
    log "Ignoring notify state=${state}"
    ;;
esac

exit 0
