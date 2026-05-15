# Mosquitto (MQTT Broker)

MQTT is the message bus for this stack. Frigate publishes events, Home Assistant subscribes, and Mosquitto routes messages between clients.

---

## Basics

- **Topics:**  
  Hierarchical strings, e.g. `frigate/backyard/person`. Publishers and subscribers don't need to know about each other.

- **QoS:**  
  Quality of Service (0/1/2). Defaults are fine here; configuration is not heavily customized.

- **Auth/TLS:**  
  Without auth, anyone could publish/subscribe. Here we require usernames/passwords; TLS encrypts traffic for clients that support it.

---

## Files (`ha/mosquitto`)

- `config/mosquitto.conf`:

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

  - `8883`: TLS for Frigate/HA and other clients.

- `config/tls/`  
  Server cert/key/CA presented to clients.

- `ca_secure/`  
  CA private key and serial files used by the host-side TLS rotation script. This directory stays outside the container mount so the signing key does not live inside the broker container.

- `data/`  
  Broker persistence (sessions, retained messages).

- `log/`  
  Mounted log directory. In the current setup, Mosquitto logs to `stdout` via `log_dest stdout` rather than writing its main broker logs here.

---

## TLS Lifecycle

Script: `scripts/renew_mosquitto_tls.sh` (host-side)

Steps:

1. Generate a local CA if missing (4096-bit).
2. Issue a server cert with SANs for:
   - Hostname(s)
   - LAN IP
   - `localhost`
3. Place cert/key/CA in `ha/mosquitto/config/tls/`.
4. Set permissions so the broker can read the cert material without making it readable to other users on the server.
5. Restart Mosquitto via:

       ./compose.sh restart mosquitto

**Why a local CA?**

- You avoid exposing internal service certs to public CAs.
- You control the trust chain for internal services like MQTT.

---

## Network Placement

- Broker is attached only to the `frigate_bridge` Docker network.
- No host ports are published in the Compose file (all access via container network).
- HA and Frigate communicate with Mosquitto by container name (`mosquitto`) and port.

TLS on `8883` is the only listener in the current setup.

---

## Commands

From `~/ha`:

- Show listeners & auth config:

      ./compose.sh exec mosquitto sh -lc 'grep -E "^(listener|allow_anonymous)" /mosquitto/config/mosquitto.conf'

- Health checks (inside container):

      ./compose.sh exec mosquitto nc -z mosquitto 8883

- Restart after TLS rotation:

      ./compose.sh restart mosquitto

---

## Potential problems

- On the bridge network, clients must use host `mosquitto`; `127.0.0.1` refers to the container itself and will break Frigate/HA.
- Port 8883 uses TLS; host-side probes to bridge-only MQTT ports will fail by design.
- Keep the password file in sync and locked down; stale broker/client credential mismatches cause CONNACK 5 and flapping integrations.
- Home Assistant's MQTT connection is UI-configured in the current setup; if its broker host, CA, or credentials drift, MQTT-driven entities and automations will go unavailable.
