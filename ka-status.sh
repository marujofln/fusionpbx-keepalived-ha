#!/bin/bash
# Keepalived VRRP health check for FreeSWITCH Sofia profiles.
# Exit 0 = healthy, exit 1 = failure (triggers failover when fall count is reached).
#
# On MASTER (node holds a VIP): requires fs_cli success and all required profiles RUNNING.
# On BACKUP (no VIP): always healthy so a stopped FreeSWITCH standby can still take over.

set -u

readonly FS_CLI="${FS_CLI:-/usr/bin/fs_cli}"
readonly LOGGER_TAG="ka-status"
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

holds_vip() {
  local vip
  for vip in "${VIP_MARKERS[@]}"; do
    if ip -o addr show 2>/dev/null | grep -q "inet ${vip}/"; then
      return 0
    fi
  done
  return 1
}

# Standby without VIP must not fail the track_script, otherwise it cannot become MASTER.
if ! holds_vip; then
  exit 0
fi

if [[ ! -x "${FS_CLI}" ]]; then
  log "KA STATUS ERROR: ${FS_CLI} not found or not executable"
  exit 1
fi

xmlstatus="$(${FS_CLI} -x "sofia xmlstatus" 2>/dev/null)"
rc=$?

if [[ ${rc} -ne 0 ]]; then
  log "KA STATUS ERROR: fs_cli sofia xmlstatus failed (rc=${rc})"
  exit 1
fi

if [[ -z "${xmlstatus}" ]]; then
  log "KA STATUS ERROR: fs_cli returned empty sofia xmlstatus"
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
    log "KA STATUS ERROR: sip profile ${profile} not RUNNING (or missing), marking failure"
    exit 1
  fi
done

exit 0
