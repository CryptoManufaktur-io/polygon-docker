#!/bin/bash
set -Eeuo pipefail

extract_files() {
  extract_dir=$1

  declare -A processed_dates

  # Join bulk parts into valid tar.zst and extract
  for file in $(find . -name "heimdall-$NETWORK-snapshot-bulk-*-part-*" -print | sort); do
      date_stamp=$(echo "$file" | grep -o 'snapshot-.*-part' | sed 's/snapshot-\(.*\)-part/\1/')

      # Check if we have already processed this date
      if [[ -z "${processed_dates[$date_stamp]:-}" ]]; then
          processed_dates[$date_stamp]=1
          output_tar="heimdall-$NETWORK-snapshot-${date_stamp}.tar.zst"
          echo "Join parts for ${date_stamp} then extract"
          cat "heimdall-$NETWORK-snapshot-${date_stamp}-part*" > "$output_tar"
          rm "heimdall-$NETWORK-snapshot-${date_stamp}-part*"
          pv -f -p "$output_tar" | zstdcat - | tar -xf - -C "${extract_dir}" 2>&1 && rm "$output_tar"
      fi
  done

  # Join incremental following day parts
  for file in $(find . -name "heimdall-$NETWORK-snapshot-*-part-*" -print | sort); do
      date_stamp=$(echo "$file" | grep -o 'snapshot-.*-part' | sed 's/snapshot-\(.*\)-part/\1/')

      # Check if we have already processed this date
      if [[ -z "${processed_dates[$date_stamp]:-}" ]]; then
          processed_dates[$date_stamp]=1
          output_tar="heimdall-$NETWORK-snapshot-${date_stamp}.tar.zst"
          echo "Join parts for ${date_stamp} then extract"
          cat "heimdall-$NETWORK-snapshot-${date_stamp}-part*" > "$output_tar"
          rm "heimdall-$NETWORK-snapshot-${date_stamp}-part*"
          pv -f -p "$output_tar" | zstdcat - | tar -xf - -C  "${extract_dir}" --strip-components=3 2>&1 && rm "$output_tar"
      fi
  done
}

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run heimdalld as heimdall
if [ "$(id -u)" = '0' ]; then
   chown -R heimdall:heimdall /var/lib/heimdall
   exec su-exec heimdall "${BASH_SOURCE[0]}" "$@"
fi

if [ ! -f /var/lib/heimdall/setupdone ]; then
  heimdalld init --home /var/lib/heimdall --chain "${NETWORK}"
  if [ -n "${SNAPSHOT}" ]; then
    mkdir -p /var/lib/heimdall/snapshots
    workdir=$(pwd)
    __dont_rm=0
    cd /var/lib/heimdall/snapshots
# shellcheck disable=SC2076
    if [[ "${SNAPSHOT}" =~ ".txt" ]]; then
      # download snapshot files list
      aria2c -x6 -s6 "${SNAPSHOT}"
      # download all files, includes automatic checksum verification per increment
      set +e
      __filename=$(basename "${SNAPSHOT}")
      aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session="heimdall-$NETWORK-failures.txt" --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i "${__filename}"

      max_retries=5
      retry_count=0

      while [ $retry_count -lt $max_retries ]; do
        echo "Retrying failed parts, attempt $((retry_count + 1))..."
        aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session="heimdall-$NETWORK-failures.txt" --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i "heimdall-$NETWORK-failures.txt"

        # Check the exit status of the aria2c command
# shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            echo "Command succeeded."
            break  # Exit the loop since the command succeeded
        else
            echo "Command failed. Retrying..."
            retry_count=$((retry_count + 1))
        fi
      done

      # Don't extract if download/retries failed.
      if [ $retry_count -eq $max_retries ]; then
          echo "Download failed. Restart the script to resume downloading."
          exit 1
      fi

      set -e
      extract_files /var/lib/heimdall/data
    else
      aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true "${SNAPSHOT}"
      filename=$(echo "${SNAPSHOT}" | awk -F/ '{print $NF}')
      if [[ "${filename}" =~ \.tar\.zst$ ]]; then
        pzstd -c -d "${filename}" | tar xvf - -C /var/lib/heimdall/data/
      elif [[ "${filename}" =~ \.tar\.gz$ || "${filename}" =~ \.tgz$ ]]; then
        tar xzvf "${filename}" -C /var/lib/heimdall/data/
      elif [[ "${filename}" =~ \.tar$ ]]; then
        tar xvf "${filename}" -C /var/lib/heimdall/data/
      elif [[ "${filename}" =~ \.lz4$ ]]; then
        lz4 -d "${filename}" | tar xvf - -C /var/lib/heimdall/data/
      else
        __dont_rm=1
        echo "The snapshot file has a format that Polygon Docker can't handle."
        echo "Please come to CryptoManufaktur Discord to work through this."
      fi
      if [ "${__dont_rm}" -eq 0 ]; then
        rm -f "${filename}"
      fi
      if [[ ! -d "/var/lib/heimdall/data/state.db/" ]]; then
        echo "Heimdall data isn't in the expected location."
        echo "This snapshot likely won't work until the fetch script has been adjusted for it."
      fi
    fi
    cd "${workdir}"
  fi
  touch /var/lib/heimdall/setupdone
fi
SERVER_IP=$(curl -s ifconfig.me)
if [ -n "${HEIMDALL_SEEDS}" ]; then
  dasel put -v "${HEIMDALL_SEEDS}" -f /var/lib/heimdall/config/config.toml 'p2p.seeds'
fi
if [ -n "${HEIMDALL_PEERS}" ]; then
  dasel put -v "${HEIMDALL_PEERS}" -f /var/lib/heimdall/config/config.toml 'p2p.persistent_peers'
fi

dasel put -v "main:${LOG_LEVEL},state:${LOG_LEVEL},*:error" -f /var/lib/heimdall/config/config.toml 'log_level'
dasel put -v "tcp://0.0.0.0:${HEIMDALL_RPC_PORT}" -f /var/lib/heimdall/config/config.toml 'rpc.laddr'
dasel put -v "tcp://${SERVER_IP}:${HEIMDALL_P2P_PORT}" -f /var/lib/heimdall/config/config.toml 'p2p.external_address'
dasel put -v "tcp://0.0.0.0:${HEIMDALL_P2P_PORT}" -f /var/lib/heimdall/config/config.toml 'p2p.laddr'
dasel put -v "${BOR_NODE_ID:-upbeatCucumber}" -f /var/lib/heimdall/config/config.toml 'moniker'
dasel put -v "${ENABLE_PROMETHEUS_METRICS:-false}" -f /var/lib/heimdall/config/config.toml 'instrumentation.prometheus'
dasel put -v "300" -f /var/lib/heimdall/config/config.toml 'p2p.max_num_inbound_peers'
dasel put -v "100" -f /var/lib/heimdall/config/config.toml 'p2p.max_num_outbound_peers'
dasel put -v "http://0.0.0.0:${HEIMDALL_RPC_PORT}" -f /var/lib/heimdall/config/heimdall-config.toml 'tendermint_rpc_url'
dasel put -v "${HEIMDALL_BOR_RPC_URL}" -f /var/lib/heimdall/config/heimdall-config.toml 'bor_rpc_url'
dasel put -v "${HEIMDALL_ETH_RPC_URL}" -f /var/lib/heimdall/config/heimdall-config.toml 'eth_rpc_url'
exec "$@"
