#!/bin/bash
# Run as root on each node (pri and sec).
# Backs up all keepalived config and runtime state before applying changes.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

for f in /tmp/ka-status.sh /tmp/ka-notify.sh /tmp/sudoers.keepalived-freeswitch; do
  if [[ ! -f "${f}" ]]; then
    echo "ERROR: missing ${f}" >&2
    exit 1
  fi
done

BACKUP_DIR="/root/keepalived-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}/keepalived"

echo "=== Backing up current configuration to ${BACKUP_DIR} ==="

# Full snapshot of keepalived directory
cp -a /etc/keepalived/. "${BACKUP_DIR}/keepalived/"

# Sudoers fragment if present
if [[ -e /etc/sudoers.d/keepalived-freeswitch ]]; then
  cp -a /etc/sudoers.d/keepalived-freeswitch "${BACKUP_DIR}/"
fi

# Runtime metadata for rollback context
systemctl status keepalived --no-pager -l >"${BACKUP_DIR}/keepalived-status.txt" 2>&1 || true
systemctl status freeswitch --no-pager -l >"${BACKUP_DIR}/freeswitch-status.txt" 2>&1 || true
ip addr >"${BACKUP_DIR}/ip-addr.txt" 2>&1 || true
if [[ -x /usr/bin/fs_cli ]]; then
  /usr/bin/fs_cli -x "sofia xmlstatus" >"${BACKUP_DIR}/sofia-xmlstatus.xml" 2>&1 || true
fi

# Manifest of what was backed up
{
  echo "hostname: $(hostname)"
  echo "date: $(date -Is)"
  echo "backup_dir: ${BACKUP_DIR}"
  echo
  echo "=== keepalived dir listing ==="
  ls -la "${BACKUP_DIR}/keepalived/"
} >"${BACKUP_DIR}/MANIFEST.txt"

echo "Backup complete. Contents:"
ls -la "${BACKUP_DIR}/"
ls -la "${BACKUP_DIR}/keepalived/"

echo
echo "=== Installing new scripts and sudoers ==="

install -o root -g www-data -m 750 /tmp/ka-status.sh /etc/keepalived/ka-status.sh
install -o root -g www-data -m 750 /tmp/ka-notify.sh /etc/keepalived/ka-notify.sh
install -o root -g root -m 440 /tmp/sudoers.keepalived-freeswitch /etc/sudoers.d/keepalived-freeswitch

visudo -cf /etc/sudoers.d/keepalived-freeswitch

# Point keepalived at the bash scripts (keep existing .pl in place; conf .bak from sed)
sed -i.bak \
  -e 's|/etc/keepalived/ka-status\.pl|/etc/keepalived/ka-status.sh|g' \
  -e 's|/etc/keepalived/ka-notify\.pl|/etc/keepalived/ka-notify.sh|g' \
  /etc/keepalived/keepalived.conf

# Also archive the sed .bak into the backup dir if created after our snapshot
if [[ -f /etc/keepalived/keepalived.conf.bak ]]; then
  cp -a /etc/keepalived/keepalived.conf.bak "${BACKUP_DIR}/keepalived/"
fi

echo "Updated /etc/keepalived/keepalived.conf:"
grep -E 'ka-(status|notify)' /etc/keepalived/keepalived.conf

# Validate config when the binary is available
if command -v keepalived >/dev/null 2>&1; then
  keepalived -t -f /etc/keepalived/keepalived.conf && echo "keepalived config OK"
elif [[ -x /usr/sbin/keepalived ]]; then
  /usr/sbin/keepalived -t -f /etc/keepalived/keepalived.conf && echo "keepalived config OK"
fi

echo
echo "Dry-run status as www-data:"
sudo -u www-data /etc/keepalived/ka-status.sh
echo "ka-status exit: $?"

echo
echo "Install done."
echo "BACKUP_DIR=${BACKUP_DIR}"
echo "Rollback:"
echo "  cp -a ${BACKUP_DIR}/keepalived/* /etc/keepalived/"
echo "  # restore or remove /etc/sudoers.d/keepalived-freeswitch as needed"
echo "  systemctl reload keepalived"
echo
echo "When ready to activate:"
echo "  systemctl reload keepalived"
echo "On BACKUP, reload will STOP freeswitch (active/passive)."
