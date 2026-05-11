# DevOps Sandbox Platform — Makefile
# All actions go through `make` so the reviewer can run anything with one command.

SHELL := /bin/bash
ROOT  := $(shell pwd)

# Load .env into Make's environment.
include .env
export

VENV       := .venv
PYTHON     := $(VENV)/bin/python
PIP        := $(VENV)/bin/pip
DAEMON_PID := .run/cleanup.pid
HEALTH_PID := .run/health.pid
API_PID    := .run/api.pid

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build            build the demo app image"
	@echo "  up               start nginx + cleanup daemon + health poller + API"
	@echo "  down             stop everything, destroy all envs"
	@echo "  create           create a new env (prompts for name + ttl)"
	@echo "  destroy ENV=...  destroy a specific env"
	@echo "  list             list active envs"
	@echo "  logs ENV=...     tail an env's app.log"
	@echo "  health           show health status of every env"
	@echo "  simulate ENV=... MODE=...   trigger an outage"
	@echo "  clean            wipe all state, logs, archives"

# ---------- setup ----------

$(VENV)/.installed: requirements.txt
	python3 -m venv $(VENV)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt
	touch $@

.PHONY: build
build:
	docker build -t $(DEMO_APP_IMAGE) ./demo-app

# ---------- lifecycle ----------

.PHONY: up
up: $(VENV)/.installed build
	@mkdir -p .run logs envs nginx/conf.d
	docker compose up -d
	@nohup ./platform/cleanup_daemon.sh > /dev/null 2>&1 & echo $$! > $(DAEMON_PID)
	@nohup $(PYTHON) monitor/health_poller.py >> logs/health_poller.log 2>&1 & echo $$! > $(HEALTH_PID)
	@nohup $(PYTHON) platform/api.py          >> logs/api.log            2>&1 & echo $$! > $(API_PID)
	@sleep 1
	@echo
	@echo "Platform UP:"
	@echo "  Nginx        http://localhost:$(NGINX_HOST_PORT)/"
	@echo "  Control API  http://localhost:$(API_HOST_PORT)/health"
	@echo "  Prometheus   http://localhost:$(PROMETHEUS_HOST_PORT)/"
	@echo "  Grafana      http://localhost:$(GRAFANA_HOST_PORT)/  (anonymous admin)"
	@echo "  PIDs: cleanup=$$(cat $(DAEMON_PID)) health=$$(cat $(HEALTH_PID)) api=$$(cat $(API_PID))"

.PHONY: down
down:
	-@for f in envs/*.json; do [ -f "$$f" ] && ./platform/destroy_env.sh "$$(basename $$f .json)" || true; done
	-@for p in $(DAEMON_PID) $(HEALTH_PID) $(API_PID); do \
	   [ -f "$$p" ] && kill $$(cat $$p) 2>/dev/null; rm -f $$p; \
	 done
	-docker compose down
	@echo "Platform DOWN."

# ---------- env operations ----------

.PHONY: create
create:
	@read -rp "Env name: " name; \
	read -rp "TTL seconds [$(DEFAULT_TTL)]: " ttl; \
	./platform/create_env.sh "$$name" "$${ttl:-$(DEFAULT_TTL)}"

.PHONY: destroy
destroy:
	@test -n "$(ENV)" || { echo "usage: make destroy ENV=env-xxxxxx"; exit 1; }
	./platform/destroy_env.sh "$(ENV)"

.PHONY: list
list:
	@if ls envs/*.json >/dev/null 2>&1; then \
	   for f in envs/*.json; do jq -r '"\(.id)\t\(.name)\t\(.status)\tttl=\(.ttl)s\tcreated=\(.created_at)"' "$$f"; done; \
	 else echo "(no envs)"; fi

.PHONY: logs
logs:
	@test -n "$(ENV)" || { echo "usage: make logs ENV=env-xxxxxx"; exit 1; }
	@tail -n 100 logs/$(ENV)/app.log

.PHONY: health
health:
	@if ls envs/*.json >/dev/null 2>&1; then \
	   for f in envs/*.json; do \
	     id=$$(jq -r .id "$$f"); status=$$(jq -r .status "$$f"); fails=$$(jq -r .consecutive_failures "$$f"); \
	     printf "%-15s status=%-10s fails=%s  last10:\n" "$$id" "$$status" "$$fails"; \
	     [ -f logs/$$id/health.log ] && tail -n 10 logs/$$id/health.log | sed 's/^/   /' || echo "   (no checks yet)"; \
	   done; \
	 else echo "(no envs)"; fi

.PHONY: simulate
simulate:
	@test -n "$(ENV)" -a -n "$(MODE)" || { echo "usage: make simulate ENV=env-xxxxxx MODE=crash|pause|network|recover|stress"; exit 1; }
	./platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

# ---------- cleanup ----------

.PHONY: clean
clean: down
	rm -rf logs/* envs/*.json nginx/conf.d/*.conf .run
	@echo "All state, logs, and archives wiped."
