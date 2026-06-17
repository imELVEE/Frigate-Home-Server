#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from collections import Counter
from datetime import datetime
from typing import Any, Dict

LOG_PATH = sys.argv[1] if len(sys.argv) > 1 else None
if not LOG_PATH:
    print("Usage: modsec_alert.py <audit_log_file>", file=sys.stderr)
    sys.exit(1)

if not os.path.exists(LOG_PATH):
    sys.exit(0)

counts: Counter[str] = Counter()
examples = []
total = 0

with open(LOG_PATH, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            data: Dict[str, Any] = json.loads(line)
        except Exception:
            continue
        messages = data.get("messages", []) or []
        if not messages:
            continue
        for msg in messages:
            details = msg.get("details", {})
            sev_raw = details.get("severity")
            try:
                sev = int(sev_raw)
            except Exception:
                continue
            if sev > 2:
                continue
            rule_id = details.get("ruleId", "unknown")
            counts[rule_id] += 1
            total += 1
            if len(examples) < 5:
                tx = data.get("transaction", {})
                examples.append(
                    {
                        "time": tx.get("time_stamp"),
                        "client": tx.get("client_ip"),
                        "host": tx.get("request", {}).get("headers", {}).get("Host"),
                        "uri": tx.get("request", {}).get("uri"),
                        "rule": rule_id,
                        "msg": msg.get("message"),
                        "severity": sev,
                    }
                )

if total == 0:
    sys.exit(0)

subject = f"WAF alert: {total} high-severity hits in modsec log"
lines = [
    f"Log file: {LOG_PATH}",
    f"Detected {total} events with severity 1-2 (block-worthy).",
    "",
    "Rule counts:",
]
for rule_id, count in counts.most_common():
    lines.append(f"- {rule_id}: {count} hit(s)")

if examples:
    lines.append("")
    lines.append("Sample events:")
    for ex in examples:
        lines.append(
            f"- {ex['time']} client={ex['client']} host={ex['host']} uri={ex['uri']} "
            f"rule={ex['rule']} ({ex['msg']}) severity={ex['severity']}"
        )

body = "\n".join(lines)

notify_script = "/home/reolink_server_admin/scripts/notify_email.py"
try:
    subprocess.run([notify_script, subject, body], check=True)
except Exception as exc:
    print(f"modsec_alert: failed to send email: {exc}", file=sys.stderr)
    sys.exit(1)
