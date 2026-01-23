#!/usr/bin/env bash
set -euo pipefail

# check_sync.sh - Compare local node against a public reference RPC
#
# Exit codes:
#   0 - In sync or within acceptable lag
#   1 - Still syncing (beyond threshold)
#   2 - Hash mismatch (possible reorg/fork)
#   3 - Local RPC error
#   4 - Public RPC error
#   5 - Missing required tools (curl/jq)
#   6 - Invalid arguments
#   7 - Container/service not found or not running

LOCAL_RPC_DEFAULT="http://127.0.0.1:8545"
BLOCK_LAG_DEFAULT=2
SAMPLE_SECS_DEFAULT=10

ENV_PUBLIC_RPC="${PUBLIC_RPC:-}"
ENV_PUBLIC_RPC_URL="${PUBLIC_RPC_URL:-}"
ENV_LOCAL_RPC="${LOCAL_RPC:-}"
ENV_LOCAL_RPC_URL="${LOCAL_RPC_URL:-}"
ENV_BLOCK_LAG="${BLOCK_LAG:-}"
ENV_SAMPLE_SECS="${SAMPLE_SECS:-}"
ENV_BOR_RPC_PORT="${BOR_RPC_PORT:-}"
ENV_HEIMDALL_BOR_RPC_URL="${HEIMDALL_BOR_RPC_URL:-}"

PUBLIC_RPC=""
LOCAL_RPC=""
BLOCK_LAG="$BLOCK_LAG_DEFAULT"
SAMPLE_SECS="$SAMPLE_SECS_DEFAULT"
CONTAINER=""
COMPOSE_SERVICE=""
ENV_FILE=""
NO_INSTALL=0

FILE_PUBLIC_RPC=""
FILE_PUBLIC_RPC_URL=""
FILE_LOCAL_RPC=""
FILE_LOCAL_RPC_URL=""
FILE_BLOCK_LAG=""
FILE_SAMPLE_SECS=""
FILE_BOR_RPC_PORT=""
FILE_HEIMDALL_BOR_RPC_URL=""

CLI_PUBLIC_RPC=""
CLI_LOCAL_RPC=""
CLI_BLOCK_LAG=""
CLI_SAMPLE_SECS=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Compare local node sync status against a public reference RPC.

Required (unless set via env file or environment):
  --public-rpc URL       Public RPC endpoint to compare against

Options:
  --local-rpc URL        Local RPC endpoint (default: http://127.0.0.1:8545)
  --block-lag N          Acceptable block lag threshold (default: 2)
  --sample-secs N        Seconds to sample block advancement (default: 10)
  --container NAME       Docker container to run curl/jq within
  --compose-service NAME Docker Compose service to run curl/jq within
  --env-file PATH        Env file to load (default: .env if present)
  --no-install           Do not auto-install curl/jq inside containers
  -h, --help             Show this help message

Env vars (optional overrides):
  PUBLIC_RPC, PUBLIC_RPC_URL
  LOCAL_RPC, LOCAL_RPC_URL
  BLOCK_LAG, SAMPLE_SECS
  BOR_RPC_PORT, HEIMDALL_BOR_RPC_URL

Exit Codes:
  0 - In sync or within acceptable lag
  1 - Still syncing (beyond threshold)
  2 - Hash mismatch at same block height (possible reorg/fork)
  3 - Local RPC error
  4 - Public RPC error
  5 - Missing required tools
  6 - Invalid arguments
  7 - Container/service error

Examples:
  ./ethd check-sync --public-rpc https://polygon-rpc.com
  ./ethd check-sync --compose-service bor --public-rpc https://polygon-rpc.com
  ./ethd check-sync --env-file .env --public-rpc https://polygon-rpc.com
EOF
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
  if [[ "$value" =~ ^".*"$ ]]; then
    value="${value:1:-1}"
  elif [[ "$value" =~ ^'.*'$ ]]; then
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
  FILE_SAMPLE_SECS="$(normalize_env_value "$(read_env_value "SAMPLE_SECS" "$file")")"
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
  printf '%s' ""
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

ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
  case "${ARGS[i]}" in
    --env-file)
      if [[ $((i+1)) -ge ${#ARGS[@]} ]]; then
        echo "Error: --env-file requires a value" >&2
        usage
        exit 6
      fi
      ENV_FILE="${ARGS[i+1]}"
      i=$((i+1))
      ;;
  esac
done

ENV_FILE_USED=""
if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: env file not found: $ENV_FILE" >&2
    exit 6
  fi
  ENV_FILE_USED="$ENV_FILE"
elif [[ -f ".env" ]]; then
  ENV_FILE_USED=".env"
fi

if [[ -n "$ENV_FILE_USED" ]]; then
  load_env_file "$ENV_FILE_USED"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-rpc)
      if [[ $# -lt 2 ]]; then
        echo "Error: --public-rpc requires a value" >&2
        usage
        exit 6
      fi
      CLI_PUBLIC_RPC="$2"
      shift 2
      ;;
    --local-rpc)
      if [[ $# -lt 2 ]]; then
        echo "Error: --local-rpc requires a value" >&2
        usage
        exit 6
      fi
      CLI_LOCAL_RPC="$2"
      shift 2
      ;;
    --block-lag)
      if [[ $# -lt 2 ]]; then
        echo "Error: --block-lag requires a value" >&2
        usage
        exit 6
      fi
      CLI_BLOCK_LAG="$2"
      shift 2
      ;;
    --sample-secs)
      if [[ $# -lt 2 ]]; then
        echo "Error: --sample-secs requires a value" >&2
        usage
        exit 6
      fi
      CLI_SAMPLE_SECS="$2"
      shift 2
      ;;
    --container)
      if [[ $# -lt 2 ]]; then
        echo "Error: --container requires a value" >&2
        usage
        exit 6
      fi
      CONTAINER="$2"
      shift 2
      ;;
    --compose-service)
      if [[ $# -lt 2 ]]; then
        echo "Error: --compose-service requires a value" >&2
        usage
        exit 6
      fi
      COMPOSE_SERVICE="$2"
      shift 2
      ;;
    --env-file)
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
      echo "Error: Unknown option: $1" >&2
      usage
      exit 6
      ;;
  esac
done

if [[ -n "$CONTAINER" && -n "$COMPOSE_SERVICE" ]]; then
  echo "Error: --container and --compose-service are mutually exclusive" >&2
  exit 6
fi

PUBLIC_RPC="$(resolve_public_rpc)"
LOCAL_RPC="$(resolve_local_rpc)"

if [[ -n "$CLI_BLOCK_LAG" ]]; then
  BLOCK_LAG="$CLI_BLOCK_LAG"
elif [[ -n "$ENV_BLOCK_LAG" ]]; then
  BLOCK_LAG="$ENV_BLOCK_LAG"
elif [[ -n "$FILE_BLOCK_LAG" ]]; then
  BLOCK_LAG="$FILE_BLOCK_LAG"
fi

if [[ -n "$CLI_SAMPLE_SECS" ]]; then
  SAMPLE_SECS="$CLI_SAMPLE_SECS"
elif [[ -n "$ENV_SAMPLE_SECS" ]]; then
  SAMPLE_SECS="$ENV_SAMPLE_SECS"
elif [[ -n "$FILE_SAMPLE_SECS" ]]; then
  SAMPLE_SECS="$FILE_SAMPLE_SECS"
fi

if [[ -z "$PUBLIC_RPC" ]]; then
  echo "Error: --public-rpc is required" >&2
  usage
  exit 6
fi

if [[ -z "$LOCAL_RPC" ]]; then
  echo "Error: local RPC is empty" >&2
  exit 6
fi

if ! is_integer "$BLOCK_LAG"; then
  echo "Error: --block-lag must be an integer" >&2
  exit 6
fi

if ! is_integer "$SAMPLE_SECS"; then
  echo "Error: --sample-secs must be an integer" >&2
  exit 6
fi

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

  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ -n "$CONTAINER" || -n "$COMPOSE_SERVICE" ]]; then
      if [[ "$NO_INSTALL" -eq 1 ]]; then
        echo "Error: Missing required tools: ${missing[*]}" >&2
        exit 5
      fi
      echo "Installing missing tools: ${missing[*]}..."
      if ! install_tools "${missing[@]}"; then
        echo "Error: Failed to install tools: ${missing[*]}" >&2
        exit 5
      fi
    else
      echo "Error: Missing required tools: ${missing[*]}" >&2
      echo "Install with: brew install ${missing[*]} (macOS) or apt install ${missing[*]} (Linux)" >&2
      exit 5
    fi
  fi
}

rpc_call() {
  local url="$1"
  local method="$2"
  local params="${3:-[]}";

  run_cmd curl -s -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" 2>/dev/null
}

get_block_number() {
  local url="$1"
  local response
  response=$(rpc_call "$url" "eth_blockNumber")

  if [[ -z "$response" ]]; then
    return 1
  fi

  local block_value
  block_value=$(echo "$response" | run_cmd jq -r '(
    .result //
    .blockNumber //
    .result.blockNumber //
    .result.number //
    .number //
    .block_height //
    .height //
    empty
  )' 2>/dev/null)

  if [[ -z "$block_value" || "$block_value" == "null" ]]; then
    local error
    error=$(echo "$response" | run_cmd jq -r '.error.message // .message // empty' 2>/dev/null)
    if [[ -n "$error" ]]; then
      echo "RPC error: $error" >&2
    fi
    return 1
  fi

  printf "%d" "$block_value"
}

check_syncing() {
  local url="$1"
  local response
  response=$(rpc_call "$url" "eth_syncing")

  if [[ -z "$response" ]]; then
    return 1
  fi

  local result
  result=$(echo "$response" | run_cmd jq -rc '
    if .result == false then false
    elif .result == true then true
    elif (.result|type) == "object" then .result
    elif (.syncing|type) == "boolean" then .syncing
    elif (.syncing|type) == "object" then .syncing
    elif (.result.syncing|type) == "boolean" then .result.syncing
    elif (.result.syncing|type) == "object" then .result.syncing
    else empty end
  ' 2>/dev/null)

  if [[ -z "$result" ]]; then
    return 1
  fi

  echo "$result"
}

get_block_hash() {
  local url="$1"
  local block_num="$2"
  local hex_block

  hex_block=$(printf "0x%x" "$block_num")

  local response
  response=$(rpc_call "$url" "eth_getBlockByNumber" "[\"$hex_block\", false]")

  if [[ -z "$response" ]]; then
    return 1
  fi

  local hash
  hash=$(echo "$response" | run_cmd jq -r '(
    .result.hash //
    .hash //
    .result.blockHash //
    .blockHash //
    empty
  )' 2>/dev/null)

  if [[ -z "$hash" || "$hash" == "null" ]]; then
    return 1
  fi

  echo "$hash"
}

if [[ -n "$CONTAINER" ]]; then
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Error: Container '$CONTAINER' not found" >&2
    exit 7
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]]; then
    echo "Error: Container '$CONTAINER' is not running" >&2
    exit 7
  fi
elif [[ -n "$COMPOSE_SERVICE" ]]; then
  if ! docker compose ps --status running "$COMPOSE_SERVICE" 2>/dev/null | grep -q "$COMPOSE_SERVICE"; then
    echo "Error: Compose service '$COMPOSE_SERVICE' is not running" >&2
    exit 7
  fi
fi

check_tools

echo "Checking sync status..."
echo "Local RPC:  $LOCAL_RPC"
echo "Public RPC: $PUBLIC_RPC"
if [[ -n "$ENV_FILE_USED" ]]; then
  echo "Env file:   $ENV_FILE_USED"
fi
echo

echo "Checking eth_syncing..."
syncing=0
sync_check_failed=0
sync_status=$(check_syncing "$LOCAL_RPC") || sync_check_failed=1

if [[ "$sync_check_failed" -eq 1 ]]; then
  echo "Warning: Failed to query eth_syncing on local RPC" >&2
elif [[ "$sync_status" != "false" ]]; then
  syncing=1
  echo "Node is actively syncing"
  if [[ "$sync_status" != "true" ]]; then
    current=$(echo "$sync_status" | run_cmd jq -r '.currentBlock // empty' 2>/dev/null)
    highest=$(echo "$sync_status" | run_cmd jq -r '.highestBlock // empty' 2>/dev/null)
    if [[ -n "$current" && -n "$highest" ]]; then
      current_dec=$((current))
      highest_dec=$((highest))
      behind=$((highest_dec - current_dec))
      pct=$(awk "BEGIN {printf \"%.2f\", ($current_dec / $highest_dec) * 100}")
      echo "Progress: $current_dec / $highest_dec ($pct%) - $behind blocks behind"
    fi
  fi
else
  echo "eth_syncing reports: not syncing"
fi

echo

echo "Fetching block numbers..."
local_err=0
public_err=0

if ! local_block=$(get_block_number "$LOCAL_RPC"); then
  local_err=1
  local_block=""
fi

if ! public_block=$(get_block_number "$PUBLIC_RPC"); then
  public_err=1
  public_block=""
fi

if [[ "$local_err" -eq 1 ]]; then
  echo "Local block:  unavailable"
else
  echo "Local block:  $local_block"
fi

if [[ "$public_err" -eq 1 ]]; then
  echo "Public block: unavailable"
else
  echo "Public block: $public_block"
fi

if [[ "$local_err" -eq 1 || "$public_err" -eq 1 ]]; then
  echo "Block lag: unavailable"
  if [[ "$local_err" -eq 1 ]]; then
    echo "Error: Failed to get local block number" >&2
    exit 3
  fi
  echo "Error: Failed to get public block number" >&2
  exit 4
fi

lag=$((public_block - local_block))
echo "Block lag: $lag"
echo

if [[ $lag -gt $BLOCK_LAG ]]; then
  echo "Sampling block advancement over ${SAMPLE_SECS}s..."
  start_block=$local_block
  sleep "$SAMPLE_SECS"

  end_block=$(get_block_number "$LOCAL_RPC") || {
    echo "Error: Failed to get local block number after sampling" >&2
    exit 3
  }

  blocks_advanced=$((end_block - start_block))

  if [[ $blocks_advanced -gt 0 ]]; then
    rate=$(awk "BEGIN {printf \"%.2f\", $blocks_advanced / $SAMPLE_SECS}")
    echo "Block rate: $rate blocks/sec"

    public_block_now=$(get_block_number "$PUBLIC_RPC") || {
      echo "Warning: Failed to get updated public block" >&2
      public_block_now=$public_block
    }

    current_lag=$((public_block_now - end_block))

    if [[ $current_lag -gt 0 ]]; then
      chain_growth=2
      effective_rate=$(awk "BEGIN {print $rate - $chain_growth}")
      if (( $(awk "BEGIN {print ($effective_rate > 0) ? 1 : 0}") )); then
        eta_secs=$(awk "BEGIN {printf \"%.0f\", $current_lag / $effective_rate}")
        eta_hours=$((eta_secs / 3600))
        eta_mins=$(((eta_secs % 3600) / 60))
        echo "Estimated time to sync: ${eta_hours}h ${eta_mins}m"
      else
        echo "Warning: Sync rate not keeping up with chain growth"
      fi
    fi

    echo
    echo "Current lag: $current_lag blocks"

    if [[ $current_lag -gt $BLOCK_LAG ]]; then
      echo "Status: SYNCING ($current_lag blocks behind, threshold: $BLOCK_LAG)"
      exit 1
    fi
  else
    echo "Warning: No block advancement detected"
    echo "Status: SYNCING (not advancing, $lag blocks behind)"
    exit 1
  fi
fi

echo "Verifying block hash consistency..."
check_height=$local_block

local_hash=$(get_block_hash "$LOCAL_RPC" "$check_height") || {
  echo "Warning: Failed to get local block hash" >&2
  local_hash=""
}

public_hash=$(get_block_hash "$PUBLIC_RPC" "$check_height") || {
  echo "Warning: Failed to get public block hash (block may not exist yet)" >&2
  public_hash=""
}

if [[ -n "$local_hash" && -n "$public_hash" ]]; then
  if [[ "$local_hash" != "$public_hash" ]]; then
    echo "HASH MISMATCH at block $check_height!"
    echo "Local:  $local_hash"
    echo "Public: $public_hash"
    echo
    echo "Status: DIVERGED (possible reorg or wrong network)"
    exit 2
  fi
  echo "Block hashes match at height $check_height"
fi

echo
if [[ "$sync_check_failed" -eq 1 ]]; then
  echo "Status: UNKNOWN (eth_syncing failed; lag: $lag blocks, threshold: $BLOCK_LAG)"
  exit 3
fi

if [[ "$syncing" -eq 1 ]]; then
  echo "Status: SYNCING (eth_syncing true; lag: $lag blocks, threshold: $BLOCK_LAG)"
  exit 1
fi

echo "Status: IN SYNC (lag: $lag blocks, threshold: $BLOCK_LAG)"
exit 0
