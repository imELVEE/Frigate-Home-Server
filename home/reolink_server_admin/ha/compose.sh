#!/usr/bin/env bash
# Wrapper to run docker compose with both HA and scripts env vars loaded.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILES=(
  "$HOME_DIR/secrets/ha.env"
  "$HOME_DIR/secrets/scripts.env"
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

cd "$SCRIPT_DIR"

exec docker compose "$@"
