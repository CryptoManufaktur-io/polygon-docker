#!/usr/bin/env bash
set -euo pipefail

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
          cat bor-$NETWORK-snapshot-${date_stamp}-part* > "$output_tar"
          rm bor-$NETWORK-snapshot-${date_stamp}-part*
          pv -f -p $output_tar | zstdcat - | tar -xf - -C ${extract_dir} 2>&1 && rm $output_tar
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
          cat bor-$NETWORK-snapshot-${date_stamp}-part* > "$output_tar"
          rm bor-$NETWORK-snapshot-${date_stamp}-part*
          pv -f -p $output_tar | zstdcat - | tar -xf - -C  ${extract_dir} --strip-components=3 2>&1 && rm $output_tar
      fi
  done
}

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

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec bor snapshot prune-state --datadir /var/lib/bor/data
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    if [ -n "${SNAPSHOT}" ]; then
      mkdir -p /var/lib/bor/data/bor/chaindata
      mkdir -p /var/lib/bor/snapshots
      workdir=$(pwd)
      cd /var/lib/bor/snapshots
      if [[ "${SNAPSHOT}" =~ "bor-${NETWORK}-parts.txt" ]]; then
        # download snapshot files list
        aria2c -x6 -s6 "${SNAPSHOT}"
        set +e
        # download files, includes automatic checksum verification per increment
        aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session=bor-$NETWORK-failures.txt --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i bor-${NETWORK}-parts.txt

        max_retries=5
        retry_count=0

        while [ $retry_count -lt $max_retries ]; do
          echo "Retrying failed parts, attempt $((retry_count + 1))..."
          aria2c -x6 -s6 --max-tries=0 --save-session-interval=60 --save-session=bor-$NETWORK-failures.txt --max-connection-per-server=4 --retry-wait=3 --check-integrity=true -i bor-$NETWORK-failures.txt

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
        extract_files /var/lib/bor/data/bor/chaindata
      else
        aria2c -c -x6 -s6 --auto-file-renaming=false --conditional-get=true --allow-overwrite=true "${SNAPSHOT}"
        filename=$(echo "${SNAPSHOT}" | awk -F/ '{print $NF}')
        if [[ "${filename}" =~ \.tar\.zst$ ]]; then
          pzstd -c -d "${filename}" | tar xvf - -C /var/lib/bor/data/bor/
        elif [[ "${filename}" =~ \.tar\.gz$ || "${filename}" =~ \.tgz$ ]]; then
          tar xzvf "${filename}" -C /var/lib/bor/data/bor/
        elif [[ "${filename}" =~ \.tar$ ]]; then
          tar xvf "${filename}" -C /var/lib/bor/data/bor/
        elif [[ "${filename}" =~ \.lz4$ ]]; then
          lz4 -d "${filename}" | tar xvf - -C /var/lib/bor/data/bor/
        else
          __dont_rm=1
          echo "The snapshot file has a format that Polygon Docker can't handle."
          echo "Please come to CryptoManufaktur Discord to work through this."
        fi
        if [ "${__dont_rm}" -eq 0 ]; then
          rm -f "${filename}"
        fi
        if [[ ! -d "/var/lib/bor/data/bor/chaindata" ]]; then
          echo "Chaindata isn't in the expected location."
          echo "This snapshot likely won't work until the fetch script has been adjusted for it."
        fi
      fi
      cd "${workdir}"
    fi
    touch /var/lib/bor/setupdone
  fi
  if [ ! -d "/var/lib/bor/data/bor/chaindata" ]; then # fresh sync is pebble
    __pbss="--db.engine pebble --state.scheme path"
  else
    # Find leveldb ldb files
    __files=$(find "/var/lib/bor/data/bor/chaindata" -mindepth 1 -maxdepth 1 -name '*.ldb')
    if [ -n "${__files}" ]; then
      __pbss=""
    else
      __pbss="--db.engine pebble --state.scheme path"
    fi
  fi
  bor dumpconfig "$@" ${__pbss} ${__verbosity} ${__bootnodes} ${EXTRAS} >/var/lib/bor/config.toml
  # Set user-supplied trusted nodes, also as static
  if [ -n "${TRUSTED_NODES}" ]; then
    for string in $(jq -r .[] <<< "${TRUSTED_NODES}"); do
      dasel put -v $(echo $string) -f /var/lib/bor/config.toml 'p2p.discovery.trusted-nodes.[]'
      dasel put -v $(echo $string) -f /var/lib/bor/config.toml 'p2p.discovery.static-nodes.[]'
    done
  fi
  exec bor server --config /var/lib/bor/config.toml
fi
