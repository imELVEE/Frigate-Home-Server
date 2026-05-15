#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$HOME_DIR/logs"

THRESH_WARN=85
THRESH_CRIT=90
LOG="$LOG_DIR/disk_healthcheck.log"
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

if [[ -x "$SCRIPT_DIR/notify_email.py" ]]; then
  "$SCRIPT_DIR/notify_email.py" \
    "Disk space alert on $(hostname)" \
    "Disk usage exceeded thresholds: ${msg}"
fi

exit 1
