# devops-sandbox

A self-service platform for spinning up isolated, short-lived sandbox environments.
Users create envs, deploy apps into them, monitor health, simulate outages, and let
them auto-destroy on a TTL. Everything runs on a single Linux VM behind one Nginx
front door. **One `make up` and you're live.**

---

## Architecture

```
                       ┌──────┐                       ┌──────────┐
                       │ User │                       │ Operator │
                       └──┬───┘                       └────┬─────┘
                          │ http://host:8080/<env_id>/     │ http://host:3000
                          │                                │ (Grafana)
                          ▼                                ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  Linux host                                                          │
 │                                                                      │
 │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐           │
 │  │ Control API  │  │ Cleanup      │  │ Health poller    │           │
 │  │ Flask :5000  │  │ daemon (60s) │  │ (every 30 s)     │           │
 │  │ + /metrics   │  └──────┬───────┘  └──────┬───────────┘           │
 │  └──────┬───────┘         │ destroy         │ HTTP /env/health      │
 │         │ subprocess      │                 │                       │
 │         ▼                 ▼                 │                       │
 │   create_env.sh / destroy_env.sh  ┌─────────▼───────────────┐       │
 │   simulate_outage.sh              │ envs/*.json (state)     │       │
 │         │                         └─────────────────────────┘       │
 │         ▼                                                            │
 │  ┌────────────────────────────────────────────────────────────────┐  │
 │  │ Docker daemon                                                  │  │
 │  │                                                                │  │
 │  │  ┌──────────┐  ┌────────────┐  ┌────────────┐                  │  │
 │  │  │  Nginx   │─▶│ env-a1b2c3 │  │ env-d4e5f6 │                  │  │
 │  │  │ :80→8080 │  │ -app :5000 │  │ -app :5000 │                  │  │
 │  │  │          │  │ + /metrics │  │ + /metrics │                  │  │
 │  │  └────┬─────┘  └────┬───────┘  └────┬───────┘                  │  │
 │  │       │ platform-net │                │                         │  │
 │  │       ╞══════════════════════════════════╡    (shared)         │  │
 │  │       │              │                  │                       │  │
 │  │       │      env-a1b2c3-net ╞═╡  env-d4e5f6-net ╞═╡             │  │
 │  │       │      (isolation)         (isolation)                    │  │
 │  │       │                                                          │  │
 │  │       ▼ scrape                                                   │  │
 │  │  ┌──────────────┐ ◀─ datasource ── ┌──────────────┐              │  │
 │  │  │ Prometheus   │                  │ Grafana      │              │  │
 │  │  │ :9090        │                  │ :3000        │              │  │
 │  │  │ (docker_sd)  │                  │ (dashboard)  │              │  │
 │  │  └──────────────┘                  └──────────────┘              │  │
 │  └────────────────────────────────────────────────────────────────┘  │
 └─────────────────────────────────────────────────────────────────────┘
```

**Network approach:**
- One **shared** `sandbox-platform-net` connects Nginx to every env's app container, so Nginx can route to them by Docker DNS name.
- Each env also gets its **own** private `sandbox-<env_id>-net`. Containers on different env networks cannot reach each other → isolation.
- `nginx/nginx.conf` includes `conf.d/*.conf`; `create_env.sh` drops a file there per env, `destroy_env.sh` removes it. Both reload Nginx via `docker exec sandbox-nginx nginx -s reload`.

---

## Prerequisites

- Linux (tested on Ubuntu 22.04 / WSL2)
- Docker ≥ 20.10 with Docker Compose v2 (`docker compose`)
- `python3 ≥ 3.10`, `python3-venv`
- `jq`, `openssl`, `curl` (`sudo apt install jq openssl curl`)

---

## Quick start (5 commands)

```bash
git clone <repo>                       # 1. fetch
cd devops-sandbox                      # 2. enter
cp .env.example .env                   # 3. configure (defaults are fine)
make up                                # 4. start Nginx + daemons + API + build image
make create                            # 5. create your first env (prompts for name + TTL)
```

Open the URL printed by `make create` in a browser. That's it.

---

## Full demo walkthrough

```bash
# Bring the platform up
make up

# Create an env named "demo" with a 5-minute TTL
echo -e "demo\n300" | ./platform/create_env.sh demo 300
# Output:
#   ID:     env-a1b2c3
#   URL:    http://localhost:8080/env-a1b2c3/
#   TTL:    300s

# Hit the env
curl http://localhost:8080/env-a1b2c3/
curl http://localhost:8080/env-a1b2c3/health

# Watch live health checks accumulate (poller runs every 30s)
make health

# Simulate a crash — container is killed
make simulate ENV=env-a1b2c3 MODE=crash
# Within 90s the poller marks it DEGRADED (after 3 failed probes)
make health

# Recover
make simulate ENV=env-a1b2c3 MODE=recover
make health    # status will flip back to "running"

# Other failure modes
make simulate ENV=env-a1b2c3 MODE=pause
make simulate ENV=env-a1b2c3 MODE=recover
make simulate ENV=env-a1b2c3 MODE=network
make simulate ENV=env-a1b2c3 MODE=recover

# Tail the env's app logs (log shipper writes to logs/<id>/app.log)
make logs ENV=env-a1b2c3

# Inspect via the API
curl -s http://localhost:5000/envs | jq
curl -s http://localhost:5000/envs/env-a1b2c3/health | jq

# Destroy manually
make destroy ENV=env-a1b2c3

# …or just wait — the cleanup daemon will destroy it once `now > created_at + ttl`.
# Every cleanup action is timestamped in logs/cleanup.log.

# Shut everything down
make down
```

---

## Monitoring (Prometheus + Grafana)

`make up` also starts Prometheus and Grafana — the brief's "optional but earns extra credit" features.

| Component | URL | Purpose |
|---|---|---|
| Prometheus | http://localhost:9090 | Scrapes env containers via Docker service discovery (`label=sandbox.role=app`) + the Control API. No per-env config edits. |
| Grafana    | http://localhost:3000 | Pre-provisioned dashboard "Sandbox Platform Overview" — request rate, p95 latency, degraded count, TTL remaining. Anonymous admin (no login). |

Exported metrics:
- `flask_http_request_total{env_id, method, status, path}` — per-env request counter (from the demo app).
- `flask_http_request_duration_seconds_bucket{env_id, ...}` — per-env latency histogram.
- `sandbox_envs_total{status}` — count of envs by status (running/degraded), from the Control API.
- `sandbox_env_consecutive_failures{env_id, name}` — failed-probe counter.
- `sandbox_env_ttl_remaining_seconds{env_id, name}` — countdown to auto-destroy.

After `make up`, open Grafana at http://localhost:3000 → Dashboards → Sandbox → "Sandbox Platform Overview." Create an env and watch it appear in the dashboard within ~30 seconds (one Prometheus scrape cycle).

## Control API endpoints

Base URL `http://localhost:5000`.

| Method | Path                       | Body                | Returns |
|--------|----------------------------|---------------------|---------|
| POST   | `/envs`                    | `{name, ttl?}`      | env_id, output |
| GET    | `/envs`                    | —                   | list + `ttl_remaining` per env |
| DELETE | `/envs/<id>`               | —                   | `{deleted: true}` |
| GET    | `/envs/<id>/logs`          | —                   | last 100 lines of app.log |
| GET    | `/envs/<id>/health`        | —                   | last 10 health checks + current status |
| POST   | `/envs/<id>/outage`        | `{mode: "crash"}`   | output of simulator |

---

## Make targets

| Target | What it does |
|---|---|
| `make build`              | Build the demo-app Docker image |
| `make up`                 | Start Nginx + cleanup daemon + health poller + Control API |
| `make down`               | Destroy all envs, stop daemons, stop Nginx |
| `make create`             | Prompt for name + TTL, create env |
| `make destroy ENV=...`    | Destroy one env |
| `make list`               | List active envs |
| `make logs ENV=...`       | Tail last 100 lines of an env's app log |
| `make health`             | Show health status of every env |
| `make simulate ENV=... MODE=crash\|pause\|network\|recover\|stress` | Trigger an outage |
| `make clean`              | `make down` + wipe all state, logs, archives, nginx configs |

---

## Repo layout

```
devops-sandbox/
├── docker-compose.yml       # Nginx service (long-running platform component)
├── Makefile                 # all operations gated behind `make`
├── requirements.txt         # Flask (for API + poller)
├── .env / .env.example      # ports, TTL default, image name, network name
├── platform/
│   ├── lib.sh               # shared bash helpers (atomic writes, reload, guards)
│   ├── create_env.sh        # spin up an env (id, network, container, route, state)
│   ├── destroy_env.sh       # tear it all down (stop, rm, archive, delete state)
│   ├── cleanup_daemon.sh    # TTL-based auto destroyer (nohup'd by `make up`)
│   ├── simulate_outage.sh   # crash | pause | network | recover | stress
│   └── api.py               # Flask Control API
├── monitor/
│   └── health_poller.py     # 30 s loop, hits /health, flags DEGRADED at 3 fails
├── nginx/
│   ├── nginx.conf           # main config; includes conf.d/*.conf
│   └── conf.d/              # per-env routes — written by create, removed by destroy
├── demo-app/                # the Flask app deployed into each env
└── logs/, envs/             # runtime (gitignored except .gitkeep)
```

---

## Known limitations

- **Single host only.** No clustering, no multi-node — fine for a sandbox.
- **No auth on the Control API.** Anyone on the host can create/destroy envs. Add a token in `.env` and a `before_request` hook for production.
- **Log shipping uses Approach A** (one `docker logs -f` per env). At 100+ envs this is wasteful — switch to a Fluentd/Loki sidecar.
- **`make down` removes Nginx**, which means new envs created without the platform running won't have an Nginx route (their config files sit in `conf.d/` waiting). Bring the platform back up and they're routable again.
- **Health poller probes via Nginx**, not directly. If Nginx is down, every env will be marked degraded — but that's correct: from a user's POV, no Nginx == no service.
- **PID reuse** is theoretically possible on log-shipper kill. In practice with 6-digit Linux PIDs it's not a concern at sandbox scale.
- **GitHub Actions CI** (the other "optional extra") is not included.
