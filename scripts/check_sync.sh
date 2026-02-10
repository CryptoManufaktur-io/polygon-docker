#!/usr/bin/env bash
set -euo pipefail

LOCAL_RPC_DEFAULT="http://127.0.0.1:8545"
PUBLIC_RPC_DEFAULT="https://polygon-rpc.com"
BLOCK_LAG_DEFAULT=2

ENV_PUBLIC_RPC="${PUBLIC_RPC:-}"
ENV_PUBLIC_RPC_URL="${PUBLIC_RPC_URL:-}"
ENV_LOCAL_RPC="${LOCAL_RPC:-}"
ENV_LOCAL_RPC_URL="${LOCAL_RPC_URL:-}"
ENV_BLOCK_LAG="${BLOCK_LAG:-}"
ENV_BOR_RPC_PORT="${BOR_RPC_PORT:-}"
ENV_HEIMDALL_BOR_RPC_URL="${HEIMDALL_BOR_RPC_URL:-}"

CLI_PUBLIC_RPC=""
CLI_LOCAL_RPC=""
CLI_BLOCK_LAG=""
CONTAINER=""
COMPOSE_SERVICE=""
ENV_FILE=""
NO_INSTALL=0

FILE_PUBLIC_RPC=""
FILE_PUBLIC_RPC_URL=""
FILE_LOCAL_RPC=""
FILE_LOCAL_RPC_URL=""
FILE_BLOCK_LAG=""
FILE_BOR_RPC_PORT=""
FILE_HEIMDALL_BOR_RPC_URL=""

usage() {
  cat <<'EOF'
Usage: check_sync.sh [options]

Options:
  --compose-service NAME
  --container NAME
  --local-rpc URL
  --public-rpc URL
  --block-lag N
  --env-file PATH
  --no-install
  -h, --help
EOF
}

print_error_and_exit() {
  local message="$1"
  echo "❌ error: ${message}"
  echo
  echo "❌ Final status: error"
  exit 2
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_env_value() {
  local value
  value="$(trim "$1")"
  if [[ "$value" =~ ^\".*\"$ ]]; then
    value="${value:1:-1}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    value="${value:1:-1}"
  fi
  printf '%s' "$value"
}

read_env_value() {
  local var="$1"
  local file="$2"
  awk -v var="$var" '
    /^[ \t]*#/ || /^[ \t]*$/ { next }
    $0 ~ "^[ \t]*(export[ \t]+)?"var"=" {
      sub("^[ \t]*(export[ \t]+)?"var"=", "", $0)
      print $0
      exit
    }
  ' "$file"
}

load_env_file() {
  local file="$1"
  FILE_PUBLIC_RPC="$(normalize_env_value "$(read_env_value "PUBLIC_RPC" "$file")")"
  FILE_PUBLIC_RPC_URL="$(normalize_env_value "$(read_env_value "PUBLIC_RPC_URL" "$file")")"
  FILE_LOCAL_RPC="$(normalize_env_value "$(read_env_value "LOCAL_RPC" "$file")")"
  FILE_LOCAL_RPC_URL="$(normalize_env_value "$(read_env_value "LOCAL_RPC_URL" "$file")")"
  FILE_BLOCK_LAG="$(normalize_env_value "$(read_env_value "BLOCK_LAG" "$file")")"
  FILE_BOR_RPC_PORT="$(normalize_env_value "$(read_env_value "BOR_RPC_PORT" "$file")")"
  FILE_HEIMDALL_BOR_RPC_URL="$(normalize_env_value "$(read_env_value "HEIMDALL_BOR_RPC_URL" "$file")")"
}

resolve_public_rpc() {
  if [[ -n "$CLI_PUBLIC_RPC" ]]; then
    printf '%s' "$CLI_PUBLIC_RPC"
    return
  fi
  if [[ -n "$ENV_PUBLIC_RPC" ]]; then
    printf '%s' "$ENV_PUBLIC_RPC"
    return
  fi
  if [[ -n "$ENV_PUBLIC_RPC_URL" ]]; then
    printf '%s' "$ENV_PUBLIC_RPC_URL"
    return
  fi
  if [[ -n "$FILE_PUBLIC_RPC" ]]; then
    printf '%s' "$FILE_PUBLIC_RPC"
    return
  fi
  if [[ -n "$FILE_PUBLIC_RPC_URL" ]]; then
    printf '%s' "$FILE_PUBLIC_RPC_URL"
    return
  fi
  printf '%s' "$PUBLIC_RPC_DEFAULT"
}

resolve_local_rpc() {
  if [[ -n "$CLI_LOCAL_RPC" ]]; then
    printf '%s' "$CLI_LOCAL_RPC"
    return
  fi
  if [[ -n "$ENV_LOCAL_RPC" ]]; then
    printf '%s' "$ENV_LOCAL_RPC"
    return
  fi
  if [[ -n "$ENV_LOCAL_RPC_URL" ]]; then
    printf '%s' "$ENV_LOCAL_RPC_URL"
    return
  fi
  if [[ -n "$ENV_HEIMDALL_BOR_RPC_URL" ]]; then
    printf '%s' "$ENV_HEIMDALL_BOR_RPC_URL"
    return
  fi
  if [[ -n "$ENV_BOR_RPC_PORT" ]]; then
    printf 'http://127.0.0.1:%s' "$ENV_BOR_RPC_PORT"
    return
  fi
  if [[ -n "$FILE_LOCAL_RPC" ]]; then
    printf '%s' "$FILE_LOCAL_RPC"
    return
  fi
  if [[ -n "$FILE_LOCAL_RPC_URL" ]]; then
    printf '%s' "$FILE_LOCAL_RPC_URL"
    return
  fi
  if [[ -n "$FILE_HEIMDALL_BOR_RPC_URL" ]]; then
    printf '%s' "$FILE_HEIMDALL_BOR_RPC_URL"
    return
  fi
  if [[ -n "$FILE_BOR_RPC_PORT" ]]; then
    printf 'http://127.0.0.1:%s' "$FILE_BOR_RPC_PORT"
    return
  fi
  printf '%s' "$LOCAL_RPC_DEFAULT"
}

run_cmd() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" "$@"
  elif [[ -n "$COMPOSE_SERVICE" ]]; then
    docker compose exec -T "$COMPOSE_SERVICE" "$@"
  else
    "$@"
  fi
}

install_tools() {
  local tools=("$@")
  if run_cmd which apk >/dev/null 2>&1; then
    run_cmd apk add --no-cache "${tools[@]}" >/dev/null 2>&1
  elif run_cmd which apt-get >/dev/null 2>&1; then
    run_cmd apt-get update >/dev/null 2>&1
    run_cmd apt-get install -y "${tools[@]}" >/dev/null 2>&1
  else
    return 1
  fi
}

check_tools() {
  local missing=()

  if ! run_cmd which curl >/dev/null 2>&1; then
    missing+=("curl")
  fi
  if ! run_cmd which jq >/dev/null 2>&1; then
    missing+=("jq")
  fi

  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  if [[ -n "$CONTAINER" || -n "$COMPOSE_SERVICE" ]]; then
    if [[ "$NO_INSTALL" -eq 1 ]]; then
      print_error_and_exit "missing required tools: ${missing[*]}"
    fi
    if ! install_tools "${missing[@]}"; then
      print_error_and_exit "failed to install required tools: ${missing[*]}"
    fi
    return
  fi

  print_error_and_exit "missing required tools on host: ${missing[*]}"
}

rpc_call() {
  local url="$1"
  local method="$2"
  local params="${3:-[]}"

  run_cmd curl -sS --max-time 10 -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" 2>/dev/null
}

parse_block_height_hash() {
  local response="$1"
  # shellcheck disable=SC2016
  echo "$response" | run_cmd jq -r '
    (
      .result.number //
      .number //
      .result.blockNumber //
      .blockNumber //
      empty
    ) as $num
    | (
      .result.hash //
      .hash //
      .result.blockHash //
      .blockHash //
      empty
    ) as $hash
    | if ($num == "" or $hash == "") then empty else ($num + " " + $hash) end
  ' 2>/dev/null
}

latest_block_height_hash() {
  local url="$1"
  local response
  response="$(rpc_call "$url" "eth_getBlockByNumber" "[\"latest\", false]")" || return 1
  [[ -n "$response" ]] || return 1

  local parsed
  parsed="$(parse_block_height_hash "$response")" || return 1
  [[ -n "$parsed" ]] || return 1

  local hex_num hash
  hex_num="${parsed%% *}"
  hash="${parsed#* }"
  [[ "$hex_num" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  [[ -n "$hash" && "$hash" != "null" ]] || return 1

  local dec_num
  dec_num="$(printf '%d' "$hex_num" 2>/dev/null)" || return 1
  printf '%s %s\n' "$dec_num" "$hash"
}

eth_syncing_active() {
  local url="$1"
  local response parsed
  response="$(rpc_call "$url" "eth_syncing")" || return 2
  [[ -n "$response" ]] || return 2

  parsed="$(echo "$response" | run_cmd jq -rc '
    if .result == true then "syncing"
    elif .result == false then "not_syncing"
    elif (.result|type) == "object" then "syncing"
    elif .syncing == true then "syncing"
    elif .syncing == false then "not_syncing"
    elif (.syncing|type) == "object" then "syncing"
    elif .result.syncing == true then "syncing"
    elif .result.syncing == false then "not_syncing"
    elif (.result.syncing|type) == "object" then "syncing"
    else "unknown"
    end
  ' 2>/dev/null)" || return 2

  if [[ "$parsed" == "syncing" ]]; then
    return 0
  fi
  if [[ "$parsed" == "not_syncing" ]]; then
    return 1
  fi
  return 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public-rpc)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_PUBLIC_RPC="$2"
        shift 2
        ;;
      --local-rpc)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_LOCAL_RPC="$2"
        shift 2
        ;;
      --block-lag)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_BLOCK_LAG="$2"
        shift 2
        ;;
      --container)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CONTAINER="$2"
        shift 2
        ;;
      --compose-service)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        COMPOSE_SERVICE="$2"
        shift 2
        ;;
      --env-file)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        ENV_FILE="$2"
        shift 2
        ;;
      --no-install)
        NO_INSTALL=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        exit 2
        ;;
    esac
  done
}

parse_args "$@"

if [[ -n "$CONTAINER" && -n "$COMPOSE_SERVICE" ]]; then
  print_error_and_exit "--container and --compose-service are mutually exclusive"
fi

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || print_error_and_exit "env file not found: ${ENV_FILE}"
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

PUBLIC_RPC="$(resolve_public_rpc)"
LOCAL_RPC="$(resolve_local_rpc)"
BLOCK_LAG="$BLOCK_LAG_DEFAULT"

if [[ -n "$CLI_BLOCK_LAG" ]]; then
  BLOCK_LAG="$CLI_BLOCK_LAG"
elif [[ -n "$ENV_BLOCK_LAG" ]]; then
  BLOCK_LAG="$ENV_BLOCK_LAG"
elif [[ -n "$FILE_BLOCK_LAG" ]]; then
  BLOCK_LAG="$FILE_BLOCK_LAG"
fi

is_integer "$BLOCK_LAG" || print_error_and_exit "block lag must be an integer"

if [[ -n "$CONTAINER" ]]; then
  docker inspect "$CONTAINER" >/dev/null 2>&1 || print_error_and_exit "container not found: ${CONTAINER}"
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" == "true" ]] || print_error_and_exit "container is not running: ${CONTAINER}"
fi

if [[ -n "$COMPOSE_SERVICE" ]]; then
  docker compose ps --status running "$COMPOSE_SERVICE" 2>/dev/null | grep -q "$COMPOSE_SERVICE" || print_error_and_exit "compose service is not running: ${COMPOSE_SERVICE}"
fi

echo "⏳ Checking tools inside container"
check_tools
echo "✅ Tools available in container"
echo

echo "⏳ Latest block comparison"

local_latest="$(latest_block_height_hash "$LOCAL_RPC")" || print_error_and_exit "RPC unreachable (${LOCAL_RPC})"
public_latest="$(latest_block_height_hash "$PUBLIC_RPC")" || print_error_and_exit "RPC unreachable (${PUBLIC_RPC})"

local_height="${local_latest%% *}"
local_hash="${local_latest#* }"
public_height="${public_latest%% *}"
public_hash="${public_latest#* }"

raw_lag=$((public_height - local_height))
if (( raw_lag > 0 )); then
  lag="$raw_lag"
  lag_label="local behind"
elif (( raw_lag < 0 )); then
  lag="0"
  lag_label="local ahead"
else
  lag="0"
  lag_label="local in sync"
fi

echo "Local latest:  ${local_height} ${local_hash}"
echo "Public latest: ${public_height} ${public_hash}"
echo "Lag:         ${lag} blocks (threshold: ${BLOCK_LAG}) (${lag_label})"

syncing_by_flag=0
if eth_syncing_active "$LOCAL_RPC"; then
  syncing_by_flag=1
fi

echo
if (( lag > BLOCK_LAG || syncing_by_flag == 1 )); then
  echo "⏳ Final status: syncing"
  exit 1
fi

echo "✅ Final status: in sync"
exit 0
