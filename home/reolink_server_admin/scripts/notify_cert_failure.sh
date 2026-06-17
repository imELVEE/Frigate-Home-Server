#!/usr/bin/env bash
set -euo pipefail
COMPONENT="${1:-unknown}"
DETAIL="${2:-no detail provided}"
SUBJECT="Cert renewal failure (${COMPONENT})"
BODY="Cert renewal failure: ${COMPONENT}. Detail: ${DETAIL}."
python3 /home/reolink_server_admin/scripts/notify_email.py "$SUBJECT" "$BODY"
