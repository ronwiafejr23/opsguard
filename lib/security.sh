# Security scan: SSH brute-force attempts and direct root logins.

# security_events SINCE - sshd log lines since SINCE (e.g. "1 hour ago").
security_events() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --since "$1" --no-pager -q -t sshd -t sshd-session -t sshd-auth 2>/dev/null
  else
    # No journal: fall back to the whole classic log file (no time filter).
    cat /var/log/auth.log /var/log/secure 2>/dev/null
  fi
}

# Prints "COUNT IP" lines, worst first. Each failed attempt is counted once.
failed_logins_by_ip() {
  security_events "$1" \
    | grep -E 'Failed password for |Invalid user ' \
    | grep -v 'Failed password for invalid user' \
    | grep -oE 'from (([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]*:[0-9a-fA-F:]+)' \
    | awk '{print $2}' | sort | uniq -c | sort -rn
}

root_logins() {
  security_events "$1" | grep -E 'Accepted [^ ]+ for root from'
}

# Prints "COUNT USER from IP" for successful logins.
accepted_logins() {
  security_events "$1" \
    | grep -oE 'Accepted [^ ]+ for [^ ]+ from [^ ]+' \
    | awk '{print $4 " from " $6}' | sort | uniq -c | sort -rn
}

run_security_scan() {
  local failed total offenders roots
  failed=$(failed_logins_by_ip "$SECURITY_WINDOW")
  total=$(awk '{s += $1} END {print s + 0}' <<< "$failed")

  echo "Failed SSH logins since $SECURITY_WINDOW: $total"
  [[ -n "$failed" ]] && head -10 <<< "$failed" | sed 's/^/ /'

  offenders=$(awk -v t="$FAILED_LOGIN_THRESHOLD" '$1 >= t {printf "%s failed attempts from %s\n", $1, $2}' <<< "$failed")
  if [[ -n "$offenders" ]] && alert_due ssh_bruteforce; then
    notify WARN "Possible SSH brute-force attack" "$offenders
Block an IP with: sudo ufw deny from <ip>   (or install fail2ban)"
  fi

  roots=$(root_logins "$SECURITY_WINDOW")
  if [[ -n "$roots" ]]; then
    echo "Direct root logins:"
    sed 's/^/  /' <<< "$roots"
    if alert_due root_login; then
      notify WARN "Direct root SSH login detected" "$roots
Consider 'PermitRootLogin no' in /etc/ssh/sshd_config."
    fi
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "Note: not running as root, so some log entries may be hidden."
  fi
  log INFO "security scan: $total failed SSH logins since $SECURITY_WINDOW" >/dev/null
}
