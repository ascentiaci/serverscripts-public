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

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
# Uptime monitor endpoints
UP_SUCCESS="https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=up&msg=Docker%20Cleanup%20Succeeded"
UP_FAILURE="https://uptime.888ltd.ca/api/push/RqHXLf4ntT?status=down&msg=Docker%20Cleanup%20Failed"

# Webhook for error summaries
WEBHOOK_URL="https://n8n.888ltd.ca/webhook/4f6fe3d5-d86c-485e-8c1d-f78e43c5d76f"

# Moodle domain (for SSL check)
MOODLE_DOMAIN="your.moodle.domain"

# Paths
LOG_FILE="/var/log/daily.sh.log"
DATA_DIR="/var/www/moodledata"
BACKUP_DIR="/var/backups/moodle"

# Retention
BACKUP_RETENTION_DAYS=7
DISK_ALERT_THRESHOLD=80  # percent

# ─── SCRIPT START ─────────────────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Starting maintenance…"

# ─── 1) Docker Cleanup ───────────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Cleaning Docker…"
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

# ─── 2) APT Maintenance ──────────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Running APT maintenance…"
if apt-get update && apt-get -y upgrade && apt-get -y autoremove && apt-get -y autoclean; then
  echo "✔ APT maintenance completed"
else
  echo "✖ APT maintenance encountered errors"
fi

# ─── 3) Service Health Checks ─────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Checking service statuses…"
for svc in apache2 mysql; do
  status=\$(systemctl is-active "$svc" || echo "unknown")
  echo " - \$svc: \$status"
done

# ─── 4) Disk Usage Alert ─────────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Checking disk usage for \$DATA_DIR…"
util=\$(df --output=pcent "$DATA_DIR" | tail -1 | tr -dc '0-9')
if [ "\$util" -ge \$DISK_ALERT_THRESHOLD ]; then
  echo "⚠ Disk usage on \$DATA_DIR is at \${util}%"
fi

# ─── 5) Moodle Backups ───────────────────────────────────────────────────────
echo "[\$(date '+%F %T')] Performing Moodle backups…"
mkdir -p "$BACKUP_DIR"
TS=\$(date +'%F_%H%M')

# Database backup
if mysqldump --single-transaction -u root moodle > "$BACKUP_DIR/db_\${TS}.sql"; then
  echo " - DB backup db_\${TS}.sql created"
else
  echo " - ERROR: DB backup failed"
fi

# File backup
if tar czf "$BACKUP_DIR/moodledata_\${TS}.tar.gz" -C /var/www moodledata; then
  echo " - File backup moodledata_\${TS}.tar.gz created"
else
  echo " - ERROR: File backup failed"
fi

# Purge old backups
echo "[\$(date '+%F %T')] Purging backups older than \${BACKUP_RETENTION_DAYS} days…"
find "$BACKUP_DIR" -type f -mtime +\$BACKUP_RETENTION_DAYS -exec rm {} \; && \
  echo " - Old backups purged"

# ─── 6) SSL Certificate Expiry ───────────────────────────────────────────────
echo "[\$(date '+%F %T')] Checking SSL expiry for \$MOODLE_DOMAIN…"
enddate=\$(echo | openssl s_client -servername "$MOODLE_DOMAIN" -connect "$MOODLE_DOMAIN:443" 2>/dev/null \
  | openssl x509 -noout -enddate | cut -d= -f2)
exp_ts=\$(date -d "\$enddate" +%s)
now_ts=\$(date +%s)
days_left=\$(( (exp_ts - now_ts) / 86400 ))
echo " - SSL cert expires in \$days_left days (on \$enddate)"

# ─── 7) Consolidated Report → Webhook ────────────────────────────────────────
# Include reverse DNS lookup
IP_ADDR=\$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print \$7; exit}')
if command -v dig &>/dev/null; then
  RDNS=\$(dig +short -x "\$IP_ADDR" | sed 's/\.$//')
else
  RDNS=\$(getent hosts "\$IP_ADDR" | awk '{print \$2}')
fi
RDNS=\${RDNS:-unknown-host}

echo "[\$(date '+%F %T')] Building error report…"
SINCE=\$(date -d "1 hour ago" '+%Y-%m-%dT%H:%M:%S')
REPORT="Error summary for the last hour on \${RDNS} (since \${SINCE}):\n"
for CONTAINER in \$(docker ps --format '{{.Names}}'); do
  REPORT+=\$'\n'"Container: \$CONTAINER"\$'\n'
  ERRORS=\$(docker logs --since "\$SINCE" "\$CONTAINER" 2>&1 \
    | grep -i "error" \
    | sed -E 's/^\[[^]]+\]\s*//' \
    | sort \
    | uniq -c \
    | sort -nr \
    | awk '{ printf("%5d × %s\n",\$1, substr(\$0, index(\$0,\$2))) }')
  if [[ -z "\$ERRORS" ]]; then
    REPORT+="    No errors in the last hour.\n"
  else
    REPORT+=\$ERRORS
  fi
done

# Debug output
echo -e "── RAW REPORT ──"
echo -e "\$REPORT"
echo -e "────────────────"

# Prepare payload
if command -v jq &>/dev/null; then
  PAYLOAD=\$(jq -Rn --arg text "\$REPORT" '{text: $text}')
else
  ESC=\$(printf '%s' "\$REPORT" \
    | sed -e 's/\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\r\?\\n/\\n/g')
  PAYLOAD="{\"text\":\"\${ESC}\"}"
fi

echo "Posting report to: \${WEBHOOK_URL}?host=\${RDNS}"
curl -fsSL -X POST \
  -H "Content-Type: application/json" \
  -d "\$PAYLOAD" \
  "\${WEBHOOK_URL}?host=\${RDNS}" \
  && echo "✅ Report posted" \
  || echo "❌ Failed to post report"

echo "[$(date '+%F %T')] Maintenance complete."
