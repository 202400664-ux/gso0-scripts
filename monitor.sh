#!/usr/bin/env bash
# monitor.sh - Monitoreo de salud y umbrales (GSO0)
set -u

LOG_DIR="/var/log/gso0"
LOG="$LOG_DIR/monitor.log"
ALERT_LOG="$LOG_DIR/alerts.log"
SERVICES=(nginx mongod gso0-app gso0-frontend)
MOUNTS=(/ /var/log /opt /var/lib/mongodb /srv/backups)
CPU_MAX=85
MEM_MAX=85
DISK_MAX=85
ALERTS=0

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) [INFO] $*" >> "$LOG"; }
alert() {
  ALERTS=$((ALERTS + 1))
  echo "$(ts) [ALERTA] $*" | tee -a "$LOG" >> "$ALERT_LOG"
  logger -t gso0-monitor -p user.crit "$*"
}

cpu_usage() {
  read -r _ u1 n1 s1 i1 w1 q1 sq1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 q2 sq2 _ < /proc/stat
  local idle=$(( (i2 + w2) - (i1 + w1) ))
  local total=$(( (u2+n2+s2+i2+w2+q2+sq2) - (u1+n1+s1+i1+w1+q1+sq1) ))
  [ "$total" -gt 0 ] && echo $(( 100 * (total - idle) / total )) || echo 0
}

mem_usage() {
  awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%d", (t-a)*100/t}' /proc/meminfo
}

# 1. Servicios
for svc in "${SERVICES[@]}"; do
  if ! systemctl is-active --quiet "$svc"; then
    alert "Servicio $svc CAIDO (estado: $(systemctl is-active "$svc"))"
  fi
done

# 2. La aplicacion responde a traves de Nginx
code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ || true)
[ "$code" = "200" ] || alert "La aplicacion no responde por Nginx (HTTP $code)"
api=$(curl -s -o /dev/null -m 5 -w "%{http_code}" http://127.0.0.1/api/roles || true)
case "$api" in 200|401|403) ;; *) alert "La API no responde por Nginx (HTTP $api)" ;; esac

# 3. CPU y memoria
cpu=$(cpu_usage); mem=$(mem_usage)
[ "$cpu" -ge "$CPU_MAX" ] && alert "CPU al ${cpu}% (umbral ${CPU_MAX}%)"
[ "$mem" -ge "$MEM_MAX" ] && alert "Memoria al ${mem}% (umbral ${MEM_MAX}%)"

# 4. Disco por particion
disks=""
for m in "${MOUNTS[@]}"; do
  use=$(df --output=pcent "$m" | tail -1 | tr -dc '0-9')
  disks="$disks $m=${use}%"
  [ "$use" -ge "$DISK_MAX" ] && alert "Disco $m al ${use}% (umbral ${DISK_MAX}%)"
done

log "CPU=${cpu}% MEM=${mem}% DISCO:${disks} | alertas=${ALERTS}"
[ "$ALERTS" -eq 0 ]
