# Timers

This page lists the tracked systemd timers in this repo. Script-specific behavior is documented in `docs/scripts.md`.

---

## Tracked Timers

### `server-healthcheck.timer`

- **Schedule:** every 30 minutes
- **OnCalendar:** `*:0/30`
- **Service:** `server-healthcheck.service`
- **Action:** runs `server_healthcheck.sh`

### `acme-renew.timer`

- **Schedule:** hourly
- **OnCalendar:** `hourly`
- **Jitter:** `RandomizedDelaySec=300`
- **Service:** `acme-renew.service`
- **Action:** runs `acme_renew.sh` and reloads nginx after successful renewal

### `crowdsec-hub-update.timer`

- **Schedule:** weekly
- **OnCalendar:** `Sun *-*-* 02:10:00`
- **Jitter:** `RandomizedDelaySec=15m`
- **Service:** `crowdsec-hub-update.service`
- **Action:** runs `/usr/local/bin/crowdsec-hub-update.sh`

### `docker-prune.timer`

- **Schedule:** weekly
- **OnCalendar:** `Sun *-*-* 03:50:00`
- **Service:** `docker-prune.service`
- **Action:** runs `docker system prune -af --filter "until=168h"`

### `weekly-reboot.timer`

- **Schedule:** weekly
- **OnCalendar:** `Sun *-*-* 04:00:00`
- **Service:** `weekly-reboot.service`
- **Action:** takes a snapshot first, then schedules a graceful reboot

### `compose-rebuild-ha.timer`

- **Schedule:** weekly
- **OnCalendar:** `Sun *-*-* 04:30:00`
- **Jitter:** `RandomizedDelaySec=900`
- **Service:** `compose-rebuild-ha.service`
- **Action:** snapshots, pulls, rebuilds, and restarts the Home Assistant container

---

## Commands

- List timers:

      systemctl list-timers --all

- Check one timer:

      systemctl status server-healthcheck.timer

- Check the service a timer triggers:

      systemctl status server-healthcheck.service

- Show the installed unit files:

      systemctl cat server-healthcheck.timer
      systemctl cat server-healthcheck.service

- Run a scheduled task immediately:

      sudo systemctl start server-healthcheck.service

- Enable a timer at boot and start it now:

      sudo systemctl enable --now server-healthcheck.timer

- Stop and disable a timer:

      sudo systemctl disable --now server-healthcheck.timer

- Reload unit files after editing them:

      sudo systemctl daemon-reload

- View recent logs for a service:

      journalctl -u server-healthcheck.service -n 100 --no-pager

---

## Notes

- `Persistent=true` means missed runs are caught up after boot for the timers that set it.
- This page only covers tracked systemd timers. Cron jobs and logrotate-triggered scripts are documented in `docs/scripts.md`.
