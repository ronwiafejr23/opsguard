# Health checks: CPU, memory, disk, systemd services and backup age.

# CPU busy % over one second, from the deltas of the first line of /proc/stat.
cpu_usage() {
  local _ user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  local idle1=$((idle + iowait))
  local total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  sleep 1
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  local idle2=$((idle + iowait))
  local total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local dt=$((total2 - total1)) di=$((idle2 - idle1))
  if (( dt <= 0 )); then echo 0; else echo $(( 100 * (dt - di) / dt )); fi
}

mem_usage() {
  awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
       END { if (t > 0) printf "%d\n", (t - a) * 100 / t; else print 0 }' /proc/meminfo
}

disk_usage() {
  df -P "$1" 2>/dev/null | awk 'NR == 2 { sub(/%/, "", $5); print $5 }'
}

top_processes() {
  ps -eo pid,user,%cpu,%mem,comm --sort=-"$1" | head -6
}

# check_threshold KEY LABEL VALUE THRESHOLD [DETAILS] - fails when VALUE >= THRESHOLD.
check_threshold() {
  local key="$1" label="$2" value="$3" threshold="$4" details="${5:-}"
  if (( value >= threshold )); then
    if [[ "$ALERTS_ENABLED" == yes ]] && alert_due "$key"; then
      notify WARN "$label is at ${value}% (threshold ${threshold}%)" "$details"
    fi
    return 1
  fi
  if [[ "$ALERTS_ENABLED" == yes ]] && alert_active "$key"; then
    alert_clear "$key"
    notify OK "$label back to normal (${value}%)"
  fi
  return 0
}

# check_service NAME - fails if the unit isn't active (after one restart attempt if enabled).
check_service() {
  local svc="$1" key="svc_$1" state
  if ! systemctl is-active --quiet "$svc" && [[ "$AUTO_RESTART_SERVICES" == yes && "$ALERTS_ENABLED" == yes ]]; then
    log WARN "service $svc is down, attempting restart"
    systemctl restart "$svc" 2>/dev/null && sleep 3
  fi
  if systemctl is-active --quiet "$svc"; then
    if [[ "$ALERTS_ENABLED" == yes ]] && alert_active "$key"; then
      alert_clear "$key"
      notify OK "Service $svc is running again"
    fi
    return 0
  fi
  state=$(systemctl is-active "$svc" 2>/dev/null || true)
  if [[ "$ALERTS_ENABLED" == yes ]] && alert_due "$key"; then
    notify CRITICAL "Service $svc is ${state:-unknown}" \
      "$(journalctl -u "$svc" -n 15 --no-pager 2>/dev/null || echo 'no journal entries available')"
  fi
  return 1
}

# Fails if the last successful backup is older than BACKUP_MAX_AGE_HOURS.
check_backup_age() {
  local file="$STATE_DIR/last_backup_ok" last age_h
  (( BACKUP_MAX_AGE_HOURS > 0 )) || return 0
  [[ -f "$file" ]] || return 0  # no backup has run yet
  last=$(<"$file")
  age_h=$(( ($(date +%s) - last) / 3600 ))
  if (( age_h >= BACKUP_MAX_AGE_HOURS )); then
    if [[ "$ALERTS_ENABLED" == yes ]] && alert_due backup_age; then
      notify CRITICAL "Last successful backup was ${age_h} hours ago" "Check: journalctl -u opsguard-backup.service"
    fi
    return 1
  fi
  [[ "$ALERTS_ENABLED" == yes ]] && alert_clear backup_age
  return 0
}

status_row() { printf '  %-32s %-10s %s\n' "$1" "$2" "$3"; }

run_health_checks() {
  local problems=0 cpu mem disk mount svc first_disk=""
  cpu=$(cpu_usage)
  mem=$(mem_usage)

  echo "opsguard health check - $HOST_LABEL - $(date '+%F %T')"
  status_row "CHECK" "VALUE" "STATUS"

  if check_threshold cpu "CPU usage" "$cpu" "$CPU_THRESHOLD" "$(top_processes %cpu)"; then
    status_row "cpu" "${cpu}%" OK
  else
    status_row "cpu" "${cpu}%" HIGH; problems=$((problems + 1))
  fi

  if check_threshold mem "Memory usage" "$mem" "$MEM_THRESHOLD" "$(top_processes %mem)"; then
    status_row "memory" "${mem}%" OK
  else
    status_row "memory" "${mem}%" HIGH; problems=$((problems + 1))
  fi

  status_row "load (1/5/15 min)" "$(cut -d' ' -f1-3 /proc/loadavg)" ""

  for mount in $DISK_MOUNTS; do
    disk=$(disk_usage "$mount")
    if [[ -z "$disk" ]]; then
      status_row "disk $mount" "-" MISSING; problems=$((problems + 1))
      continue
    fi
    [[ -z "$first_disk" ]] && first_disk=$disk
    if check_threshold "disk_$mount" "Disk $mount" "$disk" "$DISK_THRESHOLD" "$(df -hP "$mount")"; then
      status_row "disk $mount" "${disk}%" OK
    else
      status_row "disk $mount" "${disk}%" FULL; problems=$((problems + 1))
    fi
  done

  for svc in $SERVICES; do
    if check_service "$svc"; then
      status_row "service $svc" "active" OK
    else
      status_row "service $svc" "$(systemctl is-active "$svc" 2>/dev/null || true)" DOWN
      problems=$((problems + 1))
    fi
  done

  local last_backup
  last_backup=$(cut -d' ' -f1-2 "$STATE_DIR/last_backup" 2>/dev/null || echo never)
  if check_backup_age; then
    status_row "last backup" "$last_backup" OK
  else
    status_row "last backup" "$last_backup" STALE
    problems=$((problems + 1))
  fi

  # Keep about a week of 5-minute samples for the daily report's trends.
  if [[ "$ALERTS_ENABLED" == yes ]]; then
    local metrics="$STATE_DIR/metrics.csv"
    echo "$(date +%s),$cpu,$mem,${first_disk:-0}" >> "$metrics"
    if (( $(wc -l < "$metrics") > 3000 )); then
      tail -n 2016 "$metrics" > "$metrics.tmp" && mv "$metrics.tmp" "$metrics"
    fi
    log INFO "health check finished: $problems problem(s)" >/dev/null
  fi

  echo "Problems: $problems"
  (( problems == 0 ))
}
