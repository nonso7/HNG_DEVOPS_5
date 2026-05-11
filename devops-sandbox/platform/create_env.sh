#!/usr/bin/env bash
# Create a new sandbox environment.
# Usage: create_env.sh <name> [ttl_seconds]

set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_cmd docker jq openssl

NAME="${1:-}"
TTL="${2:-$DEFAULT_TTL}"

if [[ -z "$NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]" >&2
  exit 1
fi
if ! [[ "$NAME" =~ ^[a-z0-9-]{1,32}$ ]]; then
  echo "Error: name must match ^[a-z0-9-]{1,32}$" >&2
  exit 1
fi
if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
  echo "Error: TTL must be a positive integer (seconds)" >&2
  exit 1
fi

ENV_ID="env-$(openssl rand -hex 3)"
CREATED_AT=$(ts)
NETWORK_NAME="sandbox-${ENV_ID}-net"
CONTAINER_NAME="${ENV_ID}-app"
STATE_FILE=$(state_file "$ENV_ID")

mkdir -p "$ENVS_DIR" "$NGINX_CONFD" "$LOG_DIR/$ENV_ID"

# Platform network — shared by Nginx and every env (so Nginx can reach them).
docker network inspect "$PLATFORM_NETWORK" >/dev/null 2>&1 || \
  docker network create "$PLATFORM_NETWORK" >/dev/null

# Per-env network — isolation between envs.
docker network create --label sandbox.env="$ENV_ID" "$NETWORK_NAME" >/dev/null

# Start the demo app on the env's network.
CONTAINER_ID=$(docker run -d \
  --name "$CONTAINER_NAME" \
  --network "$NETWORK_NAME" \
  --label sandbox.env="$ENV_ID" \
  --label sandbox.role=app \
  -e ENV_ID="$ENV_ID" \
  "$DEMO_APP_IMAGE")

# Attach to the platform network so Nginx (on platform-net) can route to it.
docker network connect "$PLATFORM_NETWORK" "$CONTAINER_NAME"

# Nginx route — proxies /<env_id>/ → http://<container_name>:5000/
NGINX_CONF="$NGINX_CONFD/${ENV_ID}.conf"
cat <<EOF | atomic_write "$NGINX_CONF"
location /${ENV_ID}/ {
    proxy_pass http://${CONTAINER_NAME}:5000/;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_read_timeout 30s;
}
EOF
reload_nginx

# Log shipping (Approach A) — docker logs -f appended to a file, PID tracked.
nohup docker logs -f "$CONTAINER_ID" >> "$LOG_DIR/$ENV_ID/app.log" 2>&1 &
LOG_PID=$!
disown "$LOG_PID" 2>/dev/null || true

# State file — atomic write so a half-written JSON never exists on disk.
jq -n \
  --arg id            "$ENV_ID" \
  --arg name          "$NAME" \
  --arg created_at    "$CREATED_AT" \
  --argjson ttl       "$TTL" \
  --arg status        "running" \
  --arg container_id  "$CONTAINER_ID" \
  --arg container_name "$CONTAINER_NAME" \
  --arg network       "$NETWORK_NAME" \
  --argjson log_pid   "$LOG_PID" \
  --argjson failures  0 \
  '{
     id: $id,
     name: $name,
     created_at: $created_at,
     ttl: $ttl,
     status: $status,
     container_id: $container_id,
     container_name: $container_name,
     network: $network,
     log_pid: $log_pid,
     consecutive_failures: $failures
   }' | atomic_write "$STATE_FILE"

ENV_URL="http://localhost:${NGINX_HOST_PORT}/${ENV_ID}/"
echo "Env created:"
echo "  ID:     $ENV_ID"
echo "  Name:   $NAME"
echo "  URL:    $ENV_URL"
echo "  TTL:    ${TTL}s"
echo "  State:  $STATE_FILE"
