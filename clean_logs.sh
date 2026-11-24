#!/usr/bin/env bash
# clean_logs.sh - Depuracion y retencion (GSO0)
set -u

LOG_DIR="/var/log/gso0"
BACKUP_DIR="/srv/backups"
LOG="$LOG_DIR/clean_logs.log"
ALERT_LOG="$LOG_DIR/alerts.log"
RET_BACKUPS_DAYS=15
RET_LOGS_DAYS=30
MIN_BACKUPS=2
DISK_MAX=85

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [INFO] $*" >> "$LOG"; }
alert() {
  echo "$(ts) [ALERTA] clean_logs.sh: $*" | tee -a "$LOG" >> "$ALERT_LOG"
  logger -t gso0-clean -p user.crit "$*"
}

log "Inicio de depuracion (respaldos > ${RET_BACKUPS_DAYS} dias, bitacoras > ${RET_LOGS_DAYS} dias)"

# 1. Respaldos vencidos (se conservan siempre los MIN_BACKUPS mas recientes)
del_bk=0; bytes_bk=0; idx=0; NOW=$(date +%s)
while read -r _ f; do
  idx=$((idx + 1))
  [ "$idx" -le "$MIN_BACKUPS" ] && continue
  age=$(( (NOW - $(stat -c %Y "$f")) / 86400 ))
  if [ "$age" -gt "$RET_BACKUPS_DAYS" ]; then
    size=$(stat -c %s "$f")
    if rm -f -- "$f" "$f.sha256"; then
      del_bk=$((del_bk + 1)); bytes_bk=$((bytes_bk + size))
      log "Respaldo eliminado: $(basename "$f") (${age} dias)"
    fi
  fi
done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' -printf '%T@ %p\n' | sort -rn)

# 2. Checksums huerfanos y restos de respaldos fallidos
for s in "$BACKUP_DIR"/backup_*.tar.gz.sha256; do
  [ -e "$s" ] || continue
  [ -e "${s%.sha256}" ] || { rm -f -- "$s"; log "Checksum huerfano eliminado: $(basename "$s")"; }
done
find "$BACKUP_DIR" -maxdepth 1 -type d -name '.stage_*' -mmin +60 -exec rm -rf {} + 2>/dev/null

# 3. Rotar y comprimir las bitacoras de los scripts
rot=0
for f in "$LOG_DIR/monitor.log" "$LOG_DIR/alerts.log" "$LOG_DIR/backup.log"; do
  [ -s "$f" ] || continue
  gz="${f}.$(date +%Y%m%d_%H%M).gz"
  if gzip -c "$f" > "$gz"; then
    : > "$f"; chgrp admins "$gz"; chmod 640 "$gz"
    rot=$((rot + 1)); log "Bitacora rotada y comprimida: $(basename "$gz")"
  fi
done

# 4. Eliminar bitacoras comprimidas vencidas y compactar el journal
old=$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.gz' -mtime +"$RET_LOGS_DAYS" -print -delete | wc -l)
journalctl --vacuum-time="${RET_LOGS_DAYS}d" >/dev/null 2>&1

# 5. Alerta si algun disco sigue lleno
for m in /var/log "$BACKUP_DIR"; do
  use=$(df --output=pcent "$m" | tail -1 | tr -dc '0-9')
  [ "$use" -ge "$DISK_MAX" ] && alert "Disco $m sigue al ${use}% tras la depuracion"
done

log "Fin: respaldos eliminados=${del_bk} ($((bytes_bk / 1024)) KB), bitacoras rotadas=${rot}, comprimidas vencidas eliminadas=${old}"
exit 0
