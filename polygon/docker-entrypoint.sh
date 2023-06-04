#!/usr/bin/env bash
set -uo pipefail

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
            stdbuf -i0 -o0 -e0 pv -f ${filename} | zstdcat - | tar -xf - -C ${extract_dir}
        else
            stdbuf -i0 -o0 -e0 pv -f ${filename} | zstdcat - | tar -xf - -C ${extract_dir} --strip-components=3
        fi
        rm -f ${filename}
    done < ${compiled_files}
}

wget_files() {
    extract_dir=$1
    compiled_files=$2
    while read -r line; do
        if [[ "${line}" == checksum* ]]; then
            continue
        fi
        filename="${line}"
        echo "Extracting ${filename}"
        if echo "${filename}" | grep -q "bulk"; then
            wget -O - ${filename} | zstdcat - | tar -xf - -C ${extract_dir}
        else
            wget -O - ${filename} | zstdcat - | tar -xf - -C ${extract_dir} --strip-components=3
        fi
    done < ${compiled_files}
}

split_aria2_list() {
    compiled_files=$1
    bulk_file=$2
    incremental_file=$3
    
    rm -f $bulk_file
    rm -f $incremental_file

    while IFS= read -r line; do
        if [[ $line == *"bulk"* ]]; then
            echo "$line" >> $bulk_file
            IFS= read -r next_line
            echo "$next_line" >> $bulk_file
        else
            echo "$line" >> $incremental_file
            IFS= read -r next_line
            echo "$next_line" >> $incremental_file
        fi
    done < ${compiled_files}
}

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run bor as bor
if [ "$(id -u)" = '0' ]; then
   chown -R bor:bor /var/lib/bor
   exec su-exec bor "$BASH_SOURCE" "$@"
fi

# Set verbosity
shopt -s nocasematch
case ${LOG_LEVEL} in
  error)
    __verbosity="--verbosity 1"
    ;;
  warn)
    __verbosity="--verbosity 2"
    ;;
  info)
    __verbosity="--verbosity 3"
    ;;
  debug)
    __verbosity="--verbosity 4"
    ;;
  trace)
    __verbosity="--verbosity 5"
    ;;
  *)
    echo "LOG_LEVEL ${LOG_LEVEL} not recognized"
    __verbosity=""
    ;;
esac

if [ -n "${BOR_BOOTNODES}" ]; then
    __bootnodes="--bootnodes ${BOR_BOOTNODES}"
else
    __bootnodes=""
fi

# Create a config.toml with trusted nodes
cat << EOF >/var/lib/bor/config.toml
[p2p]
    [p2p.discovery]
        static-nodes = [${BOR_TRUSTED_NODES}]
        trusted-nodes = [${BOR_TRUSTED_NODES}]
EOF

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec bor snapshot prune-state --datadir /var/lib/bor/data
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    mkdir -p /var/lib/bor/data/bor/chaindata
    mkdir -p /var/lib/bor/snapshots
    workdir=$(pwd)
    cd /var/lib/bor/snapshots
    # download compiled incremental snapshot files list
    aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true https://snapshot-download.polygon.technology/bor-${NETWORK}-incremental-compiled-files.txt
    split_aria2_list bor-${NETWORK}-incremental-compiled-files.txt bor-bulk-file.txt bor-incremental-files.txt
    if [ "${USE_ARIA}" = "true" ]; then
        if [ ! -f /var/lib/bor/bulkdone ]; then
            # download bulk file, includes automatic checksum verification per increment
            aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true -i bor-bulk-file.txt
            extract_files /var/lib/bor/data/bor/chaindata bor-bulk-file.txt
            touch /var/lib/bor/bulkdone
        fi
        # download all incremental files, includes automatic checksum verification per increment
        # Be space-saving and do this one by one
        i=0
        >bor-current-incremental.txt
        while IFS= read -r entry; do
            # Every two lines, pass the temp file to aria2c
            if (( i % 2 == 0 )) && (( i != 0 )); then
                aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true -i bor-current-incremental.txt
                extract_files /var/lib/bor/data/bor/chaindata bor-current-incremental.txt
                >bor-current-incremental.txt
            fi
            # Write the current line to the temp file
            echo "$entry" >> bor-current-incremental.txt
            ((i++))
        done < bor-incremental-files.txt
        # Get the final file
        aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true -i bor-current-incremental.txt
        extract_files /var/lib/bor/data/bor/chaindata bor-current-incremental.txt
    else
        if [ ! -f /var/lib/bor/bulkdone ]; then
            wget_files /var/lib/bor/data/bor/chaindata bor-bulk-file.txt
            touch /var/lib/bor/bulkdone
        fi
        wget_files /var/lib/bor/data/bor/chaindata bor-incremental-files.txt
    fi
    cd "${workdir}"
    touch /var/lib/bor/setupdone
  fi
  exec "$@" ${__verbosity} ${__bootnodes}
fi
