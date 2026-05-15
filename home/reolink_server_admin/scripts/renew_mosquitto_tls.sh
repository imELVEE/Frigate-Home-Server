#!/usr/bin/env bash
# Regenerate Mosquitto TLS server cert (signed by local CA) and restart broker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HA_DIR="$HOME_DIR/ha"
SECRETS_DIR="$HOME_DIR/secrets"

# Load shared env if available (for HA_LAN_IP)
ENV_FILE="$SECRETS_DIR/ha.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

CONFIG_DIR="$HA_DIR/mosquitto/config"
TLS_DIR="$CONFIG_DIR/tls"
SECURE_CA_DIR="$HA_DIR/mosquitto/ca_secure"
HOST_IP="${HA_LAN_IP:-}"
HOST_DOMAIN="${HA_EXTERNAL_HOST:-}"
if [[ -z "$HOST_IP" || -z "$HOST_DOMAIN" ]]; then
  echo "Set HA_LAN_IP and HA_EXTERNAL_HOST in $SECRETS_DIR/ha.env before running." >&2
  exit 1
fi
CA_KEY="$SECURE_CA_DIR/ca.key"
CA_SRL="$SECURE_CA_DIR/ca.srl"
CA_CRT="$TLS_DIR/ca.crt"  # keep CA cert next to server cert for clients
SERVER_KEY="$TLS_DIR/server.key"
SERVER_CSR="$TLS_DIR/server.csr"
SERVER_CRT="$TLS_DIR/server.crt"
EXTFILE="$TLS_DIR/server.ext"

mkdir -p "$TLS_DIR" "$SECURE_CA_DIR"

# Create CA if missing (long-lived). Keep CA key outside the container mount.
if [[ ! -f "$CA_KEY" || ! -f "$CA_CRT" ]]; then
  openssl genrsa -out "$CA_KEY" 4096
  openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 3650 \
    -subj "/CN=mosquitto-ca" -out "$CA_CRT"
fi
chmod 600 "$CA_KEY" "$CA_SRL" 2>/dev/null || true
chown root:root "$CA_KEY" "$CA_SRL" 2>/dev/null || true

# SANs for broker; add your LAN hostname/IPs if clients verify them
cat > "$EXTFILE" <<EOF_EXT
subjectAltName=DNS:mosquitto,DNS:localhost,DNS:${HOST_DOMAIN},IP:127.0.0.1,IP:${HOST_IP}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF_EXT

# Issue fresh server cert (120 days)
openssl genrsa -out "$SERVER_KEY" 2048
openssl req -new -key "$SERVER_KEY" -subj "/CN=mosquitto" -out "$SERVER_CSR"
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$SERVER_CRT" -days 120 -sha256 -extfile "$EXTFILE"
rm -f "$SERVER_CSR"

# Permissions: broker sees only certs; CA key stays root-only outside mount
chown 1883:1883 "$SERVER_KEY" "$SERVER_CRT" "$CA_CRT" "$EXTFILE"
chmod 640 "$SERVER_KEY" "$SERVER_CRT" "$CA_CRT" "$EXTFILE"

# Restart broker to pick up new cert
cd "$HA_DIR"
"$HA_DIR/compose.sh" restart mosquitto
