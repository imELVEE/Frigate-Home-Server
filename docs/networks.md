# Networks & Firewall

This stack uses separate Docker networks so internal services do not sit on the same network as the public HTTPS entry point.

---

## Docker Bridges

Two Docker networks are defined in the Compose file:

- **`ha_net`** (e.g. `172.21.0.0/16`)
  - Connects nginx <-> Home Assistant.
  - nginx publishes 80/443 to the host.
  - Home Assistant publishes 8123 for LAN-only fallback.
- **`frigate_bridge`** (e.g. `172.18.0.0/16`)
  - Connects Home Assistant <-> Mosquitto <-> Frigate.
  - MQTT and Frigate endpoints are not exposed to the host WAN NIC.

Why bridges?

- They are private internal LAN segments inside Docker.
- Internal services are not reachable from the internet unless explicitly published.

No container uses `network_mode: host`, which helps prevent accidental exposure and keeps IP-based security meaningful.  
Fallback: use host networking only if a device/driver demands it, and compensate with stricter firewall rules and explicit notes about what is now exposed.

---

## Host Firewall (UFW)

`ufw` is configured as:

- `default deny incoming`
- Allow:
  - `80,443/tcp` (nginx) - public entry point
  - `22/tcp` from LAN only - SSH limited to local subnet
  - `8123/tcp` from LAN only - HA direct access limited to local subnet

MQTT is **not** opened on the host; access is only via the Docker bridge network.

Config files under `/etc/ufw/` are host-specific and are not included in the repo; apply rules manually on the target host.

---

## Trusted Proxies (Home Assistant)

`trusted_proxies` in `configuration.yaml` includes:

- `127.0.0.1`, `::1`
- Subnets for `ha_net` and `frigate_bridge`
- LAN CIDR (`LAN_SUBNET`)

**Why:**  
This prevents spoofed `X-Forwarded-For` headers. Only requests arriving from those networks are allowed to set the client IP that HA uses.

---

## Exposure Map

- **WAN:**
  - Only nginx on ports 80/443.

- **LAN:**
  - nginx (80/443)
  - HA (8123) - direct web UI fallback; plain HTTP and bypasses nginx/WAF
  - SSH (22)

- **Internal-only:**
  - MQTT 8883 (TLS)
  - Frigate API / UI (`5000` is not published to the host)
  - HA's internal service address (`homeassistant:8123` from within Docker)

---

## Verification Commands

On the host:

- Firewall snapshot:

      sudo ufw status verbose

- Raw listening ports:

      ss -ltpn

From `~/ha`:

- List Docker networks:

      docker network ls

- Inspect the Compose-created bridge networks:

      docker network inspect ha_ha_net
      docker network inspect ha_frigate_bridge

  Compose often prefixes the actual Docker network objects with the project name. In this repo, the project directory is `ha`, so the engine-level network names are often `ha_ha_net` and `ha_frigate_bridge` even though the Compose network keys are `ha_net` and `frigate_bridge`.

The `scripts/ha_eos_check.sh` script also captures:

- `ufw status`
- `nft list ruleset`
- `ss -ltpn`

as part of the health report.

---

## Potential problems

- Moving from host networking invalidates `127.0.0.1` shortcuts; use service names on the bridge and expose ports only on nginx.
- If `trusted_proxies` omits the actual bridge subnet (or is overly broad like `172.16.0.0/12`), HA will mishandle client IPs or reject proxied requests.
- Host-side probes to bridge-only MQTT ports fail by design; that is expected.
- Docker's actual network object names may be prefixed by the Compose project name, so inspecting `ha_net` directly may fail even though that is the network key in `docker-compose.yml`.
- If LAN clients use the public DDNS hostname and the router hairpins that traffic, failed logins can ban the translated public/router address. Use the internal URL or split DNS locally.

---

## Summary

- Docker bridges = private internal LAN segments.
- UFW = the host firewall that filters incoming traffic.
- HA's `trusted_proxies` = which networks HA accepts forwarded client IPs from.
