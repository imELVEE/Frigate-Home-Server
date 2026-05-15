# Docker & Compose

Docker runs each service in its own container while still sharing the host kernel. Compared to a full virtual machine, containers start faster, use less RAM, and are easier to rebuild.

Docker Compose defines which containers to start, which networks to attach, which folders to mount, and how services should restart.

---

## Why Containers Here?

- **Isolation:** Home Assistant, nginx, Mosquitto, and Frigate each get their own sandbox. If one misbehaves, the others stay stable.
- **Reproducibility:** Config + image tag = identical environment after rebuilds or migrations.
- **Convenience:** Most of the stack already exists as prebuilt images, so setup is faster and updates are usually just a pull/redeploy instead of a manual install.
- **Exposure control:** By putting services on dedicated Docker bridges instead of the host network, you avoid accidental exposure of MQTT or Frigate and keep HTTPS access centralized on nginx.
- **Speed:** Containers launch in seconds, so health restarts are quick.

---

## Layout

- **Compose spec:** `ha/docker-compose.yml`
- **Entry wrapper:** `ha/compose.sh`  
  - Loads `~/secrets/ha.env` + `~/secrets/scripts.env`  
  - Runs `docker compose ...` in the `~/ha` directory
- **Stack directories:**
  - `ha/nginx/`
  - `ha/homeassistant/`
  - `ha/mosquitto/`
  - `ha/frigate/`
  - `ha/acme/`
- **Networks:**
  - `ha_net` (nginx <-> Home Assistant)
  - `frigate_bridge` (Home Assistant <-> Mosquitto <-> Frigate)
- **Volumes:**
  - Service subfolders under `~/ha`
  - `/etc/localtime:ro` for consistent host/container time

---

## Services

- **nginx (`owasp/modsecurity-crs:nginx`)**  
  Reverse proxy + TLS terminator + WAF.  
  Handles the public 80/443 path.

- **homeassistant (custom build)**  
  Adds `hass-web-proxy-lib` required by the Frigate integration.  
  Runs as UID 1000 so configs stay user-owned, not root.  
  Port 8123 is also published for optional direct host/LAN access.

- **mosquitto (`eclipse-mosquitto:2`)**  
  Internal MQTT broker on port 8883 with TLS, used by Frigate/HA with a local CA.

- **frigate (`ghcr.io/blakeblackshear/frigate:0.16.1`)**  
  NVR that uses the Intel iGPU via VAAPI (`/dev/dri/renderD128`, `LIBVA_DRIVER_NAME=i965`) to decode camera streams efficiently and run detections.

---

## Networking

A Docker bridge is a private virtual switch:

- Containers on the same bridge can talk to each other by name (Docker's embedded DNS).
- The host can talk *into* the bridge, but outsiders cannot unless you publish ports.

In this stack:

- `ha_net` (e.g. `172.21.0.0/16`):
  - nginx <-> Home Assistant
  - nginx publishes 80/443 to the host
  - Home Assistant also publishes 8123 to the host for optional direct access
- `frigate_bridge` (e.g. `172.18.0.0/16`):
  - Home Assistant <-> Mosquitto <-> Frigate
  - MQTT and Frigate never publish ports to the host

No container uses `network_mode: host`, which:

- Makes accidental port exposure harder.
- Keeps IP-based controls meaningful.

---

## Health & Lifecycle

- nginx has a healthcheck that curls `127.0.0.1:18081/healthz` with `Host: ${HA_EXTERNAL_HOST}` and accepts HTTP 200, 401, or 403 as healthy.
- Restart policy:
  - `restart: unless-stopped` so services auto-recover after reboots or transient failures.

---

## Essential Commands

From `~/ha`:

- Start or update the stack (with secrets loaded):

      ./compose.sh up -d

- Rebuild the HA image when Python deps or the Frigate integration change:

      ./compose.sh build homeassistant

- Pre-fetch newer base images before redeploying:

      ./compose.sh pull nginx mosquitto frigate

- See running/health state across services:

      ./compose.sh ps

- Run a command *inside* a container (e.g., shell, curl) without installing tools on the host:

      ./compose.sh exec <svc> <cmd>
