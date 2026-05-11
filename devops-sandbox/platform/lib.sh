#!/usr/bin/env bash
# Shared helpers sourced by every script in platform/.
# Never executed directly — always `source` it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
set +a

LOG_DIR="$ROOT_DIR/logs"
ENVS_DIR="$ROOT_DIR/envs"
NGINX_CONFD="$ROOT_DIR/nginx/conf.d"
NGINX_CONTAINER="${NGINX_CONTAINER:-sandbox-nginx}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

state_file() { echo "$ENVS_DIR/$1.json"; }

atomic_write() {
  local target=$1
  local tmp
  tmp=$(mktemp "${target}.XXXXXX")
  cat > "$tmp"
  mv "$tmp" "$target"
}

update_state() {
  local id=$1 expr=$2
  local f
  f=$(state_file "$id")
  [[ -f "$f" ]] || return 1
  local tmp
  tmp=$(mktemp "${f}.XXXXXX")
  jq "$expr" "$f" > "$tmp"
  mv "$tmp" "$f"
}

reload_nginx() {
  if docker ps --filter "name=^${NGINX_CONTAINER}$" --filter status=running -q | grep -q .; then
    docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null 2>&1 || true
  fi
}

require_cmd() {
  local missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Error: missing commands: ${missing[*]}" >&2
    exit 1
  fi
}

is_protected_container() {
  local name=$1
  [[ "$name" == "$NGINX_CONTAINER" ]] && return 0
  [[ "$name" == sandbox-prometheus ]] && return 0
  [[ "$name" == sandbox-grafana ]] && return 0
  [[ "$name" == *"cleanup"* ]] && return 0
  [[ "$name" == *"daemon"* ]] && return 0
  return 1
}
