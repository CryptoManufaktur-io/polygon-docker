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
        if echo "${filename}" | grep -q "bulk"; then
            pv ${filename} | tar -I zstd -xf - -C ${extract_dir}
        else
            pv ${filename} | tar -I zstd -xf - -C ${extract_dir} --strip-components=3
        fi
        rm -f ${filename}
    done < ${compiled_files}
}

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run bor as bor
if [ "$(id -u)" = '0' ]; then
   chown -R bor:bor /var/lib/bor
   exec su-exec bor "$BASH_SOURCE" "$@"
fi

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec bor snapshot prune-state --datadir /var/lib/bor/data
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    mkdir -p /var/lib/bor/data/bor/chaindata
    workdir=$(pwd)
    cd /var/lib/bor/snapshots
    # download compiled incremental snapshot files list
    aria2c -x6 -s6 https://snapshot-download.polygon.technology/bor-${NETWORK}-incremental-compiled-files.txt
    # download all incremental files, includes automatic checksum verification per increment
    aria2c -x6 -s6 -i bor-${NETWORK}-incremental-compiled-files.txt
    extract_files /var/lib/bor/data/bor/chaindata bor-${NETWORK}-incremental-compiled-files.txt
    cd "${workdir}"
    touch /var/lib/bor/setupdone
  fi
  exec "$@"
fi
