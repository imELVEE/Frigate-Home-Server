#!/usr/bin/env bash
# Weekly Lynis host audit with email summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$HOME_DIR/logs"
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

# Make sure the home directory owner can read the outputs
OWNER_UID="$(stat -c '%u' "$HOME_DIR")"
OWNER_GID="$(stat -c '%g' "$HOME_DIR")"
chown "$OWNER_UID:$OWNER_GID" "$LOG_FILE" "$REPORT_FILE"

subject="Lynis host audit: $warnings warnings, $suggestions suggestions"
body="Lynis completed at $(date -u).\nWarnings: $warnings\nSuggestions: $suggestions\nReport: $REPORT_FILE\nLog: $LOG_FILE"

"$SCRIPT_DIR/notify_email.py" "$subject" "$body"
