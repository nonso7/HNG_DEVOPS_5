#!/usr/bin/env bash
# Background loop: every 60s, destroy any env whose TTL has elapsed.
# Started via `make up` with nohup; stopped via `make down` (pkill).

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker jq

mkdir -p "$LOG_DIR"
CLEANUP_LOG="$LOG_DIR/cleanup.log"

log() { echo "[$(ts)] $*" >> "$CLEANUP_LOG"; }

trap 'log "cleanup daemon stopping (PID $$)"; exit 0' INT TERM

log "cleanup daemon started (PID $$)"

while true; do
  shopt -s nullglob
  for state in "$ENVS_DIR"/*.json; do
    id=$(jq -r .id "$state" 2>/dev/null || true)
    created=$(jq -r .created_at "$state" 2>/dev/null || true)
    ttl=$(jq -r .ttl "$state" 2>/dev/null || true)
    [[ -z "$id" || -z "$created" || -z "$ttl" ]] && continue

    created_epoch=$(date -u -d "$created" +%s 2>/dev/null || echo 0)
    now_epoch=$(date -u +%s)
    age=$(( now_epoch - created_epoch ))

    if (( age > ttl )); then
      log "expiring $id (age=${age}s > ttl=${ttl}s)"
      if "$SCRIPT_DIR/destroy_env.sh" "$id" >> "$CLEANUP_LOG" 2>&1; then
        log "expired $id OK"
      else
        log "FAILED to expire $id"
      fi
    fi
  done
  shopt -u nullglob
  sleep 60
done
