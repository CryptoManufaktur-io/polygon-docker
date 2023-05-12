#!/bin/bash
set -Eeuo pipefail

extract_files() {
    extract_dir=$1
    compiled_files=$2
    while read -r line; do
        if [[ "${line}" == checksum* ]]; then
            continue
        fi
        filename=`echo ${line} | awk -F/ '{print $NF}'`
        echo "Extracting ${filename}"
        if echo "${filename}" | grep -q "bulk"; then
            pv ${filename} | tar -I zstd -xf - -C ${extract_dir}
        else
            pv ${filename} | tar -I zstd -xf - -C ${extract_dir} --strip-components=3
        fi
        rm -f ${filename}
    done < ${compiled_files}
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
  # download compiled incremental snapshot files list
  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true https://snapshot-download.polygon.technology/heimdall-${NETWORK}-incremental-compiled-files.txt
  # download all incremental files, includes automatic checksum verification per increment
  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true -i heimdall-${NETWORK}-incremental-compiled-files.txt
  extract_files /var/lib/heimdall heimdall-${NETWORK}-incremental-compiled-files.txt
  cd "${workdir}"
  touch /var/lib/heimdall/setupdone
fi
SERVER_IP=$(curl -s ifconfig.me)
sed -i "/external_address = \".*\"/c\external_address = \"tcp:\/\/${SERVER_IP}:26656\"" /var/lib/heimdall/config/config.toml
sed -i '/26657/c\laddr = "tcp://0.0.0.0:26657"' /var/lib/heimdall/config/config.toml
sed -i "/moniker/c\moniker = \"${BOR_NODE_ID:-upbeatCucumber}\"" /var/lib/heimdall/config/config.toml
sed -i "/bor_rpc_url/c\bor_rpc_url = \"${HEIMDALL_BOR_RPC_URL}\"" /var/lib/heimdall/config/heimdall-config.toml
sed -i "/eth_rpc_url/c\eth_rpc_url = \"${HEIMDALL_ETH_RPC_URL}\"" /var/lib/heimdall/config/heimdall-config.toml
sed -i '/amqp_url/c\amqp_url = "amqp://guest:guest@rabbitmq:5672"' /var/lib/heimdall/config/heimdall-config.toml
exec "$@"
