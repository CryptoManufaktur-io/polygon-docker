# Polygon Docker: Docker automation for Polygon RPC nodes

## Overview

Polygon Docker follows [Eth Docker](https://eth-docker.net) conventions. A lot of the same basic patterns,
such as for traefik access, apply.

## Getting Started

For a quick start, you can install prerequisites and configure Polygon Docker, as a non-root user:

* `cd ~ && git clone https://github.com/CryptoManufaktur-io/polygon-docker.git && cd polygon-docker`
* `./polygond install`
* `cp default.env .env` and adjust network, Ethereum RPC URL, node ID, and desired version tags
* Add `BOR_SNAPSHOT` and `HEIMDALL_SNAPSHOT` URLs to `.env`

## Initial heimdalld peering

Initial heimdalld peering can be challenging, see https://wiki.polygon.technology/docs/maintain/validate/kb/known-issues/#log-error-dialing-seed. polygon-docker already sets the external IP and increased peering for heimdalld in its `config/config.toml` file.

If heimdalld cannot find peers after half an hour or so, a workaround is to take a `config/addrbook.json` from a working node, stop heimdalld, copy this file into the `config/` directory on the `heimdall-data` docker volume with the right permissions (`sudo bash` and standard cp/chown commands), and start heimdalld again.

## Database format, pruning

Bor will use whatever format an existing DB is in, or fresh-sync with Pebble/PBSS. For legacy leveldb/hash DBs,
the command `./polygond prune-bor` is available, which prunes a long-running leveldb/hash DB back down.

If possible, use a Pebble/PBSS snapshot.

## License

[Apache License v2](https://github.com/CryptoManufaktur-io/polygon-docker/blob/main/LICENSE)

# Version

This is Polygon Docker v2.3.0
