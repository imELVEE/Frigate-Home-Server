# Home Server - Home Assistant + Frigate + MQTT + Nginx/WAF

Self-hosted home automation and camera analytics stack running on Ubuntu with:

- Home Assistant (automations / UI)
- Frigate (video analytics/person detection from RTSP substreams)
- Mosquitto (MQTT broker)
- Nginx with ModSecurity/OWASP CRS (reverse proxy + WAF)
- Dynu DDNS + Let's Encrypt (DNS-01 ACME)
- Systemd timers and scripts for health checks, backups, and cert renewals

This repo is for older camera setups that may not have built-in phone notifications or person detection. The docs are split into separate topics so you can read only the parts you need.

Scope: Secure Home Assistant ingress via nginx/WAF (external access supported) with optional direct LAN access.

## Highlights

- HTTPS entry point: strict Host enforcement, ModSecurity/CRS with tuned exclusions, and TLS via DNS-01 ACME.
- Recurring checks: 10-minute container checks plus 30-minute server healthchecks with email/MQTT alerts and `/api` probes that include HA tokens to avoid bans.
- Routine maintenance: hourly ACME renew with automatic nginx reload, monthly Mosquitto TLS rotation, weekly CVE and host audits (Trivy + Lynis), and logrotate on WAF audit logs.
- Rebuild guide: documented rebuild from bare Ubuntu with all secrets and env files kept outside git.
- Backups: rotating config snapshots that keep the newest three and exclude media from the archive.

## Key Design Choices

- Bridge networks instead of host networking to preserve isolation and minimize accidental exposure; nginx publishes 80/443, and Home Assistant publishes 8123 for LAN-only fallback.
- DNS-01 ACME avoids inbound challenge ports; nginx terminates TLS and enforces headers + WAF in one place.
- MQTT uses TLS with a local CA on port `8883`.
- Secrets live in env files; example env files are included in the repo, while real files are gitignored and set to `chmod 600` so the repo is sharable without redaction.
- Health checks, backups, and cert renewals run through scripts and timers so the same steps happen every time.

---

## Architecture Summary

- **Host OS:** Ubuntu 24.04 LTS
- **Hardware:** Small form factor Intel box with iGPU (VAAPI used for video decode)
- **Core services (Docker):**
  - `nginx` (reverse proxy + WAF)
  - `homeassistant` (custom image that installs Frigate integration requirements from the integration manifest)
  - `mosquitto` (MQTT broker)
  - `frigate` (video analytics/detection)
- **Networks (Docker bridges):**
  - `ha_net`: `nginx` <-> `homeassistant` (nginx publishes 80/443; HA publishes 8123 for LAN-only fallback)
  - `frigate_bridge`: `homeassistant` <-> `mosquitto` <-> `frigate` (internal-only)
- **Ingress:**
  - Dynu DDNS for `<PUBLIC_HOSTNAME>`
  - Let's Encrypt via DNS-01 (Dynu API) using `acme.sh`
  - Nginx terminates HTTPS and enforces security headers + WAF
- **Health & Automation:**
  - Systemd timers for ACME renew and recurring server health checks
  - Cron jobs for container checks, disk checks, Mosquitto TLS rotation, CVE scans (Trivy), and host audits (Lynis)
  - Scripts for backups, checks, TLS rotation, and alerts

---

## Security Highlights

- **Reverse proxy in front of Home Assistant**
  - TLS termination with Let's Encrypt ECC certs
  - Strict Host enforcement (unknown hosts are dropped with nginx 444, which closes the connection)
  - Security headers (HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy)
- **Web Application Firewall (ModSecurity + OWASP CRS)**
  - Blocking mode on `/`, `/auth`, and `/api`
  - Detection-only for `/auth/login_flow`
  - Turned off only for `/api/websocket` (WebSocket handshake)
- **Network segmentation**
  - No container uses `network_mode: host`
  - MQTT broker and Frigate live only on `frigate_bridge`
  - Only nginx exposes ports 80/443 to the WAN; HA 8123 is a LAN fallback only
- **MQTT hardening**
  - TLS listener on 8883 with local CA
  - Auth required (`allow_anonymous false`)
- **Home Assistant hardening**
  - `trusted_proxies` restricted to loopback + Docker subnets + LAN CIDR
  - `ip_ban_enabled: true`, low `login_attempts_threshold`
  - External URL + CORS allowlist
  - Runs as UID 1000, not root
- **Secrets management**
  - `~/secrets/ha.env`, `~/secrets/scripts.env` (mode 600, git-ignored; example files `secrets/ha.env.example` and `secrets/scripts.env.example` are included)
  - `/etc/acme/dynu.env` (root-only) for Dynu API keys; example file `etc/acme/dynu.env.example` is included
- **Monitoring & hygiene**
  - Systemd timers for:
    - ACME renew (hourly) + nginx reload on success
    - Server healthcheck (every 30 minutes) with email/MQTT alerts
  - Cron jobs for 10-minute container checks, 4-hour disk checks, monthly Mosquitto TLS rotation, weekly Trivy, and weekly Lynis
  - UFW locked down: only 80/443 public; SSH and HA 8123 limited to LAN

---

## Directory Layout

Directory structure in the home directory:

- `ha/`
  - `docker-compose.yml`
  - `compose.sh`
  - `nginx/`
  - `homeassistant/`
  - `mosquitto/`
  - `frigate/`
  - `acme/`
- `scripts/` - health checks, snapshots, TLS renewal, email alerts
- `secrets/` - `.env` files (git-ignored, mode 600)
- `logs/` - runtime script logs (created when scripts run, not committed to git)
- `snapshots/` - configuration backups and health logs

---

## Documentation Map

This repo has multiple markdowns for different parts of the stack:

- **Start here:** `docs/server-architecture.md`, `docs/build-from-scratch.md`, and `docs/scripts.md`.
- **Architecture**
  - `docs/server-architecture.md` - full stack explanation (networks, boundaries, components)
- **Rebuild guide**
  - `docs/build-from-scratch.md` - step-by-step, from bare Ubuntu to a running stack
- **Subsystem docs**
  - `docs/docker.md` - Docker and Compose layout
  - `docs/nginx.md` - reverse proxy + WAF
  - `docs/homeassistant.md` - HA config, auth controls, automations
  - `docs/frigate.md` - Frigate, hardware accel, and MQTT connection
  - `docs/mosquitto.md` - MQTT broker, TLS, local CA
  - `docs/networks.md` - Docker bridges + UFW + trusted proxies
  - `docs/env.md` - secrets and environment variables (`secrets/ha.env.example` / `secrets/scripts.env.example` / `etc/acme/dynu.env.example`)
  - `docs/acme.md` - Dynu DNS-01 + acme.sh + systemd timers
  - `docs/scripts.md` - scripts, timers, and host-side automation
  - `docs/vulnerabilities.md` - known security considerations and checks
  - `docs/timers.md` - systemd timer reference

---

## Operations

- Updates: pull images periodically, rebuild the HA image when dependencies change, and apply Ubuntu security updates before weekly health runs.
- Backups: `scripts/server_make_snapshot.sh` rotates the newest three config snapshots and excludes media from the archive.
- Restore outline: reinstall Ubuntu, recreate the directory layout, restore `ha/`, `scripts/`, and secrets envs, re-issue certs, then bring the stack up with `./compose.sh up -d`.
- Certificates: ACME renew runs hourly via systemd and reloads nginx on success; DNS API credentials stay root-only.

## Verification Quickstart

- Stack state:
  ```bash
  ./compose.sh ps
  ```
- Nginx config test:
  ```bash
  ./compose.sh exec nginx nginx -t
  ```
- HA reachability via proxy:
  ```bash
  curl -I -k https://<PUBLIC_HOSTNAME>/
  ```
- MQTT pub/sub check:
  ```bash
  ./compose.sh exec mosquitto mosquitto_sub \
    -h mosquitto -p 8883 --cafile /mosquitto/config/tls/ca.crt \
    -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t '$SYS/#' -C 1
  ```
- Frigate endpoint check:
  ```bash
  ./compose.sh exec frigate curl -f http://localhost:5000/api/version
  ```
- Health script (captures firewall, WAF, MQTT, HA):
  ```bash
  sudo ./scripts/ha_eos_check.sh
  ```

---

## Tested Stack

- Host OS: Ubuntu 24.04 LTS (primary target)
- Hardware: 2014 Acer AXC-605-UB1F (Haswell iGPU using i965 VAAPI)
- Home Assistant: custom image based on `ghcr.io/home-assistant/home-assistant:stable`; Frigate integration Python requirements are installed dynamically from the bundled integration manifest
- Frigate: `ghcr.io/blakeblackshear/frigate:0.16.1`
- Mosquitto: `eclipse-mosquitto:2`
- Nginx/WAF: `owasp/modsecurity-crs:nginx`

---

## Getting Started

If you want to understand the design first:

1. Read `docs/server-architecture.md` first.
2. Skim the subsystem docs under `docs/` for areas you care about (networking / WAF / Frigate).
3. Use `docs/build-from-scratch.md` as the main rebuild guide.

If you just want to run the existing configuration on compatible hardware:

1. Prepare an Ubuntu 24.04 host.
2. Recreate the directory layout (`ha/`, `scripts/`, `secrets/`, etc.).
3. Copy and fill `~/secrets/ha.env` and `~/secrets/scripts.env` from the example files in this repo.
4. If you want external HTTPS access, configure Dynu and `/etc/acme/dynu.env` for DNS-01; otherwise keep the stack LAN-only.
5. Follow `docs/build-from-scratch.md` to build and start the stack.
