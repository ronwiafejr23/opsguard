#!/usr/bin/env bash
# Installs opsguard to /opt/opsguard and enables its systemd timers.
set -euo pipefail

PREFIX=/opt/opsguard
CONF_DIR=/etc/opsguard
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMERS="check security backup report"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo ./install.sh" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
  echo "systemd is required (on WSL, enable it in /etc/wsl.conf - see README)" >&2
  exit 1
fi

missing=()
for cmd in curl tar gzip sha256sum flock df ps awk rsync; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
  echo "Missing tools: ${missing[*]}"
  echo "Install them first, e.g.: sudo apt install curl rsync procps util-linux"
  exit 1
fi

echo "==> Installing program to $PREFIX"
install -d -m 755 "$PREFIX/bin" "$PREFIX/lib"
install -m 755 "$SRC/bin/opsguard" "$PREFIX/bin/opsguard"
install -m 644 "$SRC"/lib/*.sh "$PREFIX/lib/"
ln -sf "$PREFIX/bin/opsguard" /usr/local/bin/opsguard

echo "==> Installing config to $CONF_DIR"
install -d -m 700 "$CONF_DIR"
if [[ -f "$CONF_DIR/opsguard.conf" ]]; then
  install -m 600 "$SRC/opsguard.conf" "$CONF_DIR/opsguard.conf.new"
  echo "    Kept your existing opsguard.conf; the new template is opsguard.conf.new"
else
  install -m 600 "$SRC/opsguard.conf" "$CONF_DIR/opsguard.conf"
fi

# Strip Windows line endings in case the files were edited on Windows.
sed -i 's/\r$//' "$PREFIX/bin/opsguard" "$PREFIX"/lib/*.sh "$CONF_DIR"/opsguard.conf*

echo "==> Creating state, backup and log locations"
install -d -m 700 /var/lib/opsguard /var/backups/opsguard
touch /var/log/opsguard.log
chmod 640 /var/log/opsguard.log
cat > /etc/logrotate.d/opsguard <<'EOF'
/var/log/opsguard.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

echo "==> Installing systemd timers"
for t in $TIMERS; do
  install -m 644 "$SRC/systemd/opsguard-$t.service" "$SRC/systemd/opsguard-$t.timer" /etc/systemd/system/
  sed -i 's/\r$//' "/etc/systemd/system/opsguard-$t.service" "/etc/systemd/system/opsguard-$t.timer"
done
systemctl daemon-reload
for t in $TIMERS; do
  systemctl enable --now "opsguard-$t.timer" >/dev/null
done

echo
echo "opsguard installed."
echo "  1. Edit the config:      sudo nano $CONF_DIR/opsguard.conf"
echo "  2. Test alerts:          sudo opsguard test-alert"
echo "  3. Run a check:          sudo opsguard check"
echo "  4. Run a backup:         sudo opsguard backup"
echo "  5. See the schedule:     systemctl list-timers 'opsguard*'"
