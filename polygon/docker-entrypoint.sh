#!/usr/bin/env bash
set -euo pipefail

__get_snapshot() {
  local __url=$1
  local __filename=""

  aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true "${__url}"
  __filename=$(echo "${__url}" | awk -F/ '{print $NF}')
  if [[ "${__filename}" =~ \.tar\.zst$ ]]; then
    pzstd -c -d "${__filename}" | tar xvf - -C /var/lib/bor/data/
  elif [[ "${__filename}" =~ \.tar\.gz$ || "${__filename}" =~ \.tgz$ ]]; then
    tar xzvf "${__filename}" -C /var/lib/bor/data/
  elif [[ "${__filename}" =~ \.tar$ ]]; then
    tar xvf "${__filename}" -C /var/lib/bor/data/
  elif [[ "${__filename}" =~ \.lz4$ ]]; then
    lz4 -c -d "${__filename}" | tar xvf - -C /var/lib/bor/data/
  else
    __dont_rm=1
    echo "The snapshot file has a format that Polygon Docker can't handle."
  fi
  if [ "${__dont_rm}" -eq 0 ]; then
    rm -f "${__filename}"
  fi
  # try to find the directory
  __search_dir="chaindata"
  __base_dir="/var/lib/bor/data/"
  __found_path=$(find "$__base_dir" -type d -path "*/$__search_dir" -print -quit)
  if [ "${__found_path}" = "${__base_dir}chaindata" ]; then
    echo "Found chaindata in root directory, moving it to bor folder"
    mkdir -p "${__base_dir}bor"
    mv "${__found_path}" "${__base_dir}bor"
  elif [ -n "${__found_path}" ]; then
    __bor_dir=$(dirname "$__found_path")
    __bor_dir=${__bor_dir%/chaindata}
    if [ "${__bor_dir}" = "${__base_dir}bor" ]; then
       echo "Snapshot extracted into ${__bor_dir}/chaindata"
    else
      echo "Found a bor directory at ${__bor_dir}, moving it."
      mv "${__bor_dir}" "${__base_dir}"
      rm -rf "${__bor_dir}"
    fi
  fi
  if [[ ! -d "/var/lib/bor/data/bor/chaindata" ]]; then
    echo "Chaindata isn't in the expected location."
    echo "This snapshot likely won't work until the fetch script has been adjusted for it."
    sleep 60
    exit 1
  fi
}


extract_files() {
  extract_dir=$1

  declare -A processed_dates

  # Join bulk parts into valid tar.zst and extract
  for file in $(find . -name "bor-$NETWORK-snapshot-bulk-*-part-*" -print | sort); do
      date_stamp=$(echo "$file" | grep -o 'snapshot-.*-part' | sed 's/snapshot-\(.*\)-part/\1/')

      # Check if we have already processed this date
      if [[ -z "${processed_dates[$date_stamp]:-}" ]]; then
          processed_dates[$date_stamp]=1
          output_tar="bor-$NETWORK-snapshot-${date_stamp}.tar.zst"
          echo "Join parts for ${date_stamp} then extract"
          cat "bor-$NETWORK-snapshot-${date_stamp}-part*" > "$output_tar"
          rm "bor-$NETWORK-snapshot-${date_stamp}-part*"
          pv -f -p "$output_tar" | zstdcat - | tar -xf - -C "${extract_dir}" 2>&1 && rm "$output_tar"
      fi
  done

  # Join incremental following day parts
  for file in $(find . -name "bor-$NETWORK-snapshot-*-part-*" -print | sort); do
      date_stamp=$(echo "$file" | grep -o 'snapshot-.*-part' | sed 's/snapshot-\(.*\)-part/\1/')

      # Check if we have already processed this date
      if [[ -z "${processed_dates[$date_stamp]:-}" ]]; then
          processed_dates[$date_stamp]=1
          output_tar="bor-$NETWORK-snapshot-${date_stamp}.tar.zst"
          echo "Join parts for ${date_stamp} then extract"
          cat "bor-$NETWORK-snapshot-${date_stamp}-part*" > "$output_tar"
          rm "bor-$NETWORK-snapshot-${date_stamp}-part*"
          pv -f -p "$output_tar" | zstdcat - | tar -xf - -C  "${extract_dir}" --strip-components=3 2>&1 && rm "$output_tar"
      fi
  done
}

# If started as root, chown the `--datadir` and run bor as bor
if [ "$(id -u)" = '0' ]; then
   chown -R bor:bor /var/lib/bor
   exec su-exec bor "${BASH_SOURCE[0]}" "$@"
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

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec bor snapshot prune-state --datadir /var/lib/bor/data
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    if [ -n "${SNAPSHOT}" ]; then
      mkdir -p /var/lib/bor/data/bor
      mkdir -p /var/lib/bor/snapshots
      workdir=$(pwd)
      __dont_rm=0
      cd /var/lib/bor/snapshots
# shellcheck disable=SC2076
      if [[ "${SNAPSHOT}" =~ ".txt" ]]; then
        mkdir -p /var/lib/bor/data/bor/chaindata
        # download snapshot files list
        aria2c -x6 -s6 "${SNAPSHOT}"
        set +e
        __filename=$(basename "${SNAPSHOT}")
        # download files, includes automatic checksum verification per increment
        aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session="bor-$NETWORK-failures.txt" --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i "${__filename}"

        max_retries=5
        retry_count=0

        while [ $retry_count -lt $max_retries ]; do
          echo "Retrying failed parts, attempt $((retry_count + 1))..."
          aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session="bor-$NETWORK-failures.txt" --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i "bor-$NETWORK-failures.txt"

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
        extract_files /var/lib/bor/data/bor/chaindata
      else
        __get_snapshot "${SNAPSHOT}"
        if [ -n "${SNAPSHOT_PART}" ]; then
          __get_snapshot "${SNAPSHOT_PART}"
        fi
      fi
      cd "${workdir}"
    fi
    touch /var/lib/bor/setupdone
  fi
  if [ -d "/var/lib/bor/data/bor/chaindata" ]; then # determine DB type
    # Find leveldb ldb files
    __files=$(find "/var/lib/bor/data/bor/chaindata" -mindepth 1 -maxdepth 1 -name '*.ldb')
    if [ -n "${__files}" ]; then
      __pbss=""
    else
      __pbss="--db.engine pebble --state.scheme path --syncmode snap"
    fi
  else
    __pbss=""
  fi
  if [[ "${HEIMDALL_REPO}" = *"heimdall-v2" ]]; then
    __ws="--bor.heimdallWS ws://${NETWORK}-heimdalld:${HEIMDALL_RPC_PORT}/websocket"
  else
    __ws=""
  fi
# shellcheck disable=SC2086
  bor dumpconfig "$@" ${__ws} ${__pbss} ${__verbosity} ${__bootnodes} ${EXTRAS} >/var/lib/bor/config.toml
  # Set user-supplied trusted nodes, also as static
  if [ -n "${TRUSTED_NODES}" ]; then
    for string in $(jq -r .[] <<< "${TRUSTED_NODES}"); do
# shellcheck disable=SC2116
      dasel put -v "$(echo "$string")" -f /var/lib/bor/config.toml 'p2p.discovery.trusted-nodes.[]'
# shellcheck disable=SC2116
      dasel put -v "$(echo "$string")" -f /var/lib/bor/config.toml 'p2p.discovery.static-nodes.[]'
    done
  fi
  exec bor server --config /var/lib/bor/config.toml
fi
