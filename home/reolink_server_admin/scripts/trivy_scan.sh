#!/usr/bin/env bash
# Weekly Trivy scan of running container images; emails on HIGH/CRITICAL findings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$HOME_DIR/logs"
mkdir -p "$LOG_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$LOG_DIR/trivy_scan_${TS}.log"

IMAGES=$(docker ps --format '{{.Image}}' | sort -u | grep -v '<none>' || true)
if [[ -z "$IMAGES" ]]; then
  echo "No running images to scan" | tee "$LOG_FILE"
  exit 0
fi

scan_failed=0

{
  echo "=== Trivy scan $(date -u) ==="
  for img in $IMAGES; do
    echo "--- Scanning $img ---"
    /usr/local/bin/trivy image \
      --ignore-unfixed \
      --severity HIGH,CRITICAL \
      --exit-code 1 \
      --format table \
      "$img" || scan_failed=1
    echo
  done
} | tee "$LOG_FILE"

if [[ $scan_failed -ne 0 ]]; then
  "$SCRIPT_DIR/notify_email.py" \
    "CVE scan alert: HIGH/CRITICAL found" \
    "Trivy detected HIGH/CRITICAL vulnerabilities in running images. See $LOG_FILE"
fi
