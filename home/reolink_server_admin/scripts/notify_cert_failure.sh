#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT="${1:-unknown}"
DETAIL="${2:-no detail provided}"
SUBJECT="Cert renewal failure (${COMPONENT})"
BODY="Cert renewal failure: ${COMPONENT}. Detail: ${DETAIL}."
python3 "$SCRIPT_DIR/notify_email.py" "$SUBJECT" "$BODY"
