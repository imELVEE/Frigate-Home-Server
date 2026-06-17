#!/usr/bin/env bash
# Wrapper to run docker compose with both HA and scripts env vars loaded.
set -euo pipefail

ENV_FILES=(
  "/home/reolink_server_admin/secrets/ha.env"
  "/home/reolink_server_admin/secrets/scripts.env"
)

for f in "${ENV_FILES[@]}"; do
  if [[ -f "$f" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  else
    echo "WARN: missing env file $f" >&2
  fi
done

# Run compose from the directory that holds docker-compose.yml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

exec docker compose "$@"
