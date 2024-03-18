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
          cat heimdall-$NETWORK-snapshot-${date_stamp}-part* > "$output_tar"
          rm heimdall-$NETWORK-snapshot-${date_stamp}-part*
          pv -f -p $output_tar | zstdcat - | tar -xf - -C ${extract_dir} 2>&1 && rm $output_tar
      fi
  done

  # Join incremental following day parts
  for file in $(find . -name "heimdall-$NETWORK-snapshot-*-part-*" -print | sort); do
      date_stamp=$(echo "$file" | grep -o 'snapshot-.*-part' | sed 's/snapshot-\(.*\)-part/\1/')

      # Check if we have already processed this date
      if [[ -z "${processed_dates[$date_stamp]}:-" ]]; then
          processed_dates[$date_stamp]=1
          output_tar="heimdall-$NETWORK-snapshot-${date_stamp}.tar.zst"
          echo "Join parts for ${date_stamp} then extract"
          cat heimdall-$NETWORK-snapshot-${date_stamp}-part* > "$output_tar"
          rm heimdall-$NETWORK-snapshot-${date_stamp}-part*
          pv -f -p $output_tar | zstdcat - | tar -xf - -C  ${extract_dir} --strip-components=3 2>&1 && rm $output_tar
      fi
  done
}

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run heimdalld as heimdall
if [ "$(id -u)" = '0' ]; then
   chown -R heimdall:heimdall /var/lib/heimdall
   exec su-exec heimdall "$BASH_SOURCE" $@
fi

if [ ! -f /var/lib/heimdall/setupdone ]; then
  heimdalld init --home /var/lib/heimdall --chain ${NETWORK}
  if [ ! ${NETWORK} = "amoy" ]; then
    mkdir -p /var/lib/heimdall/snapshots
    workdir=$(pwd)
    cd /var/lib/heimdall/snapshots
    # download snapshot files list
    aria2c -x6 -s6 https://snapshot-download.polygon.technology/heimdall-${NETWORK}-parts.txt
    # download all files, includes automatic checksum verification per increment
    set +e
    aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session=heimdall-$NETWORK-failures.txt --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i heimdall-${NETWORK}-parts.txt

    max_retries=5
    retry_count=0

    while [ $retry_count -lt $max_retries ]; do
      echo "Retrying failed parts, attempt $((retry_count + 1))..."
      aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session=heimdall-$NETWORK-failures.txt --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i heimdall-$NETWORK-failures.txt

      # Check the exit status of the aria2c command
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
    cd "${workdir}"
  fi
  touch /var/lib/heimdall/setupdone
fi
SERVER_IP=$(curl -s ifconfig.me)
if [ -n "${HEIMDALL_SEEDS}" ]; then
  dasel put -v "${HEIMDALL_SEEDS}" -f /var/lib/heimdall/config/config.toml 'p2p.seeds'
fi
dasel put -v "main:${LOG_LEVEL},state:${LOG_LEVEL},*:error" -f /var/lib/heimdall/config/config.toml 'log_level'
dasel put -v "tcp://0.0.0.0:${HEIMDALL_RPC_PORT}" -f /var/lib/heimdall/config/config.toml 'rpc.laddr'
dasel put -v "tcp://${SERVER_IP}:${HEIMDALL_P2P_PORT}" -f /var/lib/heimdall/config/config.toml 'p2p.external_address'
dasel put -v "tcp://0.0.0.0:${HEIMDALL_P2P_PORT}" -f /var/lib/heimdall/config/config.toml 'p2p.laddr'
dasel put -v "${BOR_NODE_ID:-upbeatCucumber}" -f /var/lib/heimdall/config/config.toml 'moniker'
dasel put -v "${ENABLE_PROMETHEUS_METRICS:-false}" -f /var/lib/heimdall/config/config.toml 'instrumentation.prometheus'
dasel put -v "300" -f /var/lib/heimdall/config/config.toml 'p2p.max_num_inbound_peers'
dasel put -v "100" -f /var/lib/heimdall/config/config.toml 'p2p.max_num_outbound_peers'
dasel put -v "${HEIMDALL_BOR_RPC_URL}" -f /var/lib/heimdall/config/heimdall-config.toml 'bor_rpc_url'
dasel put -v "${HEIMDALL_ETH_RPC_URL}" -f /var/lib/heimdall/config/heimdall-config.toml 'eth_rpc_url'
exec "$@"
