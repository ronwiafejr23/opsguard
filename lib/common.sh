# Shared helpers: defaults, logging, locking and alert de-duplication.

# Defaults for anything the config file leaves out.
: "${HOST_LABEL:=$(hostname -f 2>/dev/null || hostname)}"
: "${CPU_THRESHOLD:=90}"
: "${MEM_THRESHOLD:=90}"
: "${DISK_THRESHOLD:=85}"
: "${DISK_MOUNTS:=/}"
: "${SERVICES:=}"
: "${AUTO_RESTART_SERVICES:=no}"
: "${BACKUP_MAX_AGE_HOURS:=26}"
: "${SLACK_WEBHOOK_URL:=}"
: "${ALERT_EMAIL:=}"
: "${EMAIL_FROM:=opsguard@$(hostname)}"
: "${ALERT_COOLDOWN:=3600}"
: "${ALERTS_ENABLED:=yes}"
: "${BACKUP_DIR:=/var/backups/opsguard}"
: "${BACKUP_PATHS:=/etc}"
: "${BACKUP_EXCLUDES:=}"
: "${POSTGRES_DBS:=}"
: "${MYSQL_DBS:=}"
: "${KEEP_DAILY:=7}"
: "${KEEP_WEEKLY:=4}"
: "${REMOTE_BACKUP_TARGET:=}"
: "${NOTIFY_ON_BACKUP_SUCCESS:=no}"
: "${SECURITY_WINDOW:=1 hour ago}"
: "${FAILED_LOGIN_THRESHOLD:=10}"
: "${STATE_DIR:=/var/lib/opsguard}"
: "${LOG_FILE:=/var/log/opsguard.log}"

# When not running as root (e.g. while developing), keep state in the user's home.
if ! mkdir -p "$STATE_DIR" 2>/dev/null || [[ ! -w "$STATE_DIR" ]]; then
  STATE_DIR="$HOME/.local/state/opsguard"
  mkdir -p "$STATE_DIR"
fi
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="$STATE_DIR/opsguard.log"
fi

log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  if [[ "$level" == ERROR || "$level" == CRITICAL ]]; then
    echo "$line" >&2
  else
    echo "$line"
  fi
  # One line per entry in the log file, so it stays easy to grep.
  echo "${line//$'\n'/ \\n }" >> "$LOG_FILE" 2>/dev/null || true
  [[ "$level" == ERROR ]] && RUN_ERRORS+="$*"$'\n'
  return 0
}

RUN_ERRORS=""

# with_lock NAME CMD... - run CMD unless another "opsguard NAME" is still running.
with_lock() {
  local name="$1"; shift
  exec 9>"$STATE_DIR/$name.lock"
  if ! flock -n 9; then
    log WARN "another 'opsguard $name' is already running; skipping"
    return 0
  fi
  "$@"
}

# Alert state files let us send each alert once per cooldown and announce recovery.
alert_file() { echo "$STATE_DIR/alert.${1//[^a-zA-Z0-9_.-]/_}"; }

# alert_due KEY - succeeds (and records the time) if KEY hasn't alerted within ALERT_COOLDOWN.
alert_due() {
  local file now last
  file=$(alert_file "$1")
  now=$(date +%s)
  if [[ -f "$file" ]]; then
    last=$(<"$file")
    (( now - last < ALERT_COOLDOWN )) && return 1
  fi
  echo "$now" > "$file"
}

alert_active() { [[ -f "$(alert_file "$1")" ]]; }
alert_clear()  { rm -f "$(alert_file "$1")"; }

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
