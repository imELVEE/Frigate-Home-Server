# Troubleshooting

## If HA is unreachable
- Check container health: `./compose.sh ps` (nginx + homeassistant should be healthy).
- If nginx is unhealthy: `./compose.sh exec nginx nginx -t`; fix template/render errors.
- If HA banned proxy IPs: clear `homeassistant/ip_bans.yaml` and ensure `trusted_proxies` include loopback and the actual Docker bridge subnets.
- Confirm upstream/ports: nginx must proxy `homeassistant:8123`; nginx publishes 80/443, while direct HA 8123 should be LAN-only fallback.
- For local curls, force Host/SNI: `curl --resolve <PUBLIC_HOSTNAME>:443:127.0.0.1 https://<PUBLIC_HOSTNAME>/`.

## If MQTT or Frigate connectivity issues
- Verify broker and Frigate are up: `./compose.sh ps`; tail Mosquitto for CONNACK 5 errors.
- Credentials: update `/mosquitto/config/passwd` and restart the broker if auth fails.
- If auth still fails after a password change, check for credential drift between the broker password file, Frigate's env-backed MQTT settings, and Home Assistant's UI-configured MQTT integration.
- Hostnames/ports: inside Docker use `mosquitto`; Frigate/HA should use 8883 with the CA mounted.
- Frigate env substitution uses Frigate's `{FRIGATE_VAR}` syntax in supported fields; for MQTT `user` / `password`, use the quoted form shown in `config.yml`, then restart Frigate after fixing.
- HA's MQTT connection is UI-configured in the current setup; if broker host, CA, or credentials drift there, MQTT consumers will break.

## If cert issuance or renewals fail
- Ensure `/etc/acme/dynu.env` exists, mode 600, with Dynu API keys; ACME is optional unless exposing externally.
- Run the renewal service directly and inspect its logs: `sudo systemctl start acme-renew.service` then `journalctl -u acme-renew.service -n 100 --no-pager`.
- If certs renew but nginx still serves the old certificate, reload nginx: `./compose.sh exec nginx nginx -s reload`.

## If WAF or auth blocks expected traffic
- Wrong Host/SNI yields nginx 444 (often shown by curl as an empty reply); always send the real hostname, even for local curls. Valid HTTP host requests should redirect to HTTPS with 308.
- nginx healthcheck accepts 200/401/403 from `/healthz`; other results will mark the container unhealthy.
- False positives to check: webhook rule `932130` and numeric Host rule `920350` (healthz); exclusions live in `ha-extra/22-modsec-exclusions.conf`.
- `/auth/login_flow` runs CRS in DetectionOnly with rule `920420` removed; `/auth` and `/api` stay blocking; `/api/websocket` has ModSecurity off.

## If health scripts or backups fail
- `ha_eos_check.sh` requires `HA_EXTERNAL_HOST` and `HA_TOKEN`; `container_healthcheck.sh` can run without `HA_TOKEN`, but then its authenticated HA API probe is skipped.
- The MQTT auth probe in `ha_eos_check.sh` only runs when `-u` and `-p` are supplied.
- `server_make_snapshot.sh` should run with sudo for a complete `/etc` snapshot; `ALLOW_NON_ROOT_SNAPSHOT=1` allows a partial run when needed.
- `server_make_snapshot.sh` is a rebuild-oriented config backup, not a full home-directory or media backup.
- If HA bans local users after DDNS access from inside the LAN, suspect router hairpin/loopback behavior and use the internal URL or split DNS.
