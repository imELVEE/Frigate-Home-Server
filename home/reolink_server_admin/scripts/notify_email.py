#!/usr/bin/env python3
import os
import smtplib
import sys
from email.message import EmailMessage
from pathlib import Path


def load_env_file(path: str) -> None:
    """Minimal .env loader: KEY=VALUE per line, ignores comments/empties."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.strip()
            val = val.strip()
            if key and key not in os.environ:
                os.environ[key] = val

HOME_DIR = Path(__file__).resolve().parent.parent

# Load defaults from ~/secrets/scripts.env unless already set in environment
load_env_file(str(HOME_DIR / "secrets" / "scripts.env"))

SMTP_SERVER = os.environ.get("EMAIL_SMTP_SERVER")
SMTP_PORT = os.environ.get("EMAIL_SMTP_PORT")
SMTP_USER = os.environ.get("EMAIL_USER")
SMTP_PASS = os.environ.get("EMAIL_PASSWORD")
SMTP_FROM = os.environ.get("EMAIL_FROM") or SMTP_USER
SMTP_TO_RAW = os.environ.get("EMAIL_TO", "")

if not all([SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM]):
    print("Email settings incomplete. Set EMAIL_SMTP_SERVER/EMAIL_SMTP_PORT/EMAIL_USER/EMAIL_PASSWORD/EMAIL_FROM", file=sys.stderr)
    sys.exit(1)

subject = sys.argv[1] if len(sys.argv) > 1 else "Test: notifier"
body = sys.argv[2] if len(sys.argv) > 2 else "This is a test email from your HA stack notifier."

msg = EmailMessage()
msg["Subject"] = subject
msg["From"] = SMTP_FROM
msg.set_content(body)

# Support comma-separated recipients in EMAIL_TO
recipients = [addr.strip() for addr in SMTP_TO_RAW.split(",") if addr.strip()]
if not recipients:
    print("No recipients defined; set EMAIL_TO", file=sys.stderr)
    sys.exit(1)
msg["To"] = ", ".join(recipients)

with smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, timeout=20) as server:
    server.login(SMTP_USER, SMTP_PASS)
    server.send_message(msg, from_addr=SMTP_FROM, to_addrs=recipients)

print("sent ok")
