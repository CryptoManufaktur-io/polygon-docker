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
          pv -f -p $output_tar | zstdcat - | tar -xf - -C ${extract_dir} 2>&1 | stdbuf -o0 tr '\r' '\n' && rm $output_tar
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
          pv -f -p $output_tar | zstdcat - | tar -xf - -C  ${extract_dir} --strip-components=3 2>&1 | stdbuf -o0 tr '\r' '\n' && rm $output_tar
      fi
  done
}

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run heimdalld as heimdall
if [ "$(id -u)" = '0' ]; then
   chown -R heimdall:heimdall /var/lib/heimdall
   exec gosu heimdall "$BASH_SOURCE" $@
fi

if [ ! -f /var/lib/heimdall/setupdone ]; then
  heimdalld init --home /var/lib/heimdall --chain ${NETWORK}
  mkdir -p /var/lib/heimdall/snapshots
  workdir=$(pwd)
  cd /var/lib/heimdall/snapshots
  # download snapshot files list
  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true https://snapshot-download.polygon.technology/heimdall-${NETWORK}-parts.txt
  # download all files, includes automatic checksum verification per increment
  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true -i heimdall-${NETWORK}-parts.txt
  extract_files /var/lib/heimdall/data
  cd "${workdir}"
  touch /var/lib/heimdall/setupdone
fi
SERVER_IP=$(curl -s ifconfig.me)
if [ -n "${HEIMDALL_SEEDS}" ]; then
  sed -i "/seeds =/c\seeds = \"${HEIMDALL_SEEDS}\"" /var/lib/heimdall/config/config.toml
fi
sed -i "/external_address = \".*\"/c\external_address = \"tcp:\/\/${SERVER_IP}:26656\"" /var/lib/heimdall/config/config.toml
sed -i '/26657/c\laddr = "tcp://0.0.0.0:26657"' /var/lib/heimdall/config/config.toml
sed -i "/moniker/c\moniker = \"${BOR_NODE_ID:-upbeatCucumber}\"" /var/lib/heimdall/config/config.toml
sed -i "/prometheus =/c\prometheus = \"${ENABLE_PROMETHEUS_METRICS:-false}\"" /var/lib/heimdall/config/config.toml
sed -i "/bor_rpc_url/c\bor_rpc_url = \"${HEIMDALL_BOR_RPC_URL}\"" /var/lib/heimdall/config/heimdall-config.toml
sed -i "/eth_rpc_url/c\eth_rpc_url = \"${HEIMDALL_ETH_RPC_URL}\"" /var/lib/heimdall/config/heimdall-config.toml
sed -i '/max_num_inbound_peers/c\max_num_inbound_peers = "300"' /var/lib/heimdall/config/config.toml
sed -i '/max_num_outbound_peers/c\max_num_outbound_peers = "100"' /var/lib/heimdall/config/config.toml
exec "$@"
