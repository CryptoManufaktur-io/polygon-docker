#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local Bor RPC URL (default: http://127.0.0.1:${BOR_RPC_PORT:-8545})
  --public-rpc URL         Public/reference Bor RPC URL (required)
  --block-lag N            Acceptable lag in blocks (default: 10)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Examples:
  ./scripts/check_sync.sh --public-rpc https://polygon-rpc.com
  ./scripts/check_sync.sh --compose-service bor --public-rpc https://polygon-rpc.com
  CONTAINER=bor-1 PUBLIC_RPC=https://polygon-rpc.com ./scripts/check_sync.sh
USAGE
}

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-10}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:-1}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      export "${key}=${val}"
    fi
  done < "$file"
}

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ENV_FILE="${args[$((i+1))]:-}"
  fi
done

if [[ -n "${ENV_FILE:-}" ]]; then
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) PUBLIC_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) INSTALL_TOOLS="0"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${BOR_RPC_PORT:-8545}}"
PUBLIC_RPC="${PUBLIC_RPC:-}"

resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ docker not found; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  else
    echo "❌ docker compose not available; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
}

jq_eval() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" jq -r "$1"
  else
    jq -r "$1"
  fi
}

http_post_json() {
  local url="$1"
  local payload="$2"
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" sh -c "printf '%s' '$payload' | curl -sS -H 'Content-Type: application/json' -d @- '$url'"
  else
    printf '%s' "$payload" | curl -sS -H 'Content-Type: application/json' -d @- "$url"
  fi
}

rpc_call() {
  local url="$1"
  local method="$2"
  local params="$3"
  local payload
  payload=$(printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$params")
  http_post_json "$url" "$payload"
}

hex_to_dec() {
  local value="$1"
  if [[ "$value" =~ ^0x ]]; then
    printf "%d" "$((16#${value#0x}))"
  else
    printf "%d" "$value"
  fi
}

resolve_container

if [[ -z "$PUBLIC_RPC" ]]; then
  echo "❌ PUBLIC_RPC is required. Use --public-rpc or set PUBLIC_RPC."
  exit 2
fi

if [[ -n "$CONTAINER" ]]; then
  if [[ "$INSTALL_TOOLS" == "1" ]]; then
    echo "==> Ensuring curl and jq are installed inside container"
    docker exec -u root "$CONTAINER" sh -c '
    set -e
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      exit 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl jq ca-certificates
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl jq ca-certificates
    else
      echo "Unsupported base image. No apt-get or apk found."
      exit 1
    fi
    '
  fi
else
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "❌ curl and jq are required on the host when no --container is set."
    exit 2
  fi
fi

echo "==> Querying Bor JSON-RPC"

local_block="$(rpc_call "$LOCAL_RPC" "eth_getBlockByNumber" '["latest", false]')"
public_block="$(rpc_call "$PUBLIC_RPC" "eth_getBlockByNumber" '["latest", false]')"
local_syncing="$(rpc_call "$LOCAL_RPC" "eth_syncing" '[]')"

local_num="$(echo "$local_block" | jq_eval '.result.number // .number')"
local_hash="$(echo "$local_block" | jq_eval '.result.hash // .hash')"
public_num="$(echo "$public_block" | jq_eval '.result.number // .number')"
public_hash="$(echo "$public_block" | jq_eval '.result.hash // .hash')"

if [[ -z "$local_num" || "$local_num" == "null" ]]; then
  echo "❌ Local RPC missing block number. Raw response:"
  echo "$local_block"
  exit 3
fi

if [[ -z "$public_num" || "$public_num" == "null" ]]; then
  echo "❌ Public RPC missing block number. Raw response:"
  echo "$public_block"
  exit 4
fi

syncing_result="$(echo "$local_syncing" | jq_eval '.result')"
if [[ "$syncing_result" == "false" || "$syncing_result" == "null" ]]; then
  syncing_flag="false"
else
  syncing_flag="true"
fi

local_height_dec="$(hex_to_dec "$local_num")"
public_height_dec="$(hex_to_dec "$public_num")"
lag="$((public_height_dec - local_height_dec))"

echo "Local  height: $local_height_dec"
echo "Public height: $public_height_dec"
echo "Lag:          $lag blocks (threshold: $BLOCK_LAG_THRESHOLD)"
echo "Syncing:      $syncing_flag"
echo

echo "Local  hash: $local_hash"
echo "Public hash: $public_hash"
echo

if [[ "$local_num" == "$public_num" && "$local_hash" == "$public_hash" ]]; then
  echo "✅ Node is in sync (height and hash match)"
  exit 0
fi

if [[ "$syncing_flag" == "true" ]]; then
  echo "⚠️  Node reports eth_syncing. Still syncing."
  exit 1
fi

if (( lag > BLOCK_LAG_THRESHOLD )); then
  echo "⚠️  Heights differ beyond threshold. Still syncing."
  exit 1
fi

if [[ "$local_num" == "$public_num" && "$local_hash" != "$public_hash" ]]; then
  echo "❌ Heights match but hashes differ. Possible fork or divergence."
  exit 2
fi

if (( lag < 0 )); then
  echo "⚠️  Local height is ahead of public endpoint. Public may be lagging."
  exit 0
fi

echo "⚠️  Heights differ but within threshold. Likely normal propagation lag."
exit 0
