# Scripts

`~/scripts/` holds the host-side scripts for this stack: health checks, notifications, TLS rotation, and snapshots. Some are run manually, some are called by systemd or cron, and some are triggered indirectly by log rotation.

---

## Key Locations

- **Code:** `~/scripts/`
- **Logs:** `~/logs/`
- **Health snapshots:** `~/snapshots/health/`
- **Server snapshots:** `~/snapshots/server/`
- **Secrets:** most runtime values come from `~/secrets/ha.env` and `~/secrets/scripts.env`; ACME renewal uses `/etc/acme/dynu.env`

---

## What Each Script Does

### `trivy_scan.sh` and `lynis_audit.sh`

- `trivy_scan.sh` scans the currently running container images for HIGH/CRITICAL vulnerabilities and emails only when findings are present.
- `lynis_audit.sh` runs a host audit, writes a log and report into `~/logs/`, and emails a summary of warning and suggestion counts.
- The schedules are `/etc/cron.weekly/trivy-scan` and `/etc/cron.weekly/lynis-audit`.

---

### `ha_eos_check.sh`

- Full check used both for initial validation and recurring runs.
- Checks Docker container state, nginx config and `/healthz`, public HTTPS and API paths, WebSocket behavior, WAF behavior, MQTT reachability, firewall state, listening ports, disk usage, Docker disk usage, and journald size.
- Requires `HA_EXTERNAL_HOST` from `ha.env` and `HA_TOKEN` from `scripts.env`.
- Optional `-u` / `-p` flags add an MQTT auth pub/sub test from inside the Mosquitto container.

---

### `container_healthcheck.sh`

- Lighter recurring health check for the Compose stack.
- Verifies `nginx`, `homeassistant`, `mosquitto`, and `frigate` are running and healthy.
- Probes nginx `/healthz`, Home Assistant `manifest.json`, and optionally the HA `/api/` endpoint when `HA_TOKEN` is set.
- Emails on failure.
- `/etc/cron.d/container-healthcheck` runs every 10 minutes.

---

### `server_healthcheck.sh`

- systemd-oriented wrapper around `ha_eos_check.sh`.
- Re-runs itself with `sudo` when needed, writes timestamped logs into `~/snapshots/health/`, and refreshes `health_latest.log`.
- On failure, sends an email and publishes an authenticated MQTT alert to `server/<hostname>/health` from inside the Mosquitto container, using `MQTT_USER` / `MQTT_PASSWORD` from `~/secrets/ha.env`.
- `server-healthcheck.timer` runs every 30 minutes.

---

### `disk_healthcheck.sh`

- Checks filesystem usage with warning and critical thresholds at 85% and 90%.
- Writes to `~/logs/disk_healthcheck.log` and emails on threshold breaches.
- `/etc/cron.d/disk-healthcheck` runs every 4 hours.

---

### `server_make_snapshot.sh`

- Creates versioned config snapshots containing `/etc`, `~/ha`, `~/scripts`, optional `~/changelog.md`, plus package and Docker metadata.
- Derives the server version from the running Compose service image names and image IDs for Home Assistant, Frigate, and nginx.
- Excludes `~/ha/frigate/media` and prior `~/snapshots/` so the archive stays focused on rebuild state rather than recordings or recursive backups.
- Rotates to the newest three snapshots per detected stack version.
- By default it re-runs with `sudo`; `ALLOW_NON_ROOT_SNAPSHOT=1` skips that and tolerates unreadable files.

---

### `renew_mosquitto_tls.sh`

- Creates the local Mosquitto CA if it does not already exist.
- Issues a fresh server certificate with SANs for `mosquitto`, `localhost`, `HA_EXTERNAL_HOST`, and `HA_LAN_IP`.
- Writes broker TLS material into `~/ha/mosquitto/config/tls/`, keeps the CA key outside the container mount, sets permissions, and restarts Mosquitto.
- `/etc/cron.d/mosquitto-tls-renew` runs monthly and calls `notify_cert_failure.sh` if renewal fails.

---

### ACME renewal and `notify_cert_failure.sh`

- `acme-renew.service` runs `acme.sh` in Docker using `/etc/acme/dynu.env` and deploys renewed certs into `~/ha/nginx/ssl/`.
- Certificate renewal is defined in `acme-renew.service`; add failure email through an explicit shell wrapper or systemd failure handler if needed.
- `notify_cert_failure.sh` sends a concise failure email through `notify_email.py`; the Mosquitto TLS cron job uses it on renewal failure.
- `acme-renew.timer` runs hourly.

---

### `notify_email.py`

- Python SMTP helper used by the shell and Python alert scripts.
- Loads mail settings from `~/secrets/scripts.env`.
- Supports comma-separated `EMAIL_TO` recipients.

---

### `modsec_alert.py`

- Parses rotated ModSecurity audit logs, counts severity 1-2 hits, and sends an aggregated email summary with sample events.
- `/etc/logrotate.d/ha-modsec` rotates the WAF audit log weekly and runs `modsec_alert.py` against the rotated `audit.log.1` file.
- `/etc/logrotate.d/ha-nginx` rotates nginx access/error logs weekly.

---

## How Secrets Are Loaded

- Shell scripts that need stack or alerting values usually source `~/secrets/ha.env` and/or `~/secrets/scripts.env`.
- `notify_email.py` loads `~/secrets/scripts.env` directly rather than relying on a shell wrapper.
- `acme-renew.service` uses `/etc/acme/dynu.env` because its DNS credentials belong to the root-managed ACME flow, not the user-owned secrets folder.
- Scripts that do not need secrets, such as `disk_healthcheck.sh` and `server_make_snapshot.sh`, do not load them.

---

## How to Run

- Manual:

      ./scripts/container_healthcheck.sh
      ./scripts/ha_eos_check.sh
      ./scripts/server_make_snapshot.sh

- With sudo, when needed:

      sudo ./scripts/ha_eos_check.sh
      sudo ./scripts/server_make_snapshot.sh
      sudo ./scripts/lynis_audit.sh

- Scheduled entrypoints:
  - `server-healthcheck.timer` runs `server_healthcheck.sh` every 30 minutes.
  - `acme-renew.timer` runs `acme.sh` inside a temporary Docker container hourly through `acme-renew.service`.
  - `crowdsec-hub-update.timer` runs `/usr/local/bin/crowdsec-hub-update.sh` weekly.
  - `/etc/cron.d/container-healthcheck` runs `container_healthcheck.sh` every 10 minutes.
  - `/etc/cron.d/mosquitto-tls-renew` runs `renew_mosquitto_tls.sh` monthly.
  - `/etc/cron.weekly/trivy-scan` runs `trivy_scan.sh`.
  - `/etc/cron.weekly/lynis-audit` runs `lynis_audit.sh`.
  - `/etc/cron.d/disk-healthcheck` runs `disk_healthcheck.sh` every 4 hours.
  - `/etc/logrotate.d/ha-modsec` runs `modsec_alert.py` after rotating the WAF audit log.
  - `/etc/logrotate.d/ha-nginx` rotates nginx access/error logs.

---

## Potential Problems

- `ha_eos_check.sh` fails fast if `HA_EXTERNAL_HOST` or `HA_TOKEN` is missing.
- The optional MQTT auth test in `ha_eos_check.sh` only runs when `-u` and `-p` are supplied and `mosquitto_pub` / `mosquitto_sub` are available in the Mosquitto container.
- `server_healthcheck.sh` and `server_make_snapshot.sh` can re-exec with `sudo`, so unattended runs need root or passwordless sudo.
- `container_healthcheck.sh` can run without `HA_TOKEN`, but then its authenticated Home Assistant `/api/` probe is skipped.
- `renew_mosquitto_tls.sh` depends on `HA_EXTERNAL_HOST` and `HA_LAN_IP` being present in `~/secrets/ha.env`.
- `server_make_snapshot.sh` is a rebuild-oriented config snapshot, not a full home-directory or media backup. It excludes Frigate media, but the archive can still contain private runtime state and must not be published.
