#!/bin/bash
# Keepalived VRRP health check for FreeSWITCH Sofia profiles.
# Exit 0 = healthy, exit 1 = failure (triggers failover when fall count is reached).
#
# On MASTER (node holds a VIP): requires fs_cli success and all required profiles RUNNING.
# On BACKUP (no VIP): always healthy so a stopped FreeSWITCH standby can still take over.
# During MASTER notify startup grace: fs_cli/profile failures are ignored so fall does not
# kill the new master while FreeSWITCH is still coming up.

set -u

readonly FS_CLI="${FS_CLI:-/usr/bin/fs_cli}"
readonly LOGGER_TAG="ka-status"
readonly DEBUG_LOG="${KA_DEBUG_LOG:-/tmp/ka-debug-3ea613.log}"
readonly GRACE_FILE="${KA_GRACE_FILE:-/tmp/ka-fs-grace-until}"
readonly REQUIRED_PROFILES=(
  fs_profile_internal
  fs_profile_external
)
# Any of these addresses indicate this node currently owns the cluster VIP(s).
readonly VIP_MARKERS=(
  192.168.32.190
  172.25.144.50
)

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
  printf '{"sessionId":"3ea613","runId":"post-fix","hypothesisId":"%s","location":"ka-status.sh","message":"%s","data":%s,"timestamp":%s,"host":"%s"}\n' \
    "${hyp}" "${msg}" "${data}" "${ts}" "$(hostname)" >>"${DEBUG_LOG}" 2>/dev/null || true
  chmod 666 "${DEBUG_LOG}" 2>/dev/null || true
}
# #endregion

holds_vip() {
  local vip
  for vip in "${VIP_MARKERS[@]}"; do
    if ip -o addr show 2>/dev/null | grep -q "inet ${vip}/"; then
      return 0
    fi
  done
  return 1
}

in_startup_grace() {
  local until_ts now fs_state
  now=$(date +%s)
  if [[ -f "${GRACE_FILE}" ]]; then
    until_ts=$(cat "${GRACE_FILE}" 2>/dev/null || echo 0)
    if [[ "${until_ts}" =~ ^[0-9]+$ ]] && [[ "${now}" -lt "${until_ts}" ]]; then
      return 0
    fi
  fi
  # FreeSWITCH still starting (systemd); treat as grace even without stamp.
  fs_state=$(systemctl is-active freeswitch 2>/dev/null || echo unknown)
  if [[ "${fs_state}" == "activating" ]]; then
    return 0
  fi
  return 1
}

grace_exit_ok() {
  local reason="$1"
  local fs_state
  fs_state=$(systemctl is-active freeswitch 2>/dev/null || echo unknown)
  log "KA STATUS GRACE: ${reason} (fs=${fs_state}), not failing track_script"
  # #region agent log
  debug_log "F" "exit0_startup_grace" "{\"holdsVip\":true,\"exit\":0,\"reason\":\"${reason}\",\"fsState\":\"${fs_state}\"}"
  # #endregion
  exit 0
}

# Standby without VIP must not fail the track_script, otherwise it cannot become MASTER.
if ! holds_vip; then
  # #region agent log
  debug_log "A" "exit0_no_vip" "{\"holdsVip\":false,\"exit\":0,\"fsActive\":\"$(systemctl is-active freeswitch 2>/dev/null || echo unknown)\"}"
  # #endregion
  exit 0
fi

if [[ ! -x "${FS_CLI}" ]]; then
  if in_startup_grace; then
    grace_exit_ok "fs_cli_missing_during_grace"
  fi
  log "KA STATUS ERROR: ${FS_CLI} not found or not executable"
  # #region agent log
  debug_log "A" "exit1_no_fs_cli" "{\"holdsVip\":true,\"exit\":1}"
  # #endregion
  exit 1
fi

xmlstatus="$(${FS_CLI} -x "sofia xmlstatus" 2>/dev/null)"
rc=$?

if [[ ${rc} -ne 0 ]]; then
  if in_startup_grace; then
    grace_exit_ok "fs_cli_rc_${rc}"
  fi
  log "KA STATUS ERROR: fs_cli sofia xmlstatus failed (rc=${rc})"
  # #region agent log
  debug_log "F" "exit1_fs_cli_rc" "{\"holdsVip\":true,\"exit\":1,\"fsCliRc\":${rc}}"
  # #endregion
  exit 1
fi

if [[ -z "${xmlstatus}" ]]; then
  if in_startup_grace; then
    grace_exit_ok "empty_xmlstatus"
  fi
  log "KA STATUS ERROR: fs_cli returned empty sofia xmlstatus"
  # #region agent log
  debug_log "A" "exit1_empty_xml" "{\"holdsVip\":true,\"exit\":1}"
  # #endregion
  exit 1
fi

# Parse <name>/<state> pairs from sofia xmlstatus profiles (ignore gateways).
declare -A profile_running=()
current_name=""
in_profile=0

while IFS= read -r line; do
  if [[ "${line}" =~ \<profile\> ]]; then
    in_profile=1
    current_name=""
    continue
  fi
  if [[ "${line}" =~ \</profile\> ]]; then
    in_profile=0
    current_name=""
    continue
  fi
  if [[ ${in_profile} -eq 0 ]]; then
    continue
  fi
  if [[ "${line}" =~ \<name\>(.*)\</name\> ]]; then
    current_name="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ -n "${current_name}" && "${line}" =~ \<state\>(.*)\</state\> ]]; then
    state="${BASH_REMATCH[1]}"
    if [[ "${state}" == RUNNING* ]]; then
      profile_running["${current_name}"]=1
    fi
  fi
done <<< "${xmlstatus}"

for profile in "${REQUIRED_PROFILES[@]}"; do
  if [[ -z "${profile_running[${profile}]+x}" ]]; then
    if in_startup_grace; then
      grace_exit_ok "profile_${profile}_not_ready"
    fi
    log "KA STATUS ERROR: sip profile ${profile} not RUNNING (or missing), marking failure"
    # #region agent log
    debug_log "A" "exit1_profile_down" "{\"holdsVip\":true,\"exit\":1,\"missingProfile\":\"${profile}\"}"
    # #endregion
    exit 1
  fi
done

# #region agent log
debug_log "A" "exit0_profiles_ok" "{\"holdsVip\":true,\"exit\":0}"
# #endregion
exit 0
