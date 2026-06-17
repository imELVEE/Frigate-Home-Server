# nginx & WAF

nginx is the reverse proxy for the stack. It receives HTTP/S traffic, enforces request rules and headers, and proxies approved requests to Home Assistant.

ModSecurity with the OWASP Core Rule Set (CRS) inspects requests for common attack patterns before they reach the application.

External exposure is optional; nginx remains the single ingress even on LAN-only deployments so other services stay unexposed.

---

## What Is a Reverse Proxy?

A reverse proxy accepts client traffic on behalf of backend services. Clients see only nginx; Home Assistant sits safely behind it.

Benefits:

- Single place for TLS termination
- Consistent security headers
- Rate limiting
- WAF enforcement
- No direct exposure of HA to the internet

---

## What Is a WAF?

A Web Application Firewall inspects HTTP payloads/headers for signatures of SQL injection, XSS, path traversal, and other common attacks.

Here, the OWASP CRS is used in:

- **Blocking mode** on proxied HTTP paths, including:
  - `/`
  - `/auth`
  - `/api` (except `/api/websocket`)
- **Special case** on:
  - `/auth/login_flow` - custom CRS tuning removes noisy rule `920420` and keeps that handshake in `DetectionOnly`
- **Off** on:
  - `/api/websocket` - WebSocket handshake differs from normal HTTP

---

## Key Files (`ha/nginx`)

- `conf.d/homeassistant.conf.template`  
  Main server block, rendered with `HA_EXTERNAL_HOST` at container start via:

  - `entrypoint.d/05-render-ha-conf.sh` (runs `envsubst`)

- `conf.d/00-globals.conf`  
  Defines:

  - Rate limit zones (`limit_req_zone`)
  - Connection limit zones (`limit_conn_zone`)
  - WebSocket `Connection` header mapping

- `conf.d/00-healthz.conf.template`  
  Local loopback-only healthcheck endpoint rendered with `HA_EXTERNAL_HOST`.

- `conf.d/10-http-redirect.conf.template`
  Port 80 server block rendered with `HA_EXTERNAL_HOST`; valid hosts get a `308` HTTPS redirect and wrong hosts are dropped with nginx `444`.

- `conf.d/ha-extra/10-modsec-baseline.conf`
  Default HTTPS-server WAF mode is `DetectionOnly`; individual UI/API locations explicitly turn blocking on.

- `conf.d/ha-extra/21-auth-loginflow.conf`
  Narrow CRS tuning for the Home Assistant login flow.

- `conf.d/modsecurity.conf`  
  Enables ModSecurity, loads ModSecurity config, and defines the single audit-log configuration.

- `conf.d/logging.conf`  
  Log formats and destinations.

- `ssl/fullchain.pem`, `ssl/privkey.pem`  
  TLS materials currently used by nginx.

- Logs:
  - `ha/nginx/log/` (access/error logs)
  - `ha/nginx/logs/modsec/audit.log` (WAF audit logs)

---

## How Requests Flow

1. Client hits `http://HA_EXTERNAL_HOST/` or `https://HA_EXTERNAL_HOST/`.
2. nginx checks the `Host` header:
   - If it doesn't match `HA_EXTERNAL_HOST`, nginx returns 444, which closes the connection without a normal HTTP response.
   - If HTTP host matches, nginx returns `308` to the HTTPS URL.
3. Method check:
   - Only allows a reasonable set (e.g. GET/POST/HEAD/OPTIONS/PUT/DELETE).
4. Security headers applied:
   - HSTS
   - `X-Frame-Options: SAMEORIGIN`
   - `X-Content-Type-Options: nosniff`
   - Referrer-Policy
   - Permissions-Policy (e.g., disabling mic/cam/geo)
5. Rate / connection controls:
   - `limit_conn addr 20` (max simultaneous connections per IP)
   - `limit_req perip 20r/s` (burst 40) on `/auth` and `/api`
6. Path-specific WAF:
   - `/`, `/auth`, and `/api` (except websocket):
     - CRS in **blocking** mode.
   - `/auth/login_flow`:
     - extra CRS tuning removes rule `920420` and keeps that handshake in **DetectionOnly**.
   - `/api/websocket`:
     - WAF off, but proxy headers and timeouts are maintained for WebSocket.

7. Requests are proxied to `homeassistant:8123` with:
   - `Host` header preserved
   - `X-Forwarded-For` / `X-Forwarded-Proto` populated

---

## Request Size & Buffers

- `client_max_body_size 1m`  
  Limits upload size, reducing risk from overly large payloads.

- Adjusted header buffers:  
  Prevent oversized headers from breaking the UI while still keeping header limits in place.

---

## Healthcheck

A local server is exposed at `127.0.0.1:18081/healthz`:

- nginx proxies `/healthz` to Home Assistant.
- Docker `healthcheck` for nginx hits this endpoint every ~30 seconds and expects HTTP 200/401/403.

If health fails, Docker marks nginx as unhealthy so the problem is visible quickly in container status and Compose output.

---

## TLS / ACME

- Certs from Let's Encrypt via DNS-01 (Dynu) are placed in `ha/nginx/ssl/`:
  - `fullchain.pem`
  - `privkey.pem`
- `acme-renew.service` (systemd) reloads nginx via:

      ./compose.sh -f docker-compose.yml exec -T nginx /usr/sbin/nginx -s reload

  after a successful renewal.

---

## Commands

From `~/ha`:

- Syntax test:

      ./compose.sh exec nginx nginx -t

- Tail access/error logs:

      ./compose.sh logs nginx

- Watch WAF audit log:

      ./compose.sh exec nginx tail -f /var/log/modsecurity/audit.log

- WAF audit logs are rotated by `/etc/logrotate.d/ha-modsec`; that rotation runs `modsec_alert.py` against the rotated audit log. Standard nginx access/error logs rotate through `/etc/logrotate.d/ha-nginx`.

---

## Potential problems

- ModSecurity is loaded as a dynamic module. Keep `load_module modules/ngx_http_modsecurity_module.so` in `nginx.conf.template`, or nginx will fail to start with unknown `modsecurity` directives.
- `unicode.mapping` must remain available alongside `SecUnicodeMapFile`, or ModSecurity startup can fail.
- `/auth/login_flow` has custom CRS tuning around rule `920420`; regressions there tend to show up as login-flow 403s.
- `/api/websocket` has ModSecurity off to avoid breaking WebSocket handshakes.
- Healthcheck expects HTTP `200`, `401`, or `403` and uses `$$code` in Compose so `${HA_EXTERNAL_HOST}` is expanded at container runtime instead of by Compose.
- CRS exclusions for `/healthz` and webhook rule `932130` live in `ha-extra/22-modsec-exclusions.conf`.
- Audit logs are pinned to `/var/log/modsecurity/audit.log`; keep that path aligned between the ModSecurity config and the mounted host directory.
