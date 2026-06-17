FROM ghcr.io/home-assistant/home-assistant:stable

COPY custom_components/frigate/manifest.json /tmp/frigate-manifest.json

RUN python3 - <<'PY'
import json
import subprocess
import sys

with open("/tmp/frigate-manifest.json", encoding="utf-8") as fh:
    requirements = json.load(fh).get("requirements", [])

if requirements:
    subprocess.check_call([sys.executable, "-m", "pip", "install", *requirements])
PY
