## Public Repo Sync

- Synced the public repository to the live server configuration while continuing to omit sensitive information.
- Updated markdowns and documents for updated configuration.

## Server v4

- Updated `ha-stack.service` so the Compose stack starts and stops through
  `ha/compose.sh`, ensuring boot-time startup loads the stack env files.
- Passed `HA_TOKEN` into Home Assistant through Compose.
- Updated healthcheck failure notifications so MQTT publishes authenticate with
  credentials loaded from `secrets/ha.env`.
- Simplified nginx ModSecurity layering:
  one `DetectionOnly` baseline, one audit/logging configuration, and one
  login-flow exclusion for rule `920420`.
- Removed the old duplicate ModSecurity audit/debug and patch files.
- Corrected the ACME timer description to identify it as an hourly renewal
  check, matching `OnCalendar=hourly`. This was a metadata correction and did
  not change certificate-renewal behavior.

## Server v3

- Added nginx HTTP-to-HTTPS redirect on port `80`.
- Dropped wrong-host HTTP requests with nginx `444`.
- Redirected valid HTTP requests to HTTPS with status `308`.
- Updated snapshot version tracking so it discovers running Compose service
  image names and image IDs dynamically instead of relying on hardcoded image
  names.
- Included the changelog in server snapshots so backup artifacts
  preserve live change history.
- Updated the Home Assistant image build to install Frigate integration
  requirements from the integration manifest instead of pinning
  `hass-web-proxy-lib==0.0.7`.
- Set the Frigate container timezone explicitly to `America/New_York` so UI
  events and snapshots align with local time while the host stays on UTC.
- Cleared a stale Home Assistant IP ban caused by LAN DDNS hairpin access.
- Documented the safer LAN behavior: use the internal URL or split DNS locally
  to avoid router hairpin bans.
