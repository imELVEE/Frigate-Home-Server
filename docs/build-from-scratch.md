# Build Book

This is a practical guide to building the server from scratch if it were ever completely lost or corrupted, or if someone wants to follow along with their own setup. Because the server was already set up before this repo existed, some steps are reconstructed and may be unorthodox or technically incorrect in places (hopefully not!). With the files in the repo, it should be easy to work around those gaps.

## Prereqs

- Ubuntu 24.04 LTS installed
- Non-root user with `sudo`
- Dynu account + API credentials (if using DNS-01/HTTPS)
- Domain/DDNS hostname (e.g. `home.example.net`) if you plan to expose externally

## Exit criteria

- Docker stack running with nginx/HA/Frigate/Mosquitto healthy on bridge networks
- HTTPS working if external exposure is enabled
- Healthcheck + renew timers active
- Backups/snapshots configured with rotation

Commands below include brief rationale for each step.

---

## Base OS + Firewall

Update the system and install required packages:

    sudo apt update && sudo apt upgrade -y
    sudo apt install -y ca-certificates curl gnupg git \
        docker.io docker-compose-plugin python3-pip ufw sysstat

Allow your user to run Docker and enable Docker at boot:

    sudo usermod -aG docker your_username
    sudo systemctl enable --now docker

Log out and back in so the new `docker` group membership takes effect.

Lock down the host firewall with LAN-focused access rules:

    sudo ufw default deny incoming
    sudo ufw allow 80,443/tcp
    sudo ufw allow from LAN_SUBNET to any port 22 proto tcp
    sudo ufw allow from LAN_SUBNET to any port 8123 proto tcp
    sudo ufw enable

Verify:

    sudo ufw status verbose

---

## Directory Layout

Create the main directories:

    mkdir -p ~/ha/{nginx,homeassistant,mosquitto,frigate,acme} \
             ~/scripts ~/secrets ~/logs ~/snapshots

Why:

- `ha/` contains all Docker configs and data.
- `scripts/` holds host-side scripts (health checks, backups, TLS renewal).
- `logs/` and `snapshots/` keep runtime output and backups separate.
- Optional: `secrets/` isolates `.env` files from git.

This repo uses a secrets folder because it makes obfuscating sensitive information easier when sharing publicly. For a home setup you do not need `.env` files or a secrets folder and can put your information directly in your config files.

---

## Secrets (optional, example env files)

Copy and fill the provided example env files; real secrets stay local-only, gitignored, and `chmod 600`.

From repo root:

    mkdir -p ~/secrets
    cp secrets/ha.env.example ~/secrets/ha.env
    cp secrets/scripts.env.example ~/secrets/scripts.env
    chmod 600 ~/secrets/*.env

Edit `~/secrets/ha.env` and `~/secrets/scripts.env` with your values. The example files live in the repo for reference; only the filled files are used at runtime.

---

## Compose Wrapper (`ha/compose.sh`)

Create a wrapper so every `docker compose` call automatically picks up env files and runs in `~/ha`:

    cat > ~/ha/compose.sh <<'EOF'
    #!/usr/bin/env bash
    set -e

    # Load secrets if present
    if [ -f "$HOME/secrets/ha.env" ]; then
      set -a
      . "$HOME/secrets/ha.env"
      set +a
    fi

    if [ -f "$HOME/secrets/scripts.env" ]; then
      set -a
      . "$HOME/secrets/scripts.env"
      set +a
    fi

    cd "$HOME/ha"
    exec docker compose "$@"
    EOF

Make it executable:

    chmod +x ~/ha/compose.sh

---

## Docker Compose Definition (`ha/docker-compose.yml`)

Write `~/ha/docker-compose.yml` to define the services, networks, and volumes. The exact contents depend on your final config, but structurally:

- Services:
  - `nginx` (image: `owasp/modsecurity-crs:nginx`)
  - `homeassistant` (build from `ha/homeassistant/Dockerfile`)
  - `mosquitto` (image: `eclipse-mosquitto:2`)
  - `frigate` (image: `ghcr.io/blakeblackshear/frigate:0.16.1`)
- Networks:
  - `ha_net`
  - `frigate_bridge`
  - Preferred: bridge networks for isolation and DNS by service name; fallback to host networking only if a device/driver forces it, and document the lost isolation/port exposure.
- Volumes:
  - Bind mounts under `~/ha/...`
  - `/etc/localtime:ro` for time sync
- Healthcheck:
  - For nginx, curl `http://127.0.0.1:18081/healthz`

---

## Nginx + WAF Configuration (optional external exposure)

Even on a LAN-only setup, keep nginx as the single ingress and WAF; publishing 80/443 externally is optional. These are the standard HTTP/HTTPS ports.
- If you are LAN-only and trust your LAN, you can skip DDNS/external TLS and access Home Assistant directly at `http://<host-ip>:8123`. The main risk then is anyone or anything on your LAN (Wi-Fi or wired). In this setup, 8123 is still exposed to LAN as a fallback if DDNS ever goes down.

Under `~/ha/nginx/`:

- `conf.d/homeassistant.conf.template`
  - Server block for `HA_EXTERNAL_HOST`
  - Proxies to `homeassistant:8123`
  - Enforces Host header, methods, headers, rate limits
  - Enables ModSecurity / CRS on `/`, `/auth`, and `/api`
  - Leaves ModSecurity off on `/api/websocket`
- `conf.d/00-globals.conf`
  - `limit_req_zone`, `limit_conn_zone`
  - WebSocket connection mapping
- `conf.d/00-healthz.conf.template`
  - Loopback-only healthcheck endpoint rendered with `HA_EXTERNAL_HOST`
- `conf.d/ha-extra/21-auth-loginflow.conf`
  - CRS tuning for the Home Assistant login flow (e.g. removing rule 920420 and relaxing that handshake)
- `conf.d/modsecurity.conf`, `conf.d/logging.conf`
  - WAF and logging configuration

Add a small entrypoint snippet (e.g., `entrypoint.d/05-render-ha-conf.sh`) to run `envsubst` on `homeassistant.conf.template` and produce `homeassistant.conf` using `HA_EXTERNAL_HOST`.

Also create `nginx/ssl/` for certs:

- `fullchain.pem`
- `privkey.pem`

You'll populate these via ACME in step 9.

---

## Home Assistant Build & Config

Create `~/ha/homeassistant/Dockerfile`:

- Base: `ghcr.io/home-assistant/home-assistant:stable`
- Install `hass-web-proxy-lib` (required by the Frigate integration)
- Use non-root UID/GID (e.g. 1000)

Example (simplified):

    FROM ghcr.io/home-assistant/home-assistant:stable
    RUN pip install --no-cache-dir hass-web-proxy-lib==0.0.7

Populate `~/ha/homeassistant/configuration.yaml`:

- `external_url`, `internal_url` using `!env_var`
- `trusted_proxies` including:
  - `127.0.0.1`, `::1`
  - Docker subnets for `ha_net` and `frigate_bridge`
  - `LAN_SUBNET`
- `use_x_forwarded_for: true`
- `ip_ban_enabled: true`
- Low `login_attempts_threshold` (e.g. 3)
- CORS allowlist restricted to `EXTERNAL_URL`
- MQTT configuration pointing to Mosquitto (host `mosquitto`, port `8883` with TLS CA mounted)

Add:

- `homeassistant/automations/` for Frigate integration and notifications
- `homeassistant/custom_components/frigate` and `homeassistant/custom_components/hacs`

Mount the entire folder as `/config` via `docker-compose.yml`.

---

## Mosquitto Configuration & Local CA

Create `~/ha/mosquitto/config/mosquitto.conf`:

    listener 8883 0.0.0.0
    cafile /mosquitto/config/tls/ca.crt
    certfile /mosquitto/config/tls/server.crt
    keyfile /mosquitto/config/tls/server.key
    tls_version tlsv1.2
    allow_anonymous false
    password_file /mosquitto/config/passwd

    persistence true
    persistence_location /mosquitto/data/
    log_dest stdout
    log_type all

Create `~/scripts/renew_mosquitto_tls.sh` to:

- Create a local CA if missing
- Issue a server cert with SANs for:
  - `home.example.net`
  - `HA_LAN_IP`
  - `localhost`
- Drop `ca.crt`, `server.crt`, and `server.key` into `ha/mosquitto/config/tls/`
- Set perms to `640` with UID/GID 1883
- Restart Mosquitto via:

      ~/ha/compose.sh restart mosquitto

Run it once to bootstrap TLS and mount the CA into Frigate (see `docs/frigate.md` for mounting path).

---

## ACME with Dynu (DNS-01, optional if exposing externally)

Skip this if you keep the stack private to the LAN; otherwise use DNS-01 so no inbound ports are required.

Create `/etc/acme` and `/etc/acme/dynu.env`:

    sudo mkdir -p /etc/acme
    sudo tee /etc/acme/dynu.env >/dev/null <<'EOF'
    Dynu_ClientId=your-dynu-client-id
    Dynu_Secret=your-dynu-secret
    EOF
    sudo chmod 600 /etc/acme/dynu.env

The repo also includes `etc/acme/dynu.env.example` as the example file for this env, but the live ACME file is `/etc/acme/dynu.env`.

Issue the initial certificate:

    docker run --rm --env-file /etc/acme/dynu.env \
      -v ~/ha/acme:/acme.sh -v ~/ha/nginx/ssl:/deploy \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh \
        --register-account -m you@example.com \
        --server letsencrypt \
        --issue --dns dns_dynu -d home.example.net --keylength ec-256'

Install the cert/key into nginx's SSL directory:

    docker run --rm --env-file /etc/acme/dynu.env \
      -v ~/ha/acme:/acme.sh -v ~/ha/nginx/ssl:/deploy \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh \
        --server letsencrypt \
        --ecc \
        --install-cert -d home.example.net \
          --fullchain-file /deploy/fullchain.pem \
          --key-file /deploy/privkey.pem'

Now nginx has `fullchain.pem` and `privkey.pem` in `ha/nginx/ssl/`.

---

## ACME Renew Timer

Create `acme-renew.service`:

    sudo tee /etc/systemd/system/acme-renew.service >/dev/null <<'EOF'
    [Unit]
    Description=Renew Let's Encrypt certs with acme.sh (Dynu DNS)
    Wants=network-online.target docker.service
    After=network-online.target docker.service

    [Service]
    Type=oneshot
    WorkingDirectory=<HOME>/ha
    EnvironmentFile=/etc/acme/dynu.env
    ExecStart=<HOME>/scripts/acme_renew.sh
    ExecStartPost=<HOME>/ha/compose.sh -f <HOME>/ha/docker-compose.yml exec -T nginx /usr/sbin/nginx -s reload
    User=root
    EOF

Create `~/scripts/acme_renew.sh`:

    cat > ~/scripts/acme_renew.sh <<'EOF'
    #!/usr/bin/env bash
    set -euo pipefail

    /usr/bin/docker run --rm --env-file /etc/acme/dynu.env \
      -v "$HOME/ha/acme:/acme.sh" \
      -v "$HOME/ha/nginx/ssl:/deploy" \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh --cron --server letsencrypt' \
      || {
        "$HOME/scripts/notify_cert_failure.sh" "ACME" "Primary domain via acme.sh renew failed"
        exit 1
      }
    EOF

Make it executable:

    chmod +x ~/scripts/acme_renew.sh

Create `acme-renew.timer`:

    sudo tee /etc/systemd/system/acme-renew.timer >/dev/null <<'EOF'
    [Unit]
    Description=Run ACME renew hourly

    [Timer]
    OnCalendar=hourly
    RandomizedDelaySec=300
    Persistent=true

    [Install]
    WantedBy=timers.target
    EOF

Enable:

    sudo systemctl enable --now acme-renew.timer

Optional belt-and-suspenders cron:

    crontab -e

Add:

    3 4 * * * "$HOME/.acme.sh"/acme.sh --cron --home "$HOME/.acme.sh" > /dev/null

---

## Healthcheck Timer & Scripts

Create `~/scripts/ha_eos_check.sh`, `~/scripts/server_healthcheck.sh`, and `~/scripts/notify_email.py` as detailed in `docs/scripts.md`. They should:

- Probe Docker container health
- Check nginx `/healthz`, HA `/api`, WebSocket, and WAF behavior
- Verify MQTT connectivity and auth
- Snapshot firewall and listening ports
- Log to `~/snapshots/health/health_latest.log`
- Email/MQTT on failure

Make scripts executable:

    chmod +x ~/scripts/*.sh

Create `server-healthcheck.service`:

    sudo tee /etc/systemd/system/server-healthcheck.service >/dev/null <<'EOF'
    [Unit]
    Description=Server healthcheck via server_healthcheck.sh

    [Service]
    Type=oneshot
    ExecStart=<HOME>/scripts/server_healthcheck.sh
    EOF

Create `server-healthcheck.timer`:

    sudo tee /etc/systemd/system/server-healthcheck.timer >/dev/null <<'EOF'
    [Unit]
    Description=Run server healthcheck every 30 minutes

    [Timer]
    OnCalendar=*:0/30
    Persistent=true

    [Install]
    WantedBy=timers.target
    EOF

Enable:

    sudo systemctl enable --now server-healthcheck.timer

---

## Build & Launch the Stack

From `~/ha`:

    ./compose.sh pull nginx mosquitto frigate   # fetch images
    ./compose.sh build homeassistant            # build custom HA image
    ./compose.sh up -d                          # start all containers
    ./compose.sh ps                             # verify state/health

---

## Validate

Quick check:

    ./scripts/container_healthcheck.sh

Full check (with sudo):

    sudo ./scripts/ha_eos_check.sh

Review:

- `docker logs nginx|homeassistant|mosquitto|frigate`
- `ha/nginx/log/` and `ha/nginx/logs/modsec/audit.log`
- HA UI at `https://home.example.net/`

---

## Backups / Snapshots

Use `server_make_snapshot.sh` to create versioned tarball backups of:

- `/etc`
- `~/ha`
- `~/scripts`

Example (from `~/scripts/server_make_snapshot.sh`):

- Output to `~/snapshots/server/v1/SNAPSHOT_YYYYMMDDTHHMMSSZ/`
- Keep last 3 snapshots per major stack version

Run manually or via cron/systemd as needed.

---

If anything breaks, you can:
- Reinstall Ubuntu
- Recreate this layout and config files
- Re-run ACME
- Restore from `snapshots/`
- And get back to an identical system.
