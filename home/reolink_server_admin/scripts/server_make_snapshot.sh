#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Notify via email on failure
notify_fail() {
  local msg="$1"
  if [[ -x "$SCRIPT_DIR/notify_email.py" ]]; then
    "$SCRIPT_DIR/notify_email.py" \
      "Snapshot FAILED on $(hostname)" \
      "$msg"
  fi
}
trap 'notify_fail "server_make_snapshot.sh failed; see logs in snapshots/server"' ERR

# If not running as root, re-exec via sudo so we can read /etc and protected files.
# Set ALLOW_NON_ROOT_SNAPSHOT=1 to skip sudo (will still attempt, but may miss
# unreadable files); intended for automated contexts without a tty.
if [[ $EUID -ne 0 && -z "${ALLOW_NON_ROOT_SNAPSHOT:-}" ]]; then
  echo "Re-running with sudo for full /etc + ha backup..."
  exec sudo "$0" "$@"
fi

###############################################################################
# Config
###############################################################################

BASE_HA_DIR="$HOME_DIR/ha"
SCRIPTS_DIR="$SCRIPT_DIR"
SNAPSHOT_ROOT="$HOME_DIR/snapshots/server"

MAX_PER_VERSION=3

# Containers that define "server version".
# Adjust these names to match your actual images if needed.
HA_IMAGE_NAME="homeassistant"
FRIGATE_IMAGE_NAME="blakeblackshear/frigate"
NGINX_IMAGE_NAME="nginx"

###############################################################################
# Setup
###############################################################################

mkdir -p "$SNAPSHOT_ROOT"
DATE_UTC="$(date -u +"%Y%m%dT%H%M%SZ")"

###############################################################################
# Determine a "server version" from container images
###############################################################################

get_image_id() {
  local image="$1"
  docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "missing:$image"
}

HA_IMG_ID="$(get_image_id "$HA_IMAGE_NAME")"
FRIGATE_IMG_ID="$(get_image_id "$FRIGATE_IMAGE_NAME")"
NGINX_IMG_ID="$(get_image_id "$NGINX_IMAGE_NAME")"

STACK_SIG="$(printf '%s\n%s\n%s\n' "$HA_IMG_ID" "$FRIGATE_IMG_ID" "$NGINX_IMG_ID" \
  | sha256sum | awk '{print $1}')"

VERSION_META_FILE="$SNAPSHOT_ROOT/.server_version"

CURRENT_VERSION=""
CURRENT_SIG=""

if [[ -f "$VERSION_META_FILE" ]]; then
  # file format: "<version> <sig>"
  read -r CURRENT_VERSION CURRENT_SIG < "$VERSION_META_FILE" || true
fi

if [[ -z "${CURRENT_VERSION:-}" ]] || [[ "$CURRENT_SIG" != "$STACK_SIG" ]]; then
  # Stack changed or no version yet → bump version
  if [[ -z "${CURRENT_VERSION:-}" ]]; then
    NEW_VERSION=1
  else
    NEW_VERSION=$(( CURRENT_VERSION + 1 ))
  fi
  CURRENT_VERSION="$NEW_VERSION"
  echo "$CURRENT_VERSION $STACK_SIG" > "$VERSION_META_FILE"
fi

if [[ -z "${CURRENT_VERSION:-}" ]]; then
  # Failsafe
  CURRENT_VERSION=1
  echo "$CURRENT_VERSION $STACK_SIG" > "$VERSION_META_FILE"
fi

VERSION_DIR="$SNAPSHOT_ROOT/v${CURRENT_VERSION}"
SNAPSHOT_DIR="$VERSION_DIR/SNAPSHOT_${DATE_UTC}"

mkdir -p "$SNAPSHOT_DIR"

###############################################################################
# Capture metadata (packages, docker info, etc.)
###############################################################################

# Package list (Debian/Ubuntu style)
if command -v dpkg >/dev/null 2>&1; then
  dpkg --get-selections > "$SNAPSHOT_DIR/dpkg_selections.txt" || true
fi

# Docker info
if command -v docker >/dev/null 2>&1; then
  docker ps -a > "$SNAPSHOT_DIR/docker_ps.txt" || true
  docker image ls > "$SNAPSHOT_DIR/docker_images.txt" || true
fi

cat > "$SNAPSHOT_DIR/runtime_meta.txt" <<EOF
date_utc=$DATE_UTC
version=$CURRENT_VERSION
stack_sig=$STACK_SIG
ha_image_name=$HA_IMAGE_NAME
ha_image_id=$HA_IMG_ID
frigate_image_name=$FRIGATE_IMAGE_NAME
frigate_image_id=$FRIGATE_IMG_ID
nginx_image_name=$NGINX_IMAGE_NAME
nginx_image_id=$NGINX_IMG_ID
EOF

###############################################################################
# Create the server config snapshot tarball
###############################################################################

TAR_PATH="$SNAPSHOT_DIR/server-config.tgz"

# We include:
#   /etc                          - system config
#   $BASE_HA_DIR                  - HA stack (configs, acme, nginx, etc.)
#   $SCRIPTS_DIR                  - your admin scripts
#
# We EXCLUDE:
#   frigate/media                 - huge recordings, not needed to rebuild
#   snapshots/                    - avoid recursive inclusion of older backups

tar czf "$TAR_PATH" \
  --ignore-failed-read \
  --exclude="${BASE_HA_DIR}/frigate/media" \
  --exclude="$HOME_DIR/snapshots" \
  /etc \
  "$BASE_HA_DIR" \
  "$SCRIPTS_DIR"

###############################################################################
# Rotate old snapshots within this version (keep MAX_PER_VERSION most recent)
###############################################################################

shopt -s nullglob
SNAP_DIRS=( "$VERSION_DIR"/SNAPSHOT_* )
shopt -u nullglob

NUM_SNAPS="${#SNAP_DIRS[@]}"

if (( NUM_SNAPS > MAX_PER_VERSION )); then
  TO_DELETE=$(( NUM_SNAPS - MAX_PER_VERSION ))

  # Sort lexicographically → oldest first (because timestamp is in name)
  mapfile -t SORTED_SNAPS < <(printf '%s\n' "${SNAP_DIRS[@]}" | sort)

  for (( i=0; i<TO_DELETE; i++ )); do
    OLD="${SORTED_SNAPS[i]}"
    echo "Deleting old snapshot: $OLD"
    rm -rf --one-file-system -- "$OLD"
  done
fi

echo "Server snapshot complete: $SNAPSHOT_DIR"
