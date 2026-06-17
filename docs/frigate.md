# Frigate (Detection)

Frigate watches RTSP camera streams, detects objects (persons here), and publishes events via MQTT. In this stack it offloads video decoding to the Intel iGPU (VAAPI) and uses the NVR's lower-resolution RTSP substreams to keep resource usage low.

The Frigate container explicitly uses `America/New_York` for UI/event timestamps while the host remains on UTC.

---

## Basics

- **RTSP (Real-Time Streaming Protocol):**  
  Cameras send H.264/H.265 video streams.

- **Detection vs. Recording:**  
  Frigate can use separate streams for detection and recording.  
  In this setup, the NVR substreams are used for both roles to minimize load, so recorded clips are lower resolution.

- **Hardware decode (VAAPI):**  
  Uses the GPU to decode H.264/H.265, freeing CPU for Frigate's detector and the rest of the stack.

- **MQTT events:**  
  Frigate publishes object/motion events; HA subscribes and turns them into sensors and notifications.

---

## Files (`ha/frigate`)

- `config/config.yml` — main configuration (detectors, motion/object filters, cameras, MQTT, retention)
- `config/` also accumulates Frigate-managed state/database files that are git-ignored
- `media/` — recordings/snapshots (git-ignored; retention controlled by config)

---

## Hardware Acceleration (Why / How)

- Device: `/dev/dri/renderD128` passed into the container
- Env: `LIBVA_DRIVER_NAME=i965` selects the Intel VAAPI driver (fits the host iGPU)
- Compose:
  - `devices:` include `/dev/dri/renderD128`
  - `shm_size: 256m` to give FFmpeg ring buffers space and avoid frame drops

**Why:**  
Without VAAPI, decoding multiple camera streams would peg the CPU. Offloading decode to the GPU keeps the system responsive.

---

## MQTT Settings

- **Broker:** `mosquitto` on the `frigate_bridge` network
- **Port:** 8883 with TLS; the CA certificate is mounted into the container and referenced by `tls_ca_certs`
- **Credentials:** `MQTT_USER` / `MQTT_PASSWORD` from `~/secrets/ha.env`, mapped into the container as `FRIGATE_MQTT_USER` / `FRIGATE_MQTT_PASSWORD`
- **Topic prefix:** `frigate`

Broker-side auth/TLS details are covered in `docs/mosquitto.md`.

---

## Detection & Motion (`config.yml`)

Current config:

- **Detector:**
  - CPU detector with 3 threads
- **Objects:**
  - Only `person` detection is enabled
  - Person filters are tuned to reduce false positives
- **Motion:**
  - Global motion settings live in `config.yml`
- **Snapshots:**
  - Enabled with bounding boxes and short retention
- **Recordings:**
  - Enabled in motion mode with short retention

---

## Cameras

- Each camera uses an RTSP substream from the NVR:
  - `backyard`
  - `side_gate`
  - `driveway`
  - `front_door`
- RTSP URLs use env placeholders:
  - `{FRIGATE_*_RTSP_USER}`
  - `{FRIGATE_*_RTSP_PASSWORD}`
  - `{FRIGATE_NVR_HOST}` (NVR IP providing substreams)

This keeps credentials out of the config file and under env control.

Each camera uses the same low-resolution detect profile to keep system load consistent.

---

## HA Integration

- A Frigate custom integration is bundled in HA’s `custom_components/frigate`.
- Home Assistant consumes Frigate through the integration and MQTT.
- The Home Assistant side of notifications, automations, and runtime config changes is documented in `docs/homeassistant.md`.

---

## Ops Commands

From `~/ha`:

- Logs:

      ./compose.sh logs frigate

- Check VAAPI configuration:

      ./compose.sh exec frigate sh -lc 'echo $LIBVA_DRIVER_NAME && ls -l /dev/dri'

- Verify MQTT reachability from inside Frigate (TLS):

      ./compose.sh exec frigate sh -lc 'nc -z mosquitto 8883'

- Check Frigate's internal API from inside the container:

      ./compose.sh exec frigate curl -f http://127.0.0.1:5000/api/version

---
