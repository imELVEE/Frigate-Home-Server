# Home Assistant

Home Assistant is the main automation service in this stack. Frigate has its own UI, but Home Assistant handles automation, device state, and phone notifications. It consumes Frigate detections and decides when alerts or other actions should happen.

---

## Basics

- **Integrations:**  
  HA dynamically loads integrations (like MQTT, Frigate). Custom components live under `custom_components/`.

- **Automations:**  
  HA reacts to events, entity state changes, and schedules. In this stack, that is how Frigate detections become notifications and other actions.

- **Reverse proxy awareness:**  
  Because HA sits behind nginx in this setup, it needs to understand forwarded client IPs and the correct external/internal URLs.

---

## Files to Know (`ha/homeassistant`)

- `Dockerfile`  
  - Builds from `ghcr.io/home-assistant/home-assistant:stable`
  - Installs the Frigate integration requirements listed in `custom_components/frigate/manifest.json`

- `configuration.yaml`  
  - Sets:
    - `external_url` / `internal_url`
    - `trusted_proxies`
    - `use_x_forwarded_for: true`
    - `ip_ban_enabled: true`
    - `login_attempts_threshold`
    - CORS allowlist
    - MQTT integration enablement (`mqtt:`); broker connection details are configured through the Home Assistant UI and stored in ignored `.storage`
    - Includes helper files: `automations/`, `scripts.yaml`, `scenes.yaml`, `input_boolean.yaml`, `timer.yaml`

- `automations/*.yaml`  
  - Automation files in this repo
  - In this setup, it mainly ties Frigate/MQTT events into Home Assistant notifications and other responses
  - The exact automation rules are user-specific and are not core to the stack architecture

- `custom_components/frigate`  
  - Frigate HA integration (the bundled version in this repo)

- `custom_components/hacs`  
  - HACS (Home Assistant Community Store) for additional integrations

- `tls/ca.crt`  
  - Mosquitto CA trust for MQTT TLS

- `/config` (mapped to `~/ha/homeassistant`)  
  - All HA state: DB, logs, snapshots, bans, etc.

---

## Security Controls

- `trusted_proxies`:  
  Includes loopback, the Docker subnets, and LAN CIDR.  
  Only these networks may set `X-Forwarded-For`, so outside clients cannot send fake forwarded IPs.

- `ip_ban_enabled: true`, `login_attempts_threshold: 3`:  
  After 3 failed logins, HA bans the source IP. This helps slow password guessing.

- CORS allowlist:  
  Only the external URL is permitted; avoids cross-site embedding from random origins.

- HA runs as UID 1000:  
  Avoids root-owned config files and makes permissions management simpler.

---

## MQTT Integration

- **Broker:** Mosquitto on `mosquitto:8883` (TLS with local CA).
- **Connection details:** In the current setup, the broker host, credentials, and CA are stored in Home Assistant's UI-backed MQTT integration entry rather than explicit YAML host/credential fields.
- **TLS:** HA trusts Mosquitto's local CA via `tls/ca.crt` when using 8883.

Frigate publishes events to MQTT; HA subscribes and exposes sensors/binary_sensors for automations. Examples:

- Binary sensor: `binary_sensor.<camera>_person`
- Event entities derived from Frigate topics

---

## Automations

Home Assistant is where this setup's automation files live.

In this stack, that mostly means reacting to Frigate/MQTT events, sending phone notifications, and coordinating other actions. The exact rules, timing, and notification behavior depend on the local setup and are not documented here in depth because they are not needed to understand the stack layout.

---

## Run / Debug Commands

From `~/ha`:

- Shell into HA container:

      ./compose.sh exec homeassistant bash

- Quick HTTP check (from inside container):

      ./compose.sh exec homeassistant curl -s http://127.0.0.1:8123/manifest.json

- Main host-side probe:

      sudo ./scripts/ha_eos_check.sh

That script checks HA `/api/`, WebSocket handshake via nginx, WAF behavior, and more.

---

## Potential problems

- `ip_bans.yaml` can block nginx if 127.0.0.1 or Docker bridge IPs get banned (often from tokenless healthchecks). Clear the ban and keep `ip_ban_enabled` with a low threshold.
- LAN clients using the public DDNS name can hairpin through the router and cause broad IP bans. Prefer the internal URL or split DNS on the LAN.
- `trusted_proxies` must include loopback and the actual Docker bridge subnet (not an overly broad `172.16.0.0/12` and not empty), or client IP handling/Frigate integration breaks.
- Health/API probes must carry a long-lived HA token; unauthenticated curls to `/api` trigger bans.
- Keep `external_url`/`internal_url` in env and ensure compose passes them; stale values cause redirect/login oddities.
- Direct access to port 8123 is plain HTTP LAN fallback and bypasses nginx TLS, WAF, rate limits, and Host checks.
