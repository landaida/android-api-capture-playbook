#!/usr/bin/env python3
"""Replay a captured API call with plain HTTP, no emulator needed.

Workflow: capture the call in mitmproxy, identify which headers actually matter (usually
Authorization, a client-version header, and sometimes a device/session id), then reproduce it here.
Remove headers one at a time until the call breaks; keep only the minimal set.

Configuration comes from the environment or a .env file (see .env.example):
    API_BASE, API_PATH, AUTH_TOKEN, USER_AGENT

Usage:
    python3 examples/replay_request.py [--param key=value ...]

Requires: pip install requests
"""
import argparse
import json
import os
import sys
from pathlib import Path

import requests


def load_env(path: Path) -> None:
    """Minimal .env loader (KEY=VALUE per line, # comments); does not override real env vars."""
    if not path.is_file():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def main() -> int:
    load_env(Path(__file__).resolve().parent.parent / ".env")
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--param", action="append", default=[], metavar="K=V", help="query parameter")
    args = ap.parse_args()

    base = os.environ.get("API_BASE", "https://api.example.com").rstrip("/")
    path = os.environ.get("API_PATH", "/v1/items")
    token = os.environ.get("AUTH_TOKEN")
    if not token:
        print("AUTH_TOKEN is not set (see .env.example)", file=sys.stderr)
        return 2

    headers = {
        "Authorization": f"Bearer {token}",
        "User-Agent": os.environ.get("USER_AGENT", "ExampleApp/1.0"),
        "Accept": "application/json",
    }
    params = dict(p.split("=", 1) for p in args.param)

    resp = requests.get(base + path, headers=headers, params=params, timeout=30)
    print(f"HTTP {resp.status_code}  {resp.url}", file=sys.stderr)
    if resp.status_code in (401, 403):
        print("Token rejected - it may have expired; capture a fresh one.", file=sys.stderr)
    try:
        print(json.dumps(resp.json(), indent=2, ensure_ascii=False))
    except ValueError:
        print(resp.text[:2000])
    return 0 if resp.ok else 1


if __name__ == "__main__":
    sys.exit(main())
