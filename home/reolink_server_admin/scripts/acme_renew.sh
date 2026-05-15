#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HA_DIR="$HOME_DIR/ha"

# Renew any due ACME certs using the tracked acme.sh home and Dynu DNS credentials.
/usr/bin/docker run --rm --env-file /etc/acme/dynu.env \
  -v "$HA_DIR/acme:/acme.sh" \
  -v "$HA_DIR/nginx/ssl:/deploy" \
  neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh --cron --server letsencrypt' \
  || {
    "$SCRIPT_DIR/notify_cert_failure.sh" "ACME" "Primary domain via acme.sh renew failed"
    exit 1
  }
