#!/usr/bin/env python3
"""Poll /health on every active sandbox env, every 30 seconds.

Writes results to logs/<env_id>/health.log in tab-separated form:
    <iso_timestamp>\t<http_status>\t<latency_ms>ms

After 3 consecutive failures (non-2xx or connection error), updates the
env's state file with status="degraded" and logs a warning.
"""

import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "envs"
LOGS = ROOT / "logs"

POLL_INTERVAL = 30
REQUEST_TIMEOUT = 5


def load_env_file():
    cfg = {}
    p = ROOT / ".env"
    if not p.exists():
        return cfg
    with open(p) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, _, v = line.partition("=")
            cfg[k] = v
    return cfg


CFG = load_env_file()
NGINX_PORT = CFG.get("NGINX_HOST_PORT", "8080")


def update_state(path: pathlib.Path, mutator):
    with open(path) as f:
        state = json.load(f)
    mutator(state)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    tmp.replace(path)


def probe(env_id):
    url = f"http://localhost:{NGINX_PORT}/{env_id}/health"
    start = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        status = 0
    latency_ms = int((time.monotonic() - start) * 1000)
    return status, latency_ms


def tick():
    for state_file in sorted(ENVS.glob("*.json")):
        try:
            with open(state_file) as f:
                state = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        env_id = state["id"]
        status, latency_ms = probe(env_id)
        ts_iso = datetime.now(timezone.utc).isoformat()

        log_dir = LOGS / env_id
        log_dir.mkdir(parents=True, exist_ok=True)
        with open(log_dir / "health.log", "a") as f:
            f.write(f"{ts_iso}\t{status}\t{latency_ms}ms\n")

        ok = 200 <= status < 300

        def mutator(s, ok=ok):
            if ok:
                s["consecutive_failures"] = 0
                if s.get("status") == "degraded":
                    s["status"] = "running"
                    print(f"[INFO] {s['id']} recovered → running", flush=True)
            else:
                s["consecutive_failures"] = s.get("consecutive_failures", 0) + 1
                if s["consecutive_failures"] >= 3 and s.get("status") != "degraded":
                    s["status"] = "degraded"
                    print(f"[WARN] {s['id']} DEGRADED after {s['consecutive_failures']} failures", flush=True)

        try:
            update_state(state_file, mutator)
        except Exception as e:
            print(f"[ERR] state update failed for {env_id}: {e}", file=sys.stderr, flush=True)


def main():
    print(f"[{datetime.now(timezone.utc).isoformat()}] health poller started (interval={POLL_INTERVAL}s)", flush=True)
    while True:
        try:
            tick()
        except Exception as e:
            print(f"[ERR] tick failed: {e}", file=sys.stderr, flush=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
