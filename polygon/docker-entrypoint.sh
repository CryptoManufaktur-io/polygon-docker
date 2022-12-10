#!/bin/bash
set -Eeuo pipefail

# allow the container to be started with `--user`
# If started as root, chown the `--datadir` and run bor as bor
if [ "$(id -u)" = '0' ]; then
   chown -R bor:bor /var/lib/bor
   exec su-exec bor "$BASH_SOURCE" "$@"
fi

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec "$@" snapshot prune-state
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    mkdir -p /var/lib/bor/data/bor/chaindata
    wget -q -O - "${BOR_FULL_NODE_SNAPSHOT_FILE}" | tar xzvf - -C /var/lib/bor/data/bor/chaindata
    touch /var/lib/bor/setupdone
  fi

  exec "$@"
fi
