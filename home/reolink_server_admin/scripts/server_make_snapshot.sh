#!/usr/bin/env bash
set -euo pipefail

# Notify via email on failure
notify_fail() {
  local msg="$1"
  if [[ -x /home/reolink_server_admin/scripts/notify_email.py ]]; then
    /home/reolink_server_admin/scripts/notify_email.py \
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

BASE_HA_DIR="/home/reolink_server_admin/ha"
SCRIPTS_DIR="/home/reolink_server_admin/scripts"
CHANGELOG_FILE="/home/reolink_server_admin/changelog.md"
SNAPSHOT_ROOT="/home/reolink_server_admin/snapshots/server"

MAX_PER_VERSION=3

# Compose services that define "server version".
# Image names are discovered from the running containers so local builds and
# upstream image renames do not break version tracking.
COMPOSE_CMD=( "$BASE_HA_DIR/compose.sh" -f "$BASE_HA_DIR/docker-compose.yml" )
STACK_SERVICES=( homeassistant frigate nginx )

###############################################################################
# Setup
###############################################################################

mkdir -p "$SNAPSHOT_ROOT"
DATE_UTC="$(date -u +"%Y%m%dT%H%M%SZ")"

###############################################################################
# Determine a "server version" from running Compose service images
###############################################################################

service_meta_key() {
  local service="$1"
  case "$service" in
    homeassistant) echo "ha" ;;
    *) echo "$service" ;;
  esac
}

get_service_container_id() {
  local service="$1"
  "${COMPOSE_CMD[@]}" ps -q "$service" 2>/dev/null | head -n 1 || true
}

declare -a STACK_SIG_LINES=()
declare -a STACK_META_LINES=()

for service in "${STACK_SERVICES[@]}"; do
  key="$(service_meta_key "$service")"
  cid="$(get_service_container_id "$service")"

  if [[ -z "$cid" ]]; then
    image_name="missing-container:$service"
    image_id="missing-container:$service"
    cid="missing"
  else
    image_name="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null || true)"
    image_id="$(docker inspect "$cid" --format '{{.Image}}' 2>/dev/null || true)"

    [[ -z "$image_name" ]] && image_name="unknown-image:$service"
    [[ -z "$image_id" ]] && image_id="unknown-image-id:$service"
  fi

  STACK_SIG_LINES+=( "${service}|${image_name}|${image_id}" )
  STACK_META_LINES+=(
    "${key}_service=$service"
    "${key}_container_id=$cid"
    "${key}_image_name=$image_name"
    "${key}_image_id=$image_id"
  )
done

STACK_SIG="$(printf '%s\n' "${STACK_SIG_LINES[@]}" \
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

{
cat <<EOF
date_utc=$DATE_UTC
version=$CURRENT_VERSION
stack_sig=$STACK_SIG
stack_services=${STACK_SERVICES[*]}
EOF
printf '%s\n' "${STACK_META_LINES[@]}"
} > "$SNAPSHOT_DIR/runtime_meta.txt"

###############################################################################
# Create the server config snapshot tarball
###############################################################################

TAR_PATH="$SNAPSHOT_DIR/server-config.tgz"

# We include:
#   /etc                          - system config
#   $BASE_HA_DIR                  - HA stack (configs, acme, nginx, etc.)
#   $SCRIPTS_DIR                  - your admin scripts
#   $CHANGELOG_FILE               - live server change history
#
# We EXCLUDE:
#   frigate/media                 - huge recordings, not needed to rebuild
#   snapshots/                    - avoid recursive inclusion of older backups

tar czf "$TAR_PATH" \
  --ignore-failed-read \
  --exclude="${BASE_HA_DIR}/frigate/media" \
  --exclude="/home/reolink_server_admin/snapshots" \
  /etc \
  "$BASE_HA_DIR" \
  "$SCRIPTS_DIR" \
  "$CHANGELOG_FILE"

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
