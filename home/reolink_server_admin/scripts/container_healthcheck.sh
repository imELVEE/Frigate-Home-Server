#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HA_DIR="$HOME_DIR/ha"
SECRETS_DIR="$HOME_DIR/secrets"

# Check container state/health via docker compose, send email on failures.
# Requires HA_TOKEN in secrets to avoid HA banning localhost on /api/ probes.
ENV_FILES=(
  "$SECRETS_DIR/ha.env"
  "$SECRETS_DIR/scripts.env"
)
for f in "${ENV_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
done

HA_TOKEN="${HA_TOKEN:-}"

COMPOSE_FILE="$HA_DIR/docker-compose.yml"
COMPOSE_CMD=("$HA_DIR/compose.sh" -f "$COMPOSE_FILE")

services=(nginx homeassistant mosquitto frigate)

issues=()
for svc in "${services[@]}"; do
  state=$("${COMPOSE_CMD[@]}" ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null | awk -v s="$svc" '$1==s{print $2, $3}')
  if [[ -z "$state" ]]; then
    issues+=("${svc}: not found or stopped")
    continue
  fi
  set -- $state
  st=$1; hlth=${2:-}
  if [[ "$st" != "running" ]]; then
    issues+=("${svc}: state=$st")
    continue
  fi
  if [[ -n "$hlth" && "$hlth" != "healthy" ]]; then
    issues+=("${svc}: health=$hlth")
  fi
  
  # Basic HTTP check for nginx and HA
  if [[ "$svc" == "nginx" ]]; then
    code=$("${COMPOSE_CMD[@]}" exec nginx sh -c "curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/healthz" || echo 000)
    [[ "$code" != "200" && "$code" != "401" && "$code" != "403" ]] && issues+=("nginx healthz http $code")
  elif [[ "$svc" == "homeassistant" ]]; then
    # Use an unauthenticated, lightweight endpoint to avoid bans if token is bad.
    code=$("${COMPOSE_CMD[@]}" exec homeassistant sh -c "curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:8123/manifest.json" || echo 000)
    [[ "$code" != "200" ]] && issues+=("homeassistant manifest http $code")

    # Optional: if token provided, check /api but only warn on auth issues.
    if [[ -n "$HA_TOKEN" ]]; then
      api_code=$("${COMPOSE_CMD[@]}" exec homeassistant sh -c "curl -sk -o /dev/null -w '%{http_code}' -H \"Authorization: Bearer ${HA_TOKEN}\" http://127.0.0.1:8123/api/" || echo 000)
      [[ "$api_code" != "200" ]] && issues+=("homeassistant api http $api_code")
    fi
  fi

done

if (( ${#issues[@]} == 0 )); then
  echo "$(date -u) OK: containers healthy"
  exit 0
fi

msg=$(printf '%s; ' "${issues[@]}")
if [[ -x "$SCRIPT_DIR/notify_email.py" ]]; then
  "$SCRIPT_DIR/notify_email.py" \
    "Container health alert on $(hostname)" \
    "Issues: ${msg}"
fi

echo "$(date -u) ALERT: ${msg}" >&2
exit 1
