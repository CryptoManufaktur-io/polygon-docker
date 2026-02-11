# Overview

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

If you want the RPC ports exposed locally, use `bor-shared.yml` in `COMPOSE_FILE` inside `.env`.

## Getting Started

For a quick start, you can install prerequisites and configure Polygon Docker, as a non-root user:

* `cd ~ && git clone https://github.com/CryptoManufaktur-io/polygon-docker.git && cd polygon-docker`
* `./polygond install`
* `cp default.env .env` and adjust network, Ethereum RPC URL, node ID, and desired version tags
* Add `BOR_SNAPSHOT` and `HEIMDALL_SNAPSHOT` URLs to `.env`

## Initial heimdalld peering

Initial heimdalld peering can be challenging, see https://wiki.polygon.technology/docs/maintain/validate/kb/known-issues/#log-error-dialing-seed. polygon-docker already sets the external IP and increased peering for heimdalld in its `config/config.toml` file.

If heimdalld cannot find peers after half an hour or so, a workaround is to take a `config/addrbook.json` from a working node, stop heimdalld, copy this file into the `config/` directory on the `heimdall-data` docker volume with the right permissions (`sudo bash` and standard cp/chown commands), and start heimdalld again.

## Sync check defaults

`./ethd check-sync` works without flags.

`./ethd check-sync` always runs inside the `heimdalld` compose service (the wrapper ignores `--compose-service` and `--container`). To target a different container, run `scripts/check_sync.sh` directly.

Bor local RPC default (container mode): `LOCAL_RPC`, `LOCAL_RPC_URL`, `HEIMDALL_BOR_RPC_URL`, then `BOR_RPC_PORT`, then `http://127.0.0.1:8545`.
Bor local RPC default (host mode): `LOCAL_RPC`, `LOCAL_RPC_URL`, `BOR_RPC_PORT`, `HEIMDALL_BOR_RPC_URL`, then `http://127.0.0.1:8545`.
Bor public RPC default: `PUBLIC_RPC` from `.env`, falling back to `https://polygon-rpc.com`.
Bor lag threshold default: `BLOCK_LAG=2`.

Heimdall local RPC default: `HEIMDALL_LOCAL_RPC` if set, otherwise `http://127.0.0.1:${HEIMDALL_RPC_PORT:-26657}`.
Heimdall public RPC default: `HEIMDALL_PUBLIC_RPC` from `.env` if set, else `https://heimdall-api.polygon.technology` for `NETWORK=mainnet`, else `https://heimdall-api-amoy.polygon.technology` for `NETWORK=amoy`. If `NETWORK` is not `mainnet` or `amoy`, set `HEIMDALL_PUBLIC_RPC` explicitly.
Heimdall lag threshold default: `HEIMDALL_BLOCK_LAG=2`.

Override precedence: CLI flags > environment variables > `--env-file`/`.env` values > built-in defaults.
Overrides: `--local-rpc`, `--public-rpc`, `--block-lag`, `--heimdall-local-rpc`, `--heimdall-public-rpc`, `--heimdall-block-lag`, `--compose-service`, `--container`, `--env-file`.

## Database format, pruning

Bor will use whatever format an existing DB is in, or fresh-sync with Pebble/PBSS. For legacy leveldb/hash DBs,
the command `./polygond prune-bor` is available, which prunes a long-running leveldb/hash DB back down.

If possible, use a Pebble/PBSS snapshot.

## Use with Shibarium

This repo works on Shibarium by adjusting the `NETWORK`, `HEIMDALL_SNAPSHOT`, `HEIMDALL_SEEDS` and `BOR_BOOTNODES`
as well as the `HEIMDALL_REPO`, `HEIMDALL_TAG` and `BOR_REPO` and `BOR_TAG` variables in `.env`.

# Version

This is Polygon Docker v3.0.0
