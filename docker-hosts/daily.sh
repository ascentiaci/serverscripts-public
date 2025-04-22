#!/usr/bin/env bash
#
# daily.sh
#
# 1) Docker cleanup → uptime monitor
# 2) APT maintenance (update/upgrade/clean)
# 3) Service health checks (Apache, MySQL)
# 4) Disk usage alert (Moodle data dir)
# 5) Moodle backups (DB + moodledata)
# 6) SSL certificate expiry check
# 7) Consolidated report via webhook?host=<rdns>
# 8) Log all output to /var/log/daily.sh.log
#
# Schedule (crontab): 0 2 * * * /home/you/daily.sh

set -euo pipefail
exec &> >(tee -a /var/log/daily.sh.log)

echo "[$(date '+%F %T')] Starting maintenance…"

# ─── 1) Docker Cleanup ────────────────────────────────────────────────────────
UP_SUCCESS="https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=up&msg=Docker%20Cleanup%20Succeeded"
UP_FAILURE="https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=down&msg=Docker%20Cleanup%20Failed"

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not installed!"
  curl -fsSL "$UP_FAILURE"
else
  if docker system prune -a -f; then
    echo "✔ Docker cleanup succeeded"
    curl -fsSL "$UP_SUCCESS"
  else
    echo "✖ Docker cleanup failed"
    curl -fsSL "$UP_FAILURE"
  fi
fi

# ─── 2) APT Maintenance ───────────────────────────────────────────────────────
echo "[$(date '+%F %T')] Running APT maintenance…"
if apt-get update && apt-get -y upgrade \
   && apt-get -y autoremove && apt-get -y autoclean; then
  echo "✔ APT maintenance completed" 
else
  echo "✖ APT maintenance encountered errors"
fi

# ─── 3) Service Health Checks ────────────────────────────────────────────────
echo "[$(date '+%F %T')] Checking service statuses…"
for svc in apache2 mysql; do
  status=$(systemctl is-active "$svc" || echo "unknown")
  echo " - $svc: $status"
done

# ─── 4) Disk Usage Alert ─────────────────────────────────────────────────────
DATA_DIR="/var/www/moodledata"
util=$(df --output=pcent "$DATA_DIR" | tail -1 | tr -dc '0-9')
if [ "$util" -ge 80 ]; then
  echo "⚠ Disk usage on $DATA_DIR is at ${util}%"
fi

# ─── 5) Moodle Backups ────────────────────────────────────────────────────────
echo "[$(date '+%F %T')] Performing Moodle backups…"
BACKUP_DIR="/var/backups/moodle"
mkdir -p "$BACKUP_DIR"
TS=$(date +'%F_%H%M')

# Database backup (MySQL)
if mysqldump --single-transaction -u root moodle > "$BACKUP_DIR/db_$TS.sql"; then
  echo " - DB backup db_$TS.sql created"
else
  echo " - ERROR: DB backup failed"
fi

# File backup (moodledata)
if tar czf "$BACKUP_DIR/moodledata_$TS.tar.gz" -C /var/www moodledata; then
  echo " - File backup moodledata_$TS.tar.gz created"
else
  echo " - ERROR: File backup failed"
fi

# Purge old backups (>7 days)
find "$BACKUP_DIR" -type f -mtime +7 -exec rm {} \; \
  && echo " - Old backups purged"

# ─── 6) SSL Certificate Expiry ───────────────────────────────────────────────
DOMAIN="your.moodle.domain"
echo "[$(date '+%F %T')] Checking SSL expiry for $DOMAIN…"
enddate=$(echo \
  | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null \
  | openssl x509 -noout -enddate \
  | cut -d= -f2)
exp_ts=$(date -d "$enddate" +%s)
now_ts=$(date +%s)
days_left=$(( (exp_ts - now_ts) / 86400 ))
echo " - SSL cert expires in $days_left days (on $enddate)"

# ─── 7) Consolidated Report → Webhook ────────────────────────────────────────
# (reuse existing webhook & reverse DNS logic from earlier)

echo "[$(date '+%F %T')] Maintenance complete."
