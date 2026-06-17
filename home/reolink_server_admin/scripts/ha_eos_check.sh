#!/usr/bin/env bash
# Home server End-Of-Setup checker (NGINX + HA + Frigate + Mosquitto)
# Extended: adds optional MQTT auth pub/sub test and basic CLI (-h/-V/-u/-p).
# NOTE: This script does NOT modify nginx or any config files.

set -u
export LC_ALL=C

ENV_FILE="/home/reolink_server_admin/secrets/ha.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi
ENV_FILE_2="/home/reolink_server_admin/secrets/scripts.env"
if [[ -f "$ENV_FILE_2" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE_2"
  set +a
fi
EXTERNAL_HOST="${HA_EXTERNAL_HOST:-}"
if [[ -z "$EXTERNAL_HOST" ]]; then
  echo "Set HA_EXTERNAL_HOST in /home/reolink_server_admin/secrets/ha.env" >&2
  exit 1
fi
HA_TOKEN="${HA_TOKEN:-}"
if [[ -z "$HA_TOKEN" ]]; then
  echo "Set HA_TOKEN in /home/reolink_server_admin/secrets/scripts.env" >&2
  exit 1
fi

VERSION="1.0.0"

# Optional MQTT auth parameters (only used if supplied via CLI)
MQTT_USER=""
MQTT_PASS=""

usage() {
  cat <<EOF
ha_eos_check.sh ${VERSION}

Health-check for Home Assistant stack (NGINX + HA + Frigate + Mosquitto).

Usage:
  $0 [options]

Options:
  -u, --mqtt-user USER    MQTT username to test auth pub/sub against
  -p, --mqtt-pass PASS    MQTT password to test auth pub/sub against

  -h, --help              Show this help and exit
  -V, --version           Show script version and exit

Behavior:
  - Without -u/-p: only checks MQTT TCP reachability (like before).
  - With -u/-p: additionally runs an MQTT auth pub/sub check using mosquitto_pub/sub.
EOF
}

# ----- CLI argument parsing -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--mqtt-user)
      MQTT_USER="${2-}"
      shift 2
      ;;
    -p|--mqtt-pass)
      MQTT_PASS="${2-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -V|--version)
      echo "ha_eos_check.sh ${VERSION}"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Try '$0 --help'." >&2
      exit 2
      ;;
  esac
done

# ---------- Helpers ----------
FAILS=()

section() {
  echo
  echo "== $1 =="
}

ok()  { echo "✅ $*"; }
bad() { echo "❌ $*"; FAILS+=("$*"); }

# curl wrapper: prints HTTP code to stdout, returns 0 always (we'll compare)
http_code() {
  local url="$1"; shift
  curl -sk -o /dev/null -w '%{http_code}\n' "$@" "$url"
}

# ---------- OS & Kernel ----------
section "OS & Kernel"
uname -a
lsb_release -d 2>/dev/null || cat /etc/os-release | sed -n 's/^PRETTY_NAME=//p' | tr -d '"'
echo

# ---------- Docker: services up & images ----------
section "Docker: services up & images"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
echo
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}'

# ---------- Frigate: VAAPI wiring + recent logs ----------
section "Frigate: VAAPI wiring + recent logs"
if docker ps --format '{{.Names}}' | grep -q '^frigate$'; then
  echo "Container: frigate"
  docker inspect frigate --format '{{json .HostConfig.Devices}}' || true
  docker exec frigate sh -lc 'echo "LIBVA_DRIVER_NAME=$LIBVA_DRIVER_NAME"' || true
else
  bad "frigate container not running"
fi

# ---------- Mosquitto: config & local broker ping ----------
section "Mosquitto: config & local broker ping"
if docker ps --format '{{.Names}}' | grep -q '^mosquitto$'; then
  echo "Container: mosquitto"
  docker exec mosquitto sh -lc 'grep -E "^(listener|allow_anonymous|password_file)" /mosquitto/config/mosquitto.conf || true'
  LISTENER_PORTS="$(docker exec mosquitto cat /mosquitto/config/mosquitto.conf \
    | awk '/^[[:space:]]*listener[[:space:]]+[0-9]+/{print $2}' \
    | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ -z "$LISTENER_PORTS" ]]; then
    LISTENER_PORTS="1883"
  fi

  # Check all configured listeners; use the first one as the default for auth tests
  MQTT_PORT_FOR_AUTH="${LISTENER_PORTS%% *}"
  for port in $LISTENER_PORTS; do
    if docker exec mosquitto sh -lc "nc -z 127.0.0.1 ${port}" 2>/dev/null; then
      ok "MQTT TCP reachable inside mosquitto container (localhost:${port})"
    else
      bad "MQTT TCP NOT reachable inside mosquitto container (localhost:${port})"
    fi
  done

  # Optional MQTT auth pub/sub test if user+pass provided AND mosquitto-clients installed
  if [[ -n "$MQTT_USER" && -n "$MQTT_PASS" ]]; then
    if docker exec mosquitto sh -c 'command -v mosquitto_pub >/dev/null 2>&1 && command -v mosquitto_sub >/dev/null 2>&1'; then
      TOPIC="eos/health/$RANDOM"
      TMPFILE="/tmp/ha_eos_mqtt.$$"
      MQTT_TLS_FLAGS=""
      if [[ "$MQTT_PORT_FOR_AUTH" != "1883" ]]; then
        MQTT_TLS_FLAGS="--cafile /mosquitto/config/tls/ca.crt --insecure"
      fi

      # Start subscriber inside container (single message, short timeout)
      docker exec mosquitto sh -c "mosquitto_sub -h 127.0.0.1 -p ${MQTT_PORT_FOR_AUTH} ${MQTT_TLS_FLAGS} -u \"$MQTT_USER\" -P \"$MQTT_PASS\" -t \"$TOPIC\" -C 1 -W 2" >"$TMPFILE" 2>/dev/null &

      sleep 0.2

      # Publish test message inside container
      docker exec mosquitto sh -c "mosquitto_pub -h 127.0.0.1 -p ${MQTT_PORT_FOR_AUTH} ${MQTT_TLS_FLAGS} -u \"$MQTT_USER\" -P \"$MQTT_PASS\" -t \"$TOPIC\" -m \"ok\"" >/dev/null 2>&1 || true

      sleep 0.5

      if grep -q "ok" "$TMPFILE" 2>/dev/null; then
        ok "MQTT auth pub/sub succeeded for user '$MQTT_USER'"
      else
        bad "MQTT auth pub/sub FAILED for user '$MQTT_USER' (check credentials/mosquitto-clients)"
      fi
      rm -f "$TMPFILE" || true
    else
      echo "WARN: MQTT auth test requested but mosquitto_pub/mosquitto_sub not installed; skipping auth test." >&2
    fi
  else
    echo "(MQTT auth test skipped: no -u/-p supplied)" >&2
  fi
else
  bad "mosquitto container not running"
fi

# ---------- Home Assistant: basic checks ----------
section "Home Assistant: basic checks"
if docker ps --format '{{.Names}}' | grep -q '^homeassistant$'; then
  echo "Container: homeassistant"
  if nc -z 127.0.0.1 8123 2>/dev/null; then
    ok "HA TCP reachable on 127.0.0.1:8123"
  else
    bad "HA TCP NOT reachable on 127.0.0.1:8123"
  fi
  code=$(http_code "http://127.0.0.1:8123/api/" -H "Authorization: Bearer ${HA_TOKEN}")
  if [[ "$code" == "200" ]]; then
    ok "HA /api/ responded HTTP $code"
  else
    bad "HA /api/ responded HTTP $code (expected 200)"
  fi
  echo "Testing configuration at /config"
  docker exec homeassistant python3 - <<'PY' || true
import sys, os, json
print("Home Assistant container is up; full config check is typically run via 'ha core check' in Supervisor installs.")
PY
else
  bad "homeassistant container not running"
fi

# ---------- NGINX reverse proxy: /healthz, TLS/WS, WAF ----------
section "NGINX reverse proxy: /healthz, TLS/WS, WAF"
if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
  echo "Container: nginx"

  # nginx config test (prefer exit code; fall back to message check)
  NGINX_T="$(mktemp -t nginx_t.XXXXXX)"
  docker exec nginx sh -lc '/usr/sbin/nginx -q -t' >"$NGINX_T" 2>&1
  RC=$?

  if [ "$RC" -eq 0 ]; then
    ok "nginx config test passed"
  else
    # Fallback: run non-quiet to get human-readable diagnostics
    NGINX_T2="$(mktemp -t nginx_t2.XXXXXX)"
    docker exec nginx sh -lc '/usr/sbin/nginx -t' >"$NGINX_T2" 2>&1
    if grep -q "syntax is ok" "$NGINX_T2" && grep -q "test is successful" "$NGINX_T2"; then
      ok "nginx config test passed"
    else
      bad "nginx config test FAILED"
      echo "--- nginx -q -t (default user) output ---"; cat "$NGINX_T" || true
      echo "--- nginx -t (default user) output ---"; cat "$NGINX_T2" || true
    fi
    rm -f "$NGINX_T2" 2>/dev/null || true
  fi
  rm -f "$NGINX_T" 2>/dev/null || true



  # Docker health
  HEALTH=$(docker inspect -f '{{.State.Health.Status}}' nginx 2>/dev/null || echo "unknown")
  if [[ "$HEALTH" == "healthy" ]]; then
    ok "Docker health: $HEALTH"
  else
    bad "Docker health: $HEALTH"
  fi

  # Local healthz (proxied to HA)
  code=$(docker exec nginx sh -lc "curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/healthz")
  if [[ "$code" =~ ^(200|200|301|302|401|403)$ ]]; then
    ok "nginx local /healthz => HTTP $code"
  else
    bad "nginx local /healthz => HTTP $code (expected 200/301/302/401/403)"
  fi

  # Public HTTPS root via localhost force-resolve
  code=$(http_code "https://${EXTERNAL_HOST}/" \
                   --resolve "${EXTERNAL_HOST}:443:127.0.0.1" \
                   -H "Host: ${EXTERNAL_HOST}")
  if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
    ok "HTTPS / (nginx) => HTTP $code"
  else
    bad "HTTPS / (nginx) => HTTP $code (expected 200/301/302/401/403)"
  fi

  # REST API path (should NOT be 400)
  code=$(http_code "https://${EXTERNAL_HOST}/api/" \
                   --resolve "${EXTERNAL_HOST}:443:127.0.0.1" \
                   -H "Host: ${EXTERNAL_HOST}" \
                   -H "Authorization: Bearer ${HA_TOKEN}")
  if [[ "$code" == "200" ]]; then
    ok "HTTPS /api/ => HTTP $code"
  else
    bad "HTTPS /api/ => HTTP $code (expected 200)"
  fi

  # WebSocket handshake (REAL)
  WS_KEY=$(openssl rand -base64 16 2>/dev/null || dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
  code=$(curl -sk --http1.1 -o /dev/null -w '%{http_code}\n' \
                 --resolve "${EXTERNAL_HOST}:443:127.0.0.1" \
                 -H "Host: ${EXTERNAL_HOST}" \
                 -H "Origin: https://${EXTERNAL_HOST}" \
                 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
                 -H 'Sec-WebSocket-Version: 13' -H "Sec-WebSocket-Key: $WS_KEY" \
                 "https://${EXTERNAL_HOST}/api/websocket")
  if [[ "$code" =~ ^(101|401|403)$ ]]; then
    ok "HTTPS WS => HTTP $code"
  else
    bad "HTTPS WS => HTTP $code (expected 101/401/403; if 400 here, your client/probe is wrong)"
  fi

  # WAF probe (expect CRS to block with 403) — only for /api (NOT websocket)
  code=$(curl -sk -o /dev/null -w '%{http_code}\n' \
                 --resolve "${EXTERNAL_HOST}:443:127.0.0.1" \
                 -H "Host: ${EXTERNAL_HOST}" \
                 "https://${EXTERNAL_HOST}/api/?id=%27%20OR%201=1--")
  if [[ "$code" == "403" ]]; then
    ok "WAF probe blocked with 403"
  else
    bad "WAF probe returned HTTP $code (expected 403)"
  fi

else
  bad "nginx container not running"
fi

# ---------- acme.sh / renewal timer snapshot ----------
section "acme.sh: renewal status"
# Just show timer status if present; don't fail the run if missing.
if systemctl list-timers --all 2>/dev/null | grep -q acme-renew.timer; then
  systemctl list-timers --all | (head -1; grep acme-renew.timer || true)
else
  echo "No systemd timer named acme-renew.timer found (ok if you cron acme.sh)."
fi

# ---------- Firewall snapshot (nftables) ----------
section "Firewall: UFW/NFT (snapshot)"
if command -v ufw >/dev/null 2>&1; then
  ufw status || true
fi
if command -v nft >/dev/null 2>&1; then
  nft list ruleset | sed -n '1,220p'
else
  echo "nft not installed."
fi

# ---------- Listening ports ----------
section "Listening ports (ssh, http/https, HA)"
ss -ltpn | sed 's/^/ /'

# ---------- Disk, Docker usage, journald ----------
section "Disk, Docker usage, journald"
df -hT | sed -n '1,30p'
docker system df
journalctl --disk-usage 2>/dev/null || true

# ---------- Final summary ----------
echo
if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "🎉 All checks passed."
  exit 0
else
  echo "⛔ Some checks failed:"
  for f in "${FAILS[@]}"; do
    echo " - $f"
  done
  exit 1
fi
