#!/usr/bin/env bash
# backup.sh - Respaldo automatizado e integridad (GSO0)
set -euo pipefail
umask 077

BACKUP_DIR="/srv/backups"
LOG="/var/log/gso0/backup.log"
ALERT_LOG="/var/log/gso0/alerts.log"
DB_CONF="/etc/gso0/backup.conf"
STAMP="$(date +%Y%m%d_%H%M)"
NAME="backup_${STAMP}"
FINAL="$BACKUP_DIR/${NAME}.tar.gz"
STAGE="$(mktemp -d "$BACKUP_DIR/.stage_XXXXXX")"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [INFO] $*" >> "$LOG"; }
fail() {
  echo "$(ts) [ALERTA] backup.sh: $*" | tee -a "$LOG" >> "$ALERT_LOG"
  logger -t gso0-backup -p user.crit "$*"
  rm -rf "$STAGE" "$FINAL" "$FINAL.sha256"
  exit 1
}
trap 'rm -rf "$STAGE"' EXIT
trap 'fail "error inesperado en la linea $LINENO"' ERR

log "Inicio de respaldo $NAME"

# 1. Volcado consistente de MongoDB (con oplog: punto unico en el tiempo)
mongodump --config="$DB_CONF" --oplog --gzip --archive="$STAGE/mongodb.archive.gz" --quiet \
  || fail "mongodump fallo"

# 2. Archivos de configuracion criticos
mkdir -p "$STAGE/config"
for f in /opt/app/config/.env \
         /etc/nginx/sites-available/gso0 \
         /etc/nginx/conf.d/hardening.conf \
         /etc/mongod.conf \
         /etc/ssh/sshd_config.d/00-hardening.conf \
         /etc/systemd/system/gso0-app.service \
         /etc/systemd/system/gso0-frontend.service \
         /etc/logrotate.d/gso0-app \
         /etc/logrotate.d/mongod \
         /etc/netplan/50-cloud-init.yaml; do
  [ -f "$f" ] || fail "falta el archivo critico $f"
  cp --parents -p "$f" "$STAGE/config/"
done
[ -f /etc/cron.d/gso0 ] && cp --parents -p /etc/cron.d/gso0 "$STAGE/config/"

# 2b. Scripts operativos (ademas del repositorio remoto)
mkdir -p "$STAGE/scripts"; tar -C /opt/app/scripts --exclude=.git -cf - . | tar -C "$STAGE/scripts" -xf -

# 3. Empaquetado comprimido con marca de tiempo
tar -czf "$FINAL" -C "$STAGE" . || fail "no se pudo crear el paquete"

# 4. Verificacion de integridad
( cd "$BACKUP_DIR" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )
( cd "$BACKUP_DIR" && sha256sum -c --quiet "${NAME}.tar.gz.sha256" ) || fail "el checksum no coincide"
tar -tzf "$FINAL" > "$STAGE/lista.txt" || fail "la prueba de lectura del paquete fallo"
grep -q 'mongodb.archive.gz' "$STAGE/lista.txt" || fail "el paquete no contiene el volcado de MongoDB"
grep -q 'config/opt/app/config/.env' "$STAGE/lista.txt" || fail "el paquete no contiene el .env"

chown root:admins "$FINAL" "$FINAL.sha256"
chmod 640 "$FINAL" "$FINAL.sha256"
log "OK ${NAME}.tar.gz ($(du -h "$FINAL" | cut -f1)) checksum y lectura verificados"
