# ACME / Certificates (Dynu DNS-01)

HTTPS needs certificates. ACME is the protocol Let's Encrypt uses to verify domain ownership and issue them. In this setup, `acme.sh` uses DNS-01 with Dynu, so Let's Encrypt checks a TXT record in DNS instead of making an inbound web request. That works well for a home server because you do not need to temporarily open port 80 or 443 just to get a certificate, and it fits naturally with Dynu already providing the hostname.

This section is optional; run it only if you expose nginx externally and want public HTTPS.

---

## Components

- **Client:** `acme.sh`, run from the `neilpang/acme.sh` Docker image
- **Storage:**
  - `ha/acme/` (ACME home)
  - `ha/nginx/ssl/` (deployed `fullchain.pem`/`privkey.pem`)
- **Secrets:** `/etc/acme/dynu.env` (root-only) with:
  - `Dynu_ClientId`
  - `Dynu_Secret`  
  (API keys for Dynu DNS)
  - Example file in the repo: `etc/acme/dynu.env.example`

---

## Initial Issue (Docker Container)

Use separate issue and install steps so the commands match normal `acme.sh` usage.

The commands below do not require `acme.sh` to be installed directly on the host. `docker run --rm ... neilpang/acme.sh ...` starts a temporary container that already contains `acme.sh`, mounts the host certificate folders into that container, runs the ACME command, then removes the container when it exits.

Issue the certificate:

    docker run --rm --env-file /etc/acme/dynu.env \
      -v ~/ha/acme:/acme.sh -v ~/ha/nginx/ssl:/deploy \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh \
        --register-account -m <PRIVATE_ACCOUNT_EMAIL> \
        --server letsencrypt \
        --issue --dns dns_dynu -d <PUBLIC_HOSTNAME> --keylength ec-256'

Install the cert/key into nginx's SSL directory:

    docker run --rm --env-file /etc/acme/dynu.env \
      -v ~/ha/acme:/acme.sh -v ~/ha/nginx/ssl:/deploy \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh \
        --server letsencrypt \
        --ecc \
        --install-cert -d <PUBLIC_HOSTNAME> \
          --fullchain-file /deploy/fullchain.pem \
          --key-file /deploy/privkey.pem'

**What this does:**

- Mounts `ha/acme` into the container as `acme.sh` home.
- Mounts `ha/nginx/ssl` as the deploy directory for certs.
- Uses Dynu API creds from `/etc/acme/dynu.env` to satisfy DNS-01.
- Issues an ECC-256 cert for `<PUBLIC_HOSTNAME>`.
- Installs the resulting `fullchain.pem` and `privkey.pem` directly into the nginx SSL directory.
- Stores the install paths so later `--cron` renewals keep those files updated automatically.

After this, nginx can be configured to serve HTTPS with these files.

---

## Renewal Automation

### Systemd Service

Certificate renewals happen through `/etc/systemd/system/acme-renew.service`. The service starts a temporary `neilpang/acme.sh` container, runs `acme.sh --cron`, then reloads nginx after the command succeeds.

    [Unit]
    Description=Renew Let's Encrypt certs with acme.sh (Dynu DNS)
    Wants=network-online.target docker.service
    After=network-online.target docker.service

    [Service]
    Type=oneshot
    WorkingDirectory=/home/reolink_server_admin/ha
    EnvironmentFile=/etc/acme/dynu.env
    ExecStart=/usr/bin/docker run --rm --env-file /etc/acme/dynu.env \
      -v /home/reolink_server_admin/ha/acme:/acme.sh \
      -v /home/reolink_server_admin/ha/nginx/ssl:/deploy \
      neilpang/acme.sh sh -lc 'acme.sh --home /acme.sh --cron --server letsencrypt'
    ExecStartPost=/home/reolink_server_admin/ha/compose.sh -f /home/reolink_server_admin/ha/docker-compose.yml exec -T nginx /usr/sbin/nginx -s reload
    User=root

- Runs `acme.sh --cron` against Let's Encrypt.
- Uses the cert already installed under `ha/nginx/ssl/`.
- Reloads nginx so it picks up any renewed cert.
- Failure notifications need an explicit shell wrapper or a separate systemd failure handler. Do not append a bare `|| notify...` tail to `ExecStart=`, because systemd does not run plain `ExecStart=` lines through a shell.

### Systemd Timer

`/etc/systemd/system/acme-renew.timer`:

    [Unit]
    Description=Run ACME renew hourly

    [Timer]
    OnCalendar=hourly
    RandomizedDelaySec=300
    Persistent=true

    [Install]
    WantedBy=timers.target

Enable with:

    sudo systemctl enable --now acme-renew.timer

ACME will try once per hour with a small randomized delay.

Note: Let's Encrypt certs are short-lived (usually 90 days), and `acme.sh --cron` only renews when a cert is close enough to expiry. In this setup, the hourly timer is just a check cadence; it does not mean a cert is reissued every hour. I have not yet had this server reach a real near-expiry renewal event, so this renewal path is documented and checked for obvious errors, but not yet proven by time alone.

---

## Potential problems

- Missing `/etc/acme/dynu.env` (mode 600) yields "Dynu client id and secret is not specified." Ensure `Dynu_ClientId`/`Dynu_Secret` are loaded via `EnvironmentFile=`.
- Running `acme.sh` from the wrong working directory or without full paths under systemd leads to `docker: not found`; use absolute `/usr/bin/docker` and `WorkingDirectory=/home/.../ha`.
- ECC installs should use `--ecc` with `--install-cert`, since the cert was issued with `--keylength ec-256`.
- `docker compose exec` under systemd should use `-T` to avoid TTY issues.
- Shell operators like `||` belong in a wrapper script or explicit shell, not directly in a plain `ExecStart=` command.
- If you inline the Docker command instead of using a wrapper script, keep it on one logical `ExecStart=` line (with `\` continuations) and keep reloads in `ExecStartPost`.

---

## Official references

- [`acme.sh` README](https://github.com/acmesh-official/acme.sh)
- [`acme.sh` DNS API wiki (Dynu)](https://github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_dynu)
- [`acme.sh` Docker image docs](https://github.com/acmesh-official/acme.sh/wiki/Run-acme.sh-in-docker)
- [`systemd.service` man page](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)
- [`systemd.timer` man page](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
