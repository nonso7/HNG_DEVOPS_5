#!/usr/bin/env python3
"""Control API for the DevOps sandbox platform.

Wraps the shell scripts in platform/ behind 6 HTTP endpoints:

    POST   /envs              create env
    GET    /envs              list active envs + TTL remaining
    DELETE /envs/<id>         destroy env
    GET    /envs/<id>/logs    last 100 lines of app.log
    GET    /envs/<id>/health  last 10 health check results
    POST   /envs/<id>/outage  trigger simulation (body: {"mode": "..."})
"""

import json
import os
import pathlib
import re
import subprocess
from datetime import datetime, timezone

from flask import Flask, abort, jsonify, request
from prometheus_client.core import REGISTRY, GaugeMetricFamily
from prometheus_flask_exporter import PrometheusMetrics

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENVS = ROOT / "envs"
LOGS = ROOT / "logs"
PLATFORM = ROOT / "platform"

ENV_ID_RE = re.compile(r"^env-[a-f0-9]{6}$")
NAME_RE = re.compile(r"^[a-z0-9-]{1,32}$")
MODE_RE = re.compile(r"^(crash|pause|network|recover|stress)$")

app = Flask(__name__)
metrics = PrometheusMetrics(app, static_labels={"service": "control-api"})


class EnvsCollector:
    """Computed at scrape time by reading every state file in envs/."""

    def collect(self):
        totals = GaugeMetricFamily(
            "sandbox_envs_total", "Active sandbox envs", labels=["status"]
        )
        failures = GaugeMetricFamily(
            "sandbox_env_consecutive_failures",
            "Consecutive failed health probes",
            labels=["env_id", "name"],
        )
        ttl_remaining = GaugeMetricFamily(
            "sandbox_env_ttl_remaining_seconds",
            "Seconds until the env auto-destroys",
            labels=["env_id", "name"],
        )
        counts = {"running": 0, "degraded": 0}
        now = datetime.now(timezone.utc).timestamp()
        for sf in ENVS.glob("*.json"):
            try:
                with open(sf) as fh:
                    s = json.load(fh)
            except (json.JSONDecodeError, OSError):
                continue
            status = s.get("status", "running")
            counts[status] = counts.get(status, 0) + 1
            failures.add_metric(
                [s["id"], s.get("name", "")],
                s.get("consecutive_failures", 0),
            )
            try:
                created = datetime.fromisoformat(
                    s["created_at"].replace("Z", "+00:00")
                ).timestamp()
                remaining = max(0, s["ttl"] - (now - created))
            except Exception:
                remaining = 0
            ttl_remaining.add_metric([s["id"], s.get("name", "")], remaining)
        for status, n in counts.items():
            totals.add_metric([status], n)
        yield totals
        yield failures
        yield ttl_remaining


REGISTRY.register(EnvsCollector())


def run_script(name, *args, timeout=120):
    return subprocess.run(
        [str(PLATFORM / name), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def load_state(env_id):
    f = ENVS / f"{env_id}.json"
    if not f.exists():
        abort(404, description=f"env {env_id} not found")
    with open(f) as fh:
        return json.load(fh)


@app.errorhandler(400)
@app.errorhandler(404)
def _err(e):
    return jsonify(error=e.description), e.code


@app.route("/health", methods=["GET"])
def api_health():
    return jsonify(status="ok", service="control-api")


@app.route("/envs", methods=["POST"])
def create_env():
    body = request.get_json(force=True, silent=True) or {}
    name = body.get("name", "")
    ttl = body.get("ttl")
    if not NAME_RE.match(name):
        abort(400, description="name must match ^[a-z0-9-]{1,32}$")
    args = [name]
    if ttl is not None:
        try:
            args.append(str(int(ttl)))
        except (TypeError, ValueError):
            abort(400, description="ttl must be an integer")
    r = run_script("create_env.sh", *args)
    if r.returncode != 0:
        return jsonify(error="create failed", stderr=r.stderr, stdout=r.stdout), 500
    m = re.search(r"ID:\s*(env-[a-f0-9]+)", r.stdout)
    env_id = m.group(1) if m else None
    return jsonify(env_id=env_id, output=r.stdout), 201


@app.route("/envs", methods=["GET"])
def list_envs():
    out = []
    now = datetime.now(timezone.utc).timestamp()
    for sf in sorted(ENVS.glob("*.json")):
        try:
            with open(sf) as fh:
                s = json.load(fh)
        except (json.JSONDecodeError, OSError):
            continue
        created = datetime.fromisoformat(s["created_at"].replace("Z", "+00:00")).timestamp()
        s["ttl_remaining"] = max(0, int(s["ttl"] - (now - created)))
        out.append(s)
    return jsonify(envs=out)


@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id):
    if not ENV_ID_RE.match(env_id):
        abort(400, description="invalid env_id")
    r = run_script("destroy_env.sh", env_id)
    if r.returncode != 0:
        return jsonify(error="destroy failed", stderr=r.stderr, stdout=r.stdout), 500
    return jsonify(env_id=env_id, deleted=True, output=r.stdout)


@app.route("/envs/<env_id>/logs", methods=["GET"])
def env_logs(env_id):
    if not ENV_ID_RE.match(env_id):
        abort(400, description="invalid env_id")
    f = LOGS / env_id / "app.log"
    if not f.exists():
        return jsonify(env_id=env_id, lines=[])
    with open(f) as fh:
        lines = fh.readlines()[-100:]
    return jsonify(env_id=env_id, lines=[l.rstrip("\n") for l in lines])


@app.route("/envs/<env_id>/health", methods=["GET"])
def env_health(env_id):
    if not ENV_ID_RE.match(env_id):
        abort(400, description="invalid env_id")
    state = load_state(env_id)
    f = LOGS / env_id / "health.log"
    checks = []
    if f.exists():
        with open(f) as fh:
            for line in fh.readlines()[-10:]:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    checks.append({
                        "timestamp": parts[0],
                        "status": int(parts[1]) if parts[1].isdigit() else 0,
                        "latency": parts[2],
                    })
    return jsonify(env_id=env_id, status=state.get("status"), checks=checks)


@app.route("/envs/<env_id>/outage", methods=["POST"])
def env_outage(env_id):
    if not ENV_ID_RE.match(env_id):
        abort(400, description="invalid env_id")
    body = request.get_json(force=True, silent=True) or {}
    mode = body.get("mode", "")
    if not MODE_RE.match(mode):
        abort(400, description="mode must be one of crash|pause|network|recover|stress")
    r = run_script("simulate_outage.sh", "--env", env_id, "--mode", mode)
    if r.returncode != 0:
        return jsonify(error="simulate failed", stderr=r.stderr, stdout=r.stdout), 500
    return jsonify(env_id=env_id, mode=mode, output=r.stdout)


if __name__ == "__main__":
    port = int(os.environ.get("API_HOST_PORT", 5000))
    app.run(host="0.0.0.0", port=port)
