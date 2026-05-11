#!/usr/bin/env bash
# Destroy a sandbox env: stop containers, remove network, unregister Nginx, archive logs.
# Usage: destroy_env.sh <env_id>

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker jq

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env_id>" >&2
  exit 1
fi

STATE_FILE=$(state_file "$ENV_ID")
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: no state file for $ENV_ID" >&2
  exit 1
fi

CONTAINER_NAME=$(jq -r .container_name "$STATE_FILE")
NETWORK_NAME=$(jq -r .network "$STATE_FILE")
LOG_PID=$(jq -r '.log_pid // 0' "$STATE_FILE")

if is_protected_container "$CONTAINER_NAME"; then
  echo "Error: refusing to destroy protected container $CONTAINER_NAME" >&2
  exit 1
fi

# 1. Kill log shipper first so the docker-logs pipe closes cleanly.
if [[ "$LOG_PID" -gt 0 ]] && kill -0 "$LOG_PID" 2>/dev/null; then
  kill "$LOG_PID" 2>/dev/null || true
fi

# 2. Stop & remove every container labeled for this env.
#    (Normally just one — but the label-driven query is the brief's contract.)
mapfile -t CONTAINERS < <(docker ps -aq --filter "label=sandbox.env=${ENV_ID}")
for c in "${CONTAINERS[@]:-}"; do
  [[ -z "$c" ]] && continue
  docker stop "$c" >/dev/null 2>&1 || true
  docker rm   "$c" >/dev/null 2>&1 || true
done

# 3. Remove the per-env network.
docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true

# 4. Unregister Nginx route, then reload.
NGINX_CONF="$NGINX_CONFD/${ENV_ID}.conf"
rm -f "$NGINX_CONF"
reload_nginx

# 5. Archive logs.
ARCHIVE_DIR="$LOG_DIR/archived/$ENV_ID"
mkdir -p "$(dirname "$ARCHIVE_DIR")"
if [[ -d "$LOG_DIR/$ENV_ID" ]]; then
  rm -rf "$ARCHIVE_DIR"
  mv "$LOG_DIR/$ENV_ID" "$ARCHIVE_DIR"
fi

# 6. Delete the state file last — once it's gone the env is officially destroyed.
rm -f "$STATE_FILE"

echo "Env destroyed: $ENV_ID (logs archived to $ARCHIVE_DIR)"
