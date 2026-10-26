#!/usr/bin/env bash
# Removes opsguard. Config, state and backups are kept unless --purge is given.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./uninstall.sh [--purge]" >&2
  exit 1
fi

for t in check security backup report; do
  systemctl disable --now "opsguard-$t.timer" 2>/dev/null || true
  rm -f "/etc/systemd/system/opsguard-$t.service" "/etc/systemd/system/opsguard-$t.timer"
done
systemctl daemon-reload
rm -rf /opt/opsguard /usr/local/bin/opsguard /etc/logrotate.d/opsguard

if [[ "${1:-}" == --purge ]]; then
  rm -rf /etc/opsguard /var/lib/opsguard /var/log/opsguard.log
  echo "opsguard removed, including config and state."
  echo "Backups in /var/backups/opsguard were NOT deleted; remove them yourself if you're sure."
else
  echo "opsguard removed. Kept /etc/opsguard, /var/lib/opsguard and /var/backups/opsguard."
fi
