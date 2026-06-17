#!/usr/bin/env bash
set -euo pipefail

# Run as root so ha_eos_check.sh can do everything it wants
if [[ $EUID -ne 0 ]]; then
  echo "Re-running server_healthcheck.sh with sudo..."
  exec sudo "$0" "$@"
fi

HOSTNAME="$(hostname)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

HEALTH_DIR="/home/reolink_server_admin/snapshots/health"
SECRETS_ENV="/home/reolink_server_admin/secrets/ha.env"
mkdir -p "$HEALTH_DIR"

if [[ -f "$SECRETS_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_ENV"
  set +a
fi

PRUNE_DAYS=7
# Prune old health logs to keep the directory small
find "$HEALTH_DIR" -type f -name 'ha_eos_*.log' -mtime +"$PRUNE_DAYS" -delete 2>/dev/null || true

LOG_FILE="${HEALTH_DIR}/ha_eos_${STAMP}.log"
LATEST_LOG="${HEALTH_DIR}/health_latest.log"

# Run the full EOS checker from the ha stack directory
cd /home/reolink_server_admin/ha

# Default exit code
rc=0
/home/reolink_server_admin/scripts/ha_eos_check.sh >"$LOG_FILE" 2>&1 || rc=$?

# Keep a "latest" symlink/copy for quick viewing
cp -a "$LOG_FILE" "$LATEST_LOG"

if [[ $rc -eq 0 ]]; then
  msg="OK: ${HOSTNAME} ha_eos_check.sh passed at ${STAMP}"
  echo "$msg"
  exit 0
fi

# Build a short summary for notifications
SUMMARY="CRITICAL: ${HOSTNAME} ha_eos_check.sh FAILED at ${STAMP} (exit=${rc}). Log: ${LOG_FILE}"
echo "$SUMMARY"

# Email alert on failure
if [[ -x /home/reolink_server_admin/scripts/notify_email.py ]]; then
  /home/reolink_server_admin/scripts/notify_email.py \
    "Healthcheck FAILED on ${HOSTNAME}" \
    "${SUMMARY}"
fi

# Try to publish MQTT alert so Home Assistant can notify you (inside mosquitto container)
if command -v docker >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -q '^mosquitto$'; then
    MQTT_PORT=$(docker exec mosquitto sh -lc "awk '/^[[:space:]]*listener[[:space:]]+[0-9]+/{print \$2; exit}' /mosquitto/config/mosquitto.conf" 2>/dev/null | tr -d '\r' || true)
    [[ -z "$MQTT_PORT" ]] && MQTT_PORT=1883
    MQTT_TLS_FLAGS=""
    if [[ "$MQTT_PORT" != "1883" ]]; then
      MQTT_TLS_FLAGS="--cafile /mosquitto/config/tls/ca.crt --insecure"
    fi

    if [[ -z "${MQTT_USER:-}" || -z "${MQTT_PASSWORD:-}" ]]; then
      echo "WARN: MQTT credentials missing; skipping MQTT health notification" >&2
    else
      /home/reolink_server_admin/ha/compose.sh \
        -f /home/reolink_server_admin/ha/docker-compose.yml exec -T \
        -e MQTT_USER="$MQTT_USER" \
        -e MQTT_PASSWORD="$MQTT_PASSWORD" \
        -e MQTT_PORT="$MQTT_PORT" \
        -e MQTT_TLS_FLAGS="$MQTT_TLS_FLAGS" \
        -e MQTT_TOPIC="server/${HOSTNAME}/health" \
        -e MQTT_MESSAGE="$SUMMARY" \
        mosquitto sh -c '
          # shellcheck disable=SC2086
          mosquitto_pub -h 127.0.0.1 -p "$MQTT_PORT" $MQTT_TLS_FLAGS \
            -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
            -t "$MQTT_TOPIC" -m "$MQTT_MESSAGE"
        ' || echo "WARN: mosquitto_pub inside container failed" >&2
    fi
  else
    echo "WARN: mosquitto container not running; skipping MQTT health notification" >&2
  fi
else
  echo "WARN: docker not available; skipping MQTT health notification" >&2
fi

exit "$rc"
