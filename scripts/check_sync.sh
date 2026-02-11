#!/usr/bin/env bash
set -euo pipefail

LOCAL_RPC_DEFAULT="http://127.0.0.1:8545"
PUBLIC_RPC_DEFAULT="https://polygon-rpc.com"
BLOCK_LAG_DEFAULT=2
HEIMDALL_BLOCK_LAG_DEFAULT=2
HEIMDALL_RPC_PORT_DEFAULT=26657

ENV_PUBLIC_RPC="${PUBLIC_RPC:-}"
ENV_PUBLIC_RPC_URL="${PUBLIC_RPC_URL:-}"
ENV_LOCAL_RPC="${LOCAL_RPC:-}"
ENV_LOCAL_RPC_URL="${LOCAL_RPC_URL:-}"
ENV_BLOCK_LAG="${BLOCK_LAG:-}"
ENV_BOR_RPC_PORT="${BOR_RPC_PORT:-}"
ENV_HEIMDALL_BOR_RPC_URL="${HEIMDALL_BOR_RPC_URL:-}"
ENV_HEIMDALL_LOCAL_RPC="${HEIMDALL_LOCAL_RPC:-}"
ENV_HEIMDALL_PUBLIC_RPC="${HEIMDALL_PUBLIC_RPC:-}"
ENV_HEIMDALL_BLOCK_LAG="${HEIMDALL_BLOCK_LAG:-}"
ENV_HEIMDALL_RPC_PORT="${HEIMDALL_RPC_PORT:-}"
ENV_NETWORK="${NETWORK:-}"

CLI_PUBLIC_RPC=""
CLI_LOCAL_RPC=""
CLI_BLOCK_LAG=""
CLI_HEIMDALL_LOCAL_RPC=""
CLI_HEIMDALL_PUBLIC_RPC=""
CLI_HEIMDALL_BLOCK_LAG=""
CLI_SAMPLE_SECS=""
CONTAINER=""
COMPOSE_SERVICE=""
ENV_FILE=""
NO_INSTALL=0

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --local-rpc URL
  --public-rpc URL
  --block-lag N
  --heimdall-local-rpc URL
  --heimdall-public-rpc URL
  --heimdall-block-lag N
  --sample-secs N          Backward-compatible no-op
  --container NAME
  --compose-service NAME
  --env-file PATH
  --no-install
  -h, --help
USAGE
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

first_non_empty() {
  local value
  for value in "$@"; do
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
  done
  printf '%s' ""
}

resolve_with_default() {
  local default_value="$1"
  shift
  local resolved
  resolved="$(first_non_empty "$@")"
  if [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"
    return
  fi
  printf '%s' "$default_value"
}

calculate_lag_and_label() {
  local local_height="$1"
  local public_height="$2"
  local raw_lag
  raw_lag=$((public_height - local_height))

  if (( raw_lag > 0 )); then
    printf '%s\t%s\n' "$raw_lag" "local behind"
    return
  fi
  if (( raw_lag < 0 )); then
    printf '%s\t%s\n' "0" "local ahead"
    return
  fi
  printf '%s\t%s\n' "0" "local in sync"
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

set_env_from_file_if_unset() {
  local target_var="$1"
  local file_key="$2"
  local file="$3"
  local value

  value="$(normalize_env_value "$(read_env_value "$file_key" "$file")")"
  if [[ -n "$value" && -z "${!target_var}" ]]; then
    printf -v "$target_var" '%s' "$value"
  fi
}

load_env_file() {
  local file="$1"
  set_env_from_file_if_unset ENV_PUBLIC_RPC "PUBLIC_RPC" "$file"
  set_env_from_file_if_unset ENV_PUBLIC_RPC_URL "PUBLIC_RPC_URL" "$file"
  set_env_from_file_if_unset ENV_LOCAL_RPC "LOCAL_RPC" "$file"
  set_env_from_file_if_unset ENV_LOCAL_RPC_URL "LOCAL_RPC_URL" "$file"
  set_env_from_file_if_unset ENV_BLOCK_LAG "BLOCK_LAG" "$file"
  set_env_from_file_if_unset ENV_BOR_RPC_PORT "BOR_RPC_PORT" "$file"
  set_env_from_file_if_unset ENV_HEIMDALL_BOR_RPC_URL "HEIMDALL_BOR_RPC_URL" "$file"
  set_env_from_file_if_unset ENV_HEIMDALL_LOCAL_RPC "HEIMDALL_LOCAL_RPC" "$file"
  set_env_from_file_if_unset ENV_HEIMDALL_PUBLIC_RPC "HEIMDALL_PUBLIC_RPC" "$file"
  set_env_from_file_if_unset ENV_HEIMDALL_BLOCK_LAG "HEIMDALL_BLOCK_LAG" "$file"
  set_env_from_file_if_unset ENV_HEIMDALL_RPC_PORT "HEIMDALL_RPC_PORT" "$file"
  set_env_from_file_if_unset ENV_NETWORK "NETWORK" "$file"
}

resolve_network() {
  printf '%s' "$ENV_NETWORK"
}

resolve_public_rpc() {
  resolve_with_default "$PUBLIC_RPC_DEFAULT" \
    "$CLI_PUBLIC_RPC" \
    "$ENV_PUBLIC_RPC" \
    "$ENV_PUBLIC_RPC_URL"
}

resolve_local_rpc() {
  local resolved_rpc
  if [[ -n "$CONTAINER" || -n "$COMPOSE_SERVICE" ]]; then
    resolved_rpc="$(first_non_empty \
      "$CLI_LOCAL_RPC" \
      "$ENV_LOCAL_RPC" \
      "$ENV_LOCAL_RPC_URL" \
      "$ENV_HEIMDALL_BOR_RPC_URL")"
  else
    resolved_rpc="$(first_non_empty \
      "$CLI_LOCAL_RPC" \
      "$ENV_LOCAL_RPC" \
      "$ENV_LOCAL_RPC_URL")"
  fi
  if [[ -n "$resolved_rpc" ]]; then
    printf '%s' "$resolved_rpc"
    return
  fi
  if [[ -n "$ENV_BOR_RPC_PORT" ]]; then
    printf 'http://127.0.0.1:%s' "$ENV_BOR_RPC_PORT"
    return
  fi
  if [[ -n "$ENV_HEIMDALL_BOR_RPC_URL" ]]; then
    printf '%s' "$ENV_HEIMDALL_BOR_RPC_URL"
    return
  fi
  printf '%s' "$LOCAL_RPC_DEFAULT"
}

resolve_heimdall_rpc_port() {
  resolve_with_default "$HEIMDALL_RPC_PORT_DEFAULT" "$ENV_HEIMDALL_RPC_PORT"
}

resolve_heimdall_local_rpc() {
  local resolved_rpc
  resolved_rpc="$(first_non_empty "$CLI_HEIMDALL_LOCAL_RPC" "$ENV_HEIMDALL_LOCAL_RPC")"
  if [[ -n "$resolved_rpc" ]]; then
    printf '%s' "$resolved_rpc"
    return
  fi

  local rpc_port
  rpc_port="$(resolve_heimdall_rpc_port)"
  printf 'http://127.0.0.1:%s' "$rpc_port"
}

resolve_heimdall_public_rpc() {
  local network="$1"
  local resolved_rpc

  resolved_rpc="$(first_non_empty "$CLI_HEIMDALL_PUBLIC_RPC" "$ENV_HEIMDALL_PUBLIC_RPC")"
  if [[ -n "$resolved_rpc" ]]; then
    printf '%s' "$resolved_rpc"
    return
  fi

  case "$network" in
    mainnet)
      printf '%s' 'https://heimdall-api.polygon.technology'
      ;;
    amoy)
      printf '%s' 'https://heimdall-api-amoy.polygon.technology'
      ;;
    *)
      printf '%s' ''
      ;;
  esac
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

http_get() {
  local url="$1"
  run_cmd curl -sS --max-time 10 "$url" 2>/dev/null
}

eth_latest_block_height_hash() {
  local url="$1"
  local response
  response="$(rpc_call "$url" "eth_getBlockByNumber" "[\"latest\", false]")" || return 1
  [[ -n "$response" ]] || return 1

  local parsed
  # shellcheck disable=SC2016
  parsed="$(echo "$response" | run_cmd jq -r '
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
  ' 2>/dev/null)" || return 1
  [[ -n "$parsed" ]] || return 1

  local hex_num hash dec_num
  hex_num="${parsed%% *}"
  hash="${parsed#* }"
  [[ "$hex_num" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  [[ -n "$hash" && "$hash" != "null" ]] || return 1

  dec_num="$(printf '%d' "$hex_num" 2>/dev/null)" || return 1
  printf '%s %s\n' "$dec_num" "$hash"
}

eth_syncing_active() {
  local url="$1"
  local response parsed
  response="$(rpc_call "$url" "eth_syncing")" || return 2
  [[ -n "$response" ]] || return 2

  # shellcheck disable=SC2016
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

heimdall_status_height_catching_up() {
  local base_url="$1"
  local url="${base_url%/}/status"
  local response
  response="$(http_get "$url")" || return 1
  [[ -n "$response" ]] || return 1

  local parsed
  # shellcheck disable=SC2016
  parsed="$(echo "$response" | run_cmd jq -r '
    (
      .result.sync_info.latest_block_height //
      .sync_info.latest_block_height //
      empty
    ) as $height
    | (
      if (.result.sync_info.catching_up? | type) != "null" then
        .result.sync_info.catching_up
      elif (.sync_info.catching_up? | type) != "null" then
        .sync_info.catching_up
      else
        empty
      end
    ) as $catching
    | if ($height == "" or $catching == "") then
        empty
      else
        ($height|tostring) + " " + (
          if ($catching == true or ($catching|tostring|ascii_downcase) == "true") then "true" else "false" end
        )
      end
  ' 2>/dev/null)" || return 1
  [[ -n "$parsed" ]] || return 1

  local height catching
  height="${parsed%% *}"
  catching="${parsed#* }"
  [[ "$height" =~ ^[0-9]+$ ]] || return 1
  [[ "$catching" == "true" || "$catching" == "false" ]] || return 1

  printf '%s %s\n' "$height" "$catching"
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
      --heimdall-local-rpc)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_HEIMDALL_LOCAL_RPC="$2"
        shift 2
        ;;
      --heimdall-public-rpc)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_HEIMDALL_PUBLIC_RPC="$2"
        shift 2
        ;;
      --heimdall-block-lag)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_HEIMDALL_BLOCK_LAG="$2"
        shift 2
        ;;
      --sample-secs)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        CLI_SAMPLE_SECS="$2"
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
# Backward-compatible no-op flag.
if [[ -n "$CLI_SAMPLE_SECS" ]]; then
  :
fi

if [[ -n "$CONTAINER" && -n "$COMPOSE_SERVICE" ]]; then
  print_error_and_exit "--container and --compose-service are mutually exclusive"
fi

if [[ -n "$ENV_FILE" ]]; then
  [[ -f "$ENV_FILE" ]] || print_error_and_exit "env file not found: ${ENV_FILE}"
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

NETWORK_VALUE="$(resolve_network)"
PUBLIC_RPC="$(resolve_public_rpc)"
LOCAL_RPC="$(resolve_local_rpc)"
HEIMDALL_LOCAL_RPC="$(resolve_heimdall_local_rpc)"
HEIMDALL_PUBLIC_RPC="$(resolve_heimdall_public_rpc "$NETWORK_VALUE")"

BLOCK_LAG="$(resolve_with_default "$BLOCK_LAG_DEFAULT" "$CLI_BLOCK_LAG" "$ENV_BLOCK_LAG")"

HEIMDALL_BLOCK_LAG="$(resolve_with_default "$HEIMDALL_BLOCK_LAG_DEFAULT" "$CLI_HEIMDALL_BLOCK_LAG" "$ENV_HEIMDALL_BLOCK_LAG")"

is_integer "$BLOCK_LAG" || print_error_and_exit "--block-lag must be an integer"
is_integer "$HEIMDALL_BLOCK_LAG" || print_error_and_exit "--heimdall-block-lag must be an integer"
[[ -n "$PUBLIC_RPC" ]] || print_error_and_exit "public RPC is empty"
[[ -n "$LOCAL_RPC" ]] || print_error_and_exit "local RPC is empty"
[[ -n "$HEIMDALL_LOCAL_RPC" ]] || print_error_and_exit "heimdall local RPC is empty"

if [[ -z "$HEIMDALL_PUBLIC_RPC" ]]; then
  print_error_and_exit "HEIMDALL_PUBLIC_RPC is required when NETWORK is not mainnet/amoy (current NETWORK: ${NETWORK_VALUE:-unset})"
fi

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

echo "⏳ Bor latest block comparison"

bor_local_latest="$(eth_latest_block_height_hash "$LOCAL_RPC")" || print_error_and_exit "Bor RPC unreachable (${LOCAL_RPC})"
bor_public_latest="$(eth_latest_block_height_hash "$PUBLIC_RPC")" || print_error_and_exit "Bor public RPC unreachable (${PUBLIC_RPC})"

bor_local_height="${bor_local_latest%% *}"
bor_local_hash="${bor_local_latest#* }"
bor_public_height="${bor_public_latest%% *}"
bor_public_hash="${bor_public_latest#* }"

bor_lag_info="$(calculate_lag_and_label "$bor_local_height" "$bor_public_height")"
bor_lag="${bor_lag_info%%$'\t'*}"
bor_lag_label="${bor_lag_info#*$'\t'}"

echo "Local latest:  ${bor_local_height} ${bor_local_hash}"
echo "Public latest: ${bor_public_height} ${bor_public_hash}"
echo "Lag:         ${bor_lag} blocks (threshold: ${BLOCK_LAG}) (${bor_lag_label})"

bor_syncing=0
if (( bor_lag > BLOCK_LAG )); then
  bor_syncing=1
fi
if eth_syncing_active "$LOCAL_RPC"; then
  bor_syncing=1
else
  eth_syncing_result=$?
  if [[ "$eth_syncing_result" -eq 2 ]]; then
    echo "⚠️ warning: unable to query eth_syncing, using lag-only decision"
  fi
fi

echo

echo "⏳ Heimdall latest block comparison"

heimdall_local_status="$(heimdall_status_height_catching_up "$HEIMDALL_LOCAL_RPC")" || print_error_and_exit "Heimdall RPC unreachable or invalid /status (${HEIMDALL_LOCAL_RPC})"
heimdall_public_status="$(heimdall_status_height_catching_up "$HEIMDALL_PUBLIC_RPC")" || print_error_and_exit "Heimdall public RPC unreachable or invalid /status (${HEIMDALL_PUBLIC_RPC})"

heimdall_local_height="${heimdall_local_status%% *}"
heimdall_local_catching_up="${heimdall_local_status#* }"
heimdall_public_height="${heimdall_public_status%% *}"

heimdall_lag_info="$(calculate_lag_and_label "$heimdall_local_height" "$heimdall_public_height")"
heimdall_lag="${heimdall_lag_info%%$'\t'*}"
heimdall_lag_label="${heimdall_lag_info#*$'\t'}"

echo "Local latest:  ${heimdall_local_height}"
echo "Public latest: ${heimdall_public_height}"
echo "Lag:         ${heimdall_lag} blocks (threshold: ${HEIMDALL_BLOCK_LAG}) (${heimdall_lag_label})"

heimdall_syncing=0
if [[ "$heimdall_local_catching_up" == "true" ]]; then
  heimdall_syncing=1
fi
if (( heimdall_lag > HEIMDALL_BLOCK_LAG )); then
  heimdall_syncing=1
fi

echo
if (( bor_syncing == 1 || heimdall_syncing == 1 )); then
  echo "⏳ Final status: syncing"
  exit 1
fi

echo "✅ Final status: in sync"
exit 0
