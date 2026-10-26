# Alert delivery: Slack-compatible webhook and email through sendmail.

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  printf '%s' "$s"
}

send_webhook() {
  local text="$1"
  [[ -z "$SLACK_WEBHOOK_URL" ]] && return 0
  local payload
  payload="{\"text\":\"$(json_escape "$text")\"}"
  if ! curl -fsS -m 15 -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null; then
    log ERROR "webhook delivery failed"
    return 1
  fi
}

# send_email SUBJECT BODY [CONTENT_TYPE]
send_email() {
  local subject="$1" body="$2" content_type="${3:-text/plain}"
  [[ -z "$ALERT_EMAIL" ]] && return 0
  local sendmail
  sendmail=$(command -v sendmail || echo /usr/sbin/sendmail)
  if [[ ! -x "$sendmail" ]]; then
    log ERROR "ALERT_EMAIL is set but sendmail was not found (install msmtp-mta, see README)"
    return 1
  fi
  {
    printf 'From: %s\n' "$EMAIL_FROM"
    printf 'To: %s\n' "$ALERT_EMAIL"
    printf 'Subject: %s\n' "$subject"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: %s; charset=UTF-8\n\n' "$content_type"
    printf '%s\n' "$body"
  } | "$sendmail" -t || { log ERROR "email delivery failed"; return 1; }
}

# notify LEVEL TITLE [DETAILS] - log and send to every configured channel.
notify() {
  local level="$1" title="$2" details="${3:-}"
  local icon rc=0
  case "$level" in
    CRITICAL) icon=":red_circle:" ;;
    WARN)     icon=":warning:" ;;
    OK)       icon=":white_check_mark:" ;;
    *)        icon=":information_source:" ;;
  esac
  log "$level" "$title${details:+ | $details}"
  send_webhook "$icon *[$HOST_LABEL] $title*${details:+$'\n'\`\`\`$details\`\`\`}" || rc=1
  send_email "[opsguard][$level] $HOST_LABEL: $title" "${details:-$title}" || rc=1
  return $rc
}
