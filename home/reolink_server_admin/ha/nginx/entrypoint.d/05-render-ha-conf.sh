#!/usr/bin/env sh
set -eu

if [ -z "${HA_EXTERNAL_HOST:-}" ]; then
  echo "ERROR: HA_EXTERNAL_HOST not set; cannot render nginx configs" >&2
  exit 1
fi

envsubst '${HA_EXTERNAL_HOST}' < /etc/nginx/conf.d/homeassistant.conf.template > /etc/nginx/conf.d/homeassistant.conf
envsubst '${HA_EXTERNAL_HOST}' < /etc/nginx/conf.d/00-healthz.conf.template > /etc/nginx/conf.d/00-healthz.conf
envsubst '${HA_EXTERNAL_HOST}' < /etc/nginx/conf.d/10-http-redirect.conf.template > /etc/nginx/conf.d/10-http-redirect.conf
