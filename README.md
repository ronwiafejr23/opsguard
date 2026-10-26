# opsguard

Server monitoring, backups and security alerts for Linux, written in Bash, with no agents or databases to run.

opsguard is for small teams running 1–20 Linux servers who need to know **before** a disk fills up, a service dies, a backup silently stops, or someone starts brute-forcing SSH.

| Feature | Schedule | What it does |
|---|---|---|
| `opsguard check` | every 5 min | CPU, memory, disk, systemd services, backup age; alerts once, then sends a "back to normal" message |
| `opsguard backup` | nightly 02:00 | tar of chosen folders, PostgreSQL/MySQL dumps, SHA-256 checksums, 7 daily + 4 weekly retention, optional off-site rsync |
| `opsguard security` | hourly | failed SSH logins per IP, brute-force detection, direct root logins |
| `opsguard report` | daily 07:00 | HTML report (health, 24h trends, services, backups, security) by email + Slack summary |

Alerts go to **Slack** (incoming webhook) and/or **email**. Repeated alerts are suppressed for `ALERT_COOLDOWN` seconds.

## Project layout

```
opsguard/
├── bin/opsguard          # CLI entry point
├── lib/
│   ├── common.sh         # defaults, logging, locking, alert de-duplication
│   ├── notify.sh         # Slack webhook + email
│   ├── health.sh         # CPU/mem/disk/services/backup-age checks
│   ├── backup.sh         # backups, retention, verify, off-site copy
│   ├── security.sh       # SSH log analysis
│   └── report.sh         # daily HTML report
├── systemd/              # 4 services + 4 timers
├── opsguard.conf         # config template
├── install.sh / uninstall.sh
```

---

## Step-by-step: build and run it

### Step 1: Get a Linux machine

Pick one:

- **WSL on Windows (free, good for development):** in PowerShell as admin, run `wsl --install -d Ubuntu`, reboot, and open "Ubuntu". opsguard needs systemd. Check it with `ps -p 1 -o comm=`, which should print `systemd`. If it doesn't, add this to `/etc/wsl.conf`:
  ```
  [boot]
  systemd=true
  ```
  Then run `wsl --shutdown` from PowerShell and reopen Ubuntu.
- **A cloud VPS (closest to a real company server):** a $4–6/month Ubuntu 24.04 server from DigitalOcean, Hetzner, Linode or AWS Lightsail. Connect with `ssh root@<ip>`.

### Step 2: Install the tools it uses

```bash
sudo apt update
sudo apt install -y curl rsync tar gzip procps util-linux git shellcheck
```

(RHEL/Fedora: `sudo dnf install -y curl rsync tar gzip procps-ng util-linux git ShellCheck`.)

### Step 3: Put the code on the machine

Either clone it from your Git repo:

```bash
git clone https://github.com/<you>/opsguard.git
cd opsguard
```

or copy the folder from Windows into WSL. Windows drives are under `/mnt/c`:

```bash
cp -r /mnt/c/Users/<you>/path/to/opsguard ~/opsguard
cd ~/opsguard
sed -i 's/\r$//' bin/opsguard lib/*.sh *.sh opsguard.conf   # fix Windows line endings
chmod +x bin/opsguard install.sh uninstall.sh
```

### Step 4: Try it without installing

As a normal user, opsguard keeps its state in `~/.local/state/opsguard`, so you can try it safely:

```bash
bin/opsguard status          # health table, no alerts sent
bin/opsguard security        # SSH scan (use sudo to see all log entries)
shellcheck bin/opsguard lib/*.sh install.sh   # lint, optional
```

### Step 5: Install it as a system service

```bash
sudo ./install.sh
```

This:
- copies the code to `/opt/opsguard` and links `/usr/local/bin/opsguard`
- puts the config in `/etc/opsguard/opsguard.conf` (mode 600, because it holds your webhook URL)
- creates `/var/lib/opsguard`, `/var/backups/opsguard` and `/var/log/opsguard.log`, with log rotation
- enables 4 systemd timers

Check the schedule:

```bash
systemctl list-timers 'opsguard*'
```

### Step 6: Configure it

```bash
sudo nano /etc/opsguard/opsguard.conf
```

The settings most people change:

```bash
DISK_MOUNTS="/ /var"
SERVICES="ssh cron nginx postgresql"   # use "sshd" on RHEL/Fedora
BACKUP_PATHS="/etc /home /var/www"
POSTGRES_DBS="app_production"
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
ALERT_EMAIL="ops@yourcompany.com"
```

There's nothing to restart. Each timer run reads the config fresh.

### Step 7: Set up Slack alerts

1. Go to https://api.slack.com/apps, then **Create New App**, then **From scratch**.
2. Open **Incoming Webhooks**, turn it **On**, then click **Add New Webhook to Workspace** and pick a channel such as `#alerts`.
3. Copy the URL into `SLACK_WEBHOOK_URL`.
4. Run `sudo opsguard test-alert`. A message should appear in the channel.

Discord works too: use a Discord webhook URL with `/slack` added to the end.

### Step 8 (optional): Set up email

opsguard sends mail through `sendmail`. The easiest way to provide that is `msmtp` with an SMTP account (Gmail app password, Microsoft 365, SendGrid, Mailgun):

```bash
sudo apt install -y msmtp msmtp-mta
sudo nano /etc/msmtprc
```

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.gmail.com
port           587
from           you@gmail.com
user           you@gmail.com
password       your-16-char-app-password
```

```bash
sudo chmod 600 /etc/msmtprc
sudo opsguard test-alert
```

### Step 9: Test everything by hand

```bash
sudo opsguard check            # health table; alerts go out for any problems
sudo opsguard backup           # make a backup now
sudo opsguard backups          # list backups
sudo opsguard verify           # check the newest backup's checksums
sudo opsguard security
sudo opsguard report           # HTML report in /var/lib/opsguard/report-<date>.html
tail -f /var/log/opsguard.log
```

**Trigger a real alert:** set `DISK_THRESHOLD=1` in the config and run `sudo opsguard check`. You'll get a "Disk / is at …" alert. Set it back, run the check again, and you'll get a "back to normal" message.

**Trigger a service alert:** add a service you can stop, for example `SERVICES="ssh cron"`, then run `sudo systemctl stop cron && sudo opsguard check`, then `sudo systemctl start cron`.

### Step 10: Restore from a backup

```bash
ls /var/backups/opsguard/daily/
B=/var/backups/opsguard/daily/2026-10-26_020312

sudo opsguard verify 2026-10-26_020312               # check it first

# Files: extract to a scratch folder, then copy back what you need
mkdir -p /tmp/restore && sudo tar -xzf $B/files.tar.gz -C /tmp/restore
sudo cp -a /tmp/restore/etc/nginx/nginx.conf /etc/nginx/

# PostgreSQL
sudo -u postgres pg_restore --clean --if-exists -d app_production $B/postgres-app_production.dump

# MySQL
gunzip -c $B/mysql-wordpress.sql.gz | sudo mysql wordpress
```

A backup you have never restored is not a backup, so test a restore at least once.

### Step 11 (optional): Copy backups off the server

If the server dies, local backups die with it. To keep a copy on another machine:

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
sudo ssh-copy-id backup@10.0.0.5
```

Then set `REMOTE_BACKUP_TARGET="backup@10.0.0.5:/srv/backups/web-01"`.

### Step 12: Uninstall

```bash
sudo ./uninstall.sh            # keeps config, state and backups
sudo ./uninstall.sh --purge    # also removes config and state (backups are never auto-deleted)
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `cannot read config file` | Run with `sudo`; the config is root-only |
| `$'\r': command not found` | Windows line endings: `sed -i 's/\r$//' bin/opsguard lib/*.sh` |
| `systemd is required` on WSL | Enable systemd in `/etc/wsl.conf` (Step 1) |
| Service always shows DOWN | Check the exact unit name with `systemctl list-units --type=service` |
| Security scan shows 0 logins | Normal on a new or WSL machine; a public VPS usually shows attacks within hours |
| See why a timer run failed | `journalctl -u opsguard-backup.service -n 50` |

## How it works (worth understanding)

- **CPU %** comes from `/proc/stat`, read twice one second apart: `busy = Δ(total − idle) / Δtotal`.
- **Memory %** uses `MemAvailable` from `/proc/meminfo`, not `MemFree`, because Linux uses free RAM as cache.
- **Alert de-duplication:** each alert writes a timestamp file in `/var/lib/opsguard/alert.*`. While that file is newer than the cooldown, the alert isn't repeated. When the problem clears, the file is deleted and a recovery message is sent.
- **Locking:** `flock` stops two runs of the same command from overlapping, for example a slow backup.
- **Safe retention:** old backups are only pruned after a *successful* backup, and failed ones are renamed `*-FAILED`. A week of failures can't wipe out your good backups.
- **Weekly backups** are hard-linked copies (`cp -al`) of Sunday's daily backup, so they take no extra disk space.

## Ideas to extend it

1. Read metrics from several servers over SSH and send one combined report.
2. Add an `opsguard ban <ip>` command that calls `ufw`, or auto-ban brute-forcers.
3. Encrypt backups with `gpg` or `age` before sending them off-site.
4. Upload backups to S3 or Backblaze B2 with `aws s3 sync` or `rclone`.
5. Check SSL certificate expiry for your domains (`openssl s_client`).
6. Check that websites respond with HTTP 200 (`curl -o /dev/null -w '%{http_code}'`).
7. Package it as a `.deb` so other teams can install it with `apt install ./opsguard.deb`.
