#!/usr/bin/env bash
# Simulate failure modes against a sandbox env.
# Usage: simulate_outage.sh --env <env_id> --mode <crash|pause|network|recover|stress>

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker jq

ENV_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)  ENV_ID="$2"; shift 2 ;;
    --mode) MODE="$2";   shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>" >&2
  exit 1
fi

STATE_FILE=$(state_file "$ENV_ID")
[[ -f "$STATE_FILE" ]] || { echo "Error: no state file for $ENV_ID" >&2; exit 1; }

CONTAINER_NAME=$(jq -r .container_name "$STATE_FILE")
CONTAINER_ID=$(jq -r .container_id "$STATE_FILE")

# GUARD — never simulate against platform infrastructure.
if is_protected_container "$CONTAINER_NAME"; then
  echo "Error: refusing to simulate against protected container $CONTAINER_NAME" >&2
  exit 1
fi

case "$MODE" in
  crash)
    echo "Crashing $CONTAINER_NAME (SIGKILL)..."
    docker kill "$CONTAINER_NAME" >/dev/null
    ;;

  pause)
    echo "Pausing $CONTAINER_NAME..."
    docker pause "$CONTAINER_NAME" >/dev/null
    ;;

  network)
    echo "Disconnecting $CONTAINER_NAME from platform network..."
    docker network disconnect "$PLATFORM_NETWORK" "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ;;

  recover)
    echo "Recovering $CONTAINER_NAME..."
    # Try each recovery action; ignore failures (some may not apply).
    docker unpause "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker start   "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker network connect "$PLATFORM_NETWORK" "$CONTAINER_NAME" >/dev/null 2>&1 || true

    # If container was crashed and restarted, the log-shipper PID is dead.
    # Spawn a new one.
    OLD_PID=$(jq -r '.log_pid // 0' "$STATE_FILE")
    if ! kill -0 "$OLD_PID" 2>/dev/null; then
      mkdir -p "$LOG_DIR/$ENV_ID"
      nohup docker logs -f "$CONTAINER_ID" >> "$LOG_DIR/$ENV_ID/app.log" 2>&1 &
      NEW_PID=$!
      disown "$NEW_PID" 2>/dev/null || true
      update_state "$ENV_ID" ".log_pid = $NEW_PID"
    fi
    update_state "$ENV_ID" '.status = "running" | .consecutive_failures = 0'
    ;;

  stress)
    # Optional — spike CPU inside the container, auto-stop after 30s.
    echo "Stressing $CONTAINER_NAME (CPU spike, 30s)..."
    docker exec -d "$CONTAINER_NAME" sh -c \
      'if command -v stress-ng >/dev/null 2>&1; then
         stress-ng --cpu 2 --timeout 30s
       else
         yes > /dev/null &
         PID=$!
         sleep 30
         kill "$PID" 2>/dev/null || true
       fi'
    ;;

  *)
    echo "Error: unknown mode '$MODE'" >&2
    exit 1
    ;;
esac

echo "Outage '$MODE' applied to $ENV_ID."
