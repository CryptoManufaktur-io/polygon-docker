#!/bin/bash
set -Eeuo pipefail

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

if [ -f /var/lib/bor/prune-marker ]; then
  rm -f /var/lib/bor/prune-marker
  exec bor snapshot prune-state --datadir /var/lib/bor/data
else
  if [ ! -f /var/lib/bor/setupdone ]; then
    mkdir -p /var/lib/bor/data/bor/chaindata
    wget -q -O - "${BOR_FULL_NODE_SNAPSHOT_FILE}" | tar xzvf - -C /var/lib/bor/data/bor/chaindata
    touch /var/lib/bor/setupdone
  fi

  exec "$@" ${__verbosity}
fi
