#!/usr/bin/env bash
# Weekly Lynis host audit with email summary.
set -euo pipefail

USER_HOME="/home/reolink_server_admin"
LOG_DIR="$USER_HOME/logs"
mkdir -p "$LOG_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/lynis_${TS}.log"
REPORT_FILE="$LOG_DIR/lynis_${TS}.report"

/usr/sbin/lynis audit system \
  --quiet \
  --logfile "$LOG_FILE" \
  --report-file "$REPORT_FILE"

# Extract counts from report (warning[]= and suggestion[]= lines)
warnings=$(grep -c '^warning' "$REPORT_FILE" 2>/dev/null || true)
suggestions=$(grep -c '^suggestion' "$REPORT_FILE" 2>/dev/null || true)

# Make sure the unprivileged user can read the outputs
chown reolink_server_admin:reolink_server_admin "$LOG_FILE" "$REPORT_FILE"

subject="Lynis host audit: $warnings warnings, $suggestions suggestions"
body="Lynis completed at $(date -u).\nWarnings: $warnings\nSuggestions: $suggestions\nReport: $REPORT_FILE\nLog: $LOG_FILE"

$USER_HOME/scripts/notify_email.py "$subject" "$body"
