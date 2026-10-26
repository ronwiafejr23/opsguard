# Backups: files (tar), PostgreSQL, MySQL/MariaDB, checksums, retention and off-site copy.
#
# Layout:  $BACKUP_DIR/daily/2026-10-26_020000/{files.tar.gz,postgres-*.dump,mysql-*.sql.gz,SHA256SUMS}
#          $BACKUP_DIR/weekly/<same names>   (hard-linked copies of Sunday's backup)

BACKUP_NAME_PATTERN='20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]'

backup_files() {
  local dest="$1" paths patterns excludes=() pattern err rc
  # read -a splits on spaces without glob-expanding patterns like *.tmp
  read -ra paths <<< "$BACKUP_PATHS"
  read -ra patterns <<< "$BACKUP_EXCLUDES"
  (( ${#paths[@]} )) || return 0
  for pattern in "${patterns[@]}"; do excludes+=("--exclude=$pattern"); done

  # Archive relative to / so tar doesn't warn about leading slashes.
  err=$(tar -C / -czf "$dest/files.tar.gz" "${excludes[@]}" "${paths[@]#/}" 2>&1 >/dev/null)
  rc=$?
  if (( rc == 0 )); then
    log INFO "files: archived ${paths[*]} ($(du -h "$dest/files.tar.gz" | cut -f1))"
  elif (( rc == 1 )); then
    log WARN "files: some files changed while being archived (backup still usable)"
  else
    log ERROR "files: tar failed: $err"
    return 1
  fi
}

backup_postgres() {
  local db="$1" dest="$2" out="$2/postgres-$1.dump" runner=()
  [[ $EUID -eq 0 ]] && runner=(runuser -u postgres --)
  if "${runner[@]}" pg_dump --format=custom "$db" > "$out" 2>"$STATE_DIR/dump.err"; then
    log INFO "postgres: dumped $db ($(du -h "$out" | cut -f1))"
  else
    log ERROR "postgres: dump of $db failed: $(<"$STATE_DIR/dump.err")"
    return 1
  fi
}

backup_mysql() {
  local db="$1" dest="$2" out="$2/mysql-$1.sql.gz"
  if mysqldump --single-transaction --routines --triggers "$db" 2>"$STATE_DIR/dump.err" | gzip > "$out"; then
    log INFO "mysql: dumped $db ($(du -h "$out" | cut -f1))"
  else
    log ERROR "mysql: dump of $db failed: $(<"$STATE_DIR/dump.err")"
    return 1
  fi
}

# prune_backups DIR KEEP - delete all but the newest KEEP backups in DIR.
prune_backups() {
  local dir="$1" keep="$2" old
  [[ -d "$dir" ]] || return 0
  (( keep < 1 )) && keep=1
  # Names are timestamps, so sorting by name sorts by date.
  find "$dir" -mindepth 1 -maxdepth 1 -type d -name "$BACKUP_NAME_PATTERN" -printf '%f\n' \
    | sort -r | tail -n +$((keep + 1)) \
    | while read -r old; do
        rm -rf -- "${dir:?}/$old"
        log INFO "retention: removed $dir/$old"
      done
}

run_backup() {
  local stamp dest errors=0 start db status size
  start=$(date +%s)
  stamp=$(date +%Y-%m-%d_%H%M%S)
  dest="$BACKUP_DIR/daily/$stamp"

  if ! mkdir -p "$dest"; then
    notify CRITICAL "Backup failed" "Cannot create $dest"
    return 1
  fi
  chmod 700 "$BACKUP_DIR"
  log INFO "backup started -> $dest"

  backup_files "$dest" || errors=$((errors + 1))
  for db in $POSTGRES_DBS; do backup_postgres "$db" "$dest" || errors=$((errors + 1)); done
  for db in $MYSQL_DBS; do backup_mysql "$db" "$dest" || errors=$((errors + 1)); done

  if [[ -n "$(ls -A "$dest")" ]]; then
    (cd "$dest" && sha256sum -- * > SHA256SUMS) || errors=$((errors + 1))
  fi

  size=$(du -sh "$dest" | cut -f1)
  if (( errors > 0 )); then
    # Rename so retention never counts a broken backup as a good one.
    mv "$dest" "$dest-FAILED"
    status=FAILED
    notify CRITICAL "Backup failed with $errors error(s)" "${RUN_ERRORS}Failed backup kept at $dest-FAILED"
  else
    status=OK
    date +%s > "$STATE_DIR/last_backup_ok"
    if [[ "$(date +%u)" == 7 ]]; then
      mkdir -p "$BACKUP_DIR/weekly"
      cp -al "$dest" "$BACKUP_DIR/weekly/$stamp"
      log INFO "weekly copy saved to $BACKUP_DIR/weekly/$stamp"
    fi
    # Only prune after a good backup, so repeated failures never delete good backups.
    prune_backups "$BACKUP_DIR/daily" "$KEEP_DAILY"
    prune_backups "$BACKUP_DIR/weekly" "$KEEP_WEEKLY"
    find "$BACKUP_DIR/daily" -mindepth 1 -maxdepth 1 -type d -name '*-FAILED' -mtime +7 -exec rm -rf {} +

    if [[ -n "$REMOTE_BACKUP_TARGET" ]]; then
      if rsync -a --delete -e "ssh -o BatchMode=yes" "$BACKUP_DIR/" "$REMOTE_BACKUP_TARGET/"; then
        log INFO "off-site copy synced to $REMOTE_BACKUP_TARGET"
      else
        status="OK(offsite-failed)"
        notify CRITICAL "Off-site backup copy failed" "rsync to $REMOTE_BACKUP_TARGET failed"
      fi
    fi
    [[ "$NOTIFY_ON_BACKUP_SUCCESS" == yes ]] && notify OK "Backup $stamp completed ($size)"
  fi

  echo "$stamp $status $size $(( $(date +%s) - start ))s" > "$STATE_DIR/last_backup"
  log INFO "backup finished: $status, $size in $(( $(date +%s) - start ))s"
  [[ "$status" != FAILED ]]
}

list_backups() {
  local kind dir
  for kind in daily weekly; do
    dir="$BACKUP_DIR/$kind"
    echo "$kind backups ($dir):"
    if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
      du -sh "$dir"/* | sort -k2 | sed 's/^/  /'
    else
      echo "  (none)"
    fi
  done
}

# verify_backup [NAME] - check SHA256SUMS of a backup (default: newest daily one).
verify_backup() {
  local name="$1" dir
  if [[ -z "$name" ]]; then
    name=$(find "$BACKUP_DIR/daily" -mindepth 1 -maxdepth 1 -type d -name "$BACKUP_NAME_PATTERN" \
             -printf '%f\n' 2>/dev/null | sort -r | head -1)
  fi
  dir="$BACKUP_DIR/daily/$name"
  [[ -d "$dir" ]] || dir="$BACKUP_DIR/weekly/$name"
  if [[ -z "$name" || ! -f "$dir/SHA256SUMS" ]]; then
    echo "No backup found to verify${name:+ named $name}" >&2
    return 1
  fi
  echo "Verifying $dir"
  (cd "$dir" && sha256sum -c SHA256SUMS) && tar -tzf "$dir/files.tar.gz" >/dev/null 2>&1 \
    && echo "Backup $name is intact."
}
