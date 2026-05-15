# Environment Files

This stack primarily uses three live env files:

- `~/secrets/ha.env`
- `~/secrets/scripts.env`
- `/etc/acme/dynu.env`

The repo tracks three matching example env files:

- `secrets/ha.env.example` -> `~/secrets/ha.env`
- `secrets/scripts.env.example` -> `~/secrets/scripts.env`
- `etc/acme/dynu.env.example` -> `/etc/acme/dynu.env`

All three `*.example` files are examples only. The live files above are what the stack reads.

---

## What Each File Affects

### `~/secrets/ha.env`

This is the runtime env file for the Docker stack.

It affects:

- `~/ha/compose.sh`
  - sources the file before every `docker compose` command
- `~/ha/docker-compose.yml`
  - uses values like `EXTERNAL_URL`, `MQTT_USER`, `MQTT_PASSWORD`, and `HA_EXTERNAL_HOST` for Compose substitution
  - passes selected values into containers through `environment:`
- `~/ha/homeassistant/configuration.yaml`
  - uses `!env_var` for `EXTERNAL_URL`, `INTERNAL_URL`, and `LAN_SUBNET`
- Home Assistant automations
  - use `!env_var` for `EXTERNAL_URL`, `MY_PHONE`, and `SOMEONE_ELSE_PHONE`
- `~/ha/frigate/config/config.yml`
  - uses placeholders like `"{FRIGATE_MQTT_USER}"`; Compose feeds those from `MQTT_USER` / `MQTT_PASSWORD` and the RTSP vars
- `~/ha/nginx/entrypoint.d/05-render-ha-conf.sh`
  - uses `HA_EXTERNAL_HOST` with `envsubst` to render nginx configs
- host scripts that source `ha.env`
  - `~/scripts/renew_mosquitto_tls.sh`
  - `~/scripts/ha_eos_check.sh`
  - `~/scripts/container_healthcheck.sh`

Common values in this file:

- hostnames and URLs
- LAN subnet / LAN IP
- MQTT username and password
- Frigate RTSP credentials
- mobile notify service names

Matching example file:

- `secrets/ha.env.example`

### `~/secrets/scripts.env`

This is the host-side API / email / helper-script env file.

It affects:

- `~/ha/compose.sh`
  - sources the file before every `docker compose` command
- `~/scripts/ha_eos_check.sh`
- `~/scripts/container_healthcheck.sh`
- `~/scripts/notify_email.py`
- host scripts that call `notify_email.py`, such as `notify_cert_failure.sh`, `server_healthcheck.sh`, `modsec_alert.py`, `disk_healthcheck.sh`, `lynis_audit.sh`, `server_make_snapshot.sh`, and `trivy_scan.sh`

In the current `~/ha/docker-compose.yml`, none of the current `scripts.env` keys (`HA_TOKEN`, `EMAIL_*`) are forwarded into container `environment:` blocks.

Common values in this file:

- `HA_TOKEN`
- SMTP server, port, username, password
- email sender / recipient values

Matching example file:

- `secrets/scripts.env.example`

### `/etc/acme/dynu.env`

This is the ACME / Dynu DNS env file.

It affects:

- the manual `acme.sh` issue/install commands
- `etc/systemd/system/acme-renew.service`
  - loads it with `EnvironmentFile=/etc/acme/dynu.env`
- `~/scripts/acme_renew.sh`
  - passes it to dockerized `acme.sh` with `--env-file /etc/acme/dynu.env`

Values in here:

- `Dynu_ClientId`
- `Dynu_Secret`

Matching example file:

- `etc/acme/dynu.env.example`

---

## How They Load

`~/ha/compose.sh` is the wrapper for stack commands. It:

- sources `~/secrets/ha.env`
- sources `~/secrets/scripts.env`
- exports both with `set -a`
- changes into `~/ha/`
- runs `docker compose`

That means:

- Compose variable substitution works consistently
- the same env values are available every time you run stack commands
- you do not have to manually export vars in your shell first

But a value being available to Compose does not automatically mean it exists inside a container. It only reaches a container if `~/ha/docker-compose.yml` passes it through under `environment:`.

In this stack:

- Compose uses env vars for YAML substitution
- Home Assistant reads env with `!env_var`
- Frigate uses quoted format-style placeholders like `"{VAR}"`
- nginx templates are rendered with `envsubst`
- ACME does not use `compose.sh`; it reads `/etc/acme/dynu.env` separately through systemd and `docker run --env-file`
