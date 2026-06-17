#!/usr/bin/env bash
set -euo pipefail

THRESH_WARN=85
THRESH_CRIT=90
LOG=/home/reolink_server_admin/logs/disk_healthcheck.log
mkdir -p "$(dirname "$LOG")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

issues=()
while read -r fs size used avail pcent mount; do
  pct=${pcent%%%}
  if (( pct >= THRESH_CRIT )); then
    issues+=("CRIT ${mount} at ${pct}% (fs ${fs}, avail ${avail})")
  elif (( pct >= THRESH_WARN )); then
    issues+=("WARN ${mount} at ${pct}% (fs ${fs}, avail ${avail})")
  fi
done < <(df -hP | tail -n +2)

if (( ${#issues[@]} == 0 )); then
  echo "${STAMP} OK: disk usage below thresholds" >> "$LOG"
  exit 0
fi

msg=$(printf '%s; ' "${issues[@]}")
echo "${STAMP} ALERT: ${msg}" >> "$LOG"

if [[ -x /home/reolink_server_admin/scripts/notify_email.py ]]; then
  /home/reolink_server_admin/scripts/notify_email.py \
    "Disk space alert on $(hostname)" \
    "Disk usage exceeded thresholds: ${msg}"
fi

exit 1
