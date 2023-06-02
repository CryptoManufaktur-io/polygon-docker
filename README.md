# polygon-docker: Docker automation for Polygon RPC nodes

## Overview

polygon-docker follows [eth-docker](https://eth-docker.net) conventions. A lot of the same basic patterns,
such as for traefik access, apply.

## Getting Started

For a quick start, you can install prerequisites and configure polygon-docker, as a non-root user:

* `cd ~ && git clone https://github.com/CryptoManufaktur-io/polygon-docker.git && cd polygon-docker`
* `./ethd install`
* `cp default.env .env` and adjust snapshot locations.

## Initial heimdalld peering

Initial heimdalld peering can be challenging, see https://wiki.polygon.technology/docs/maintain/validate/kb/known-issues/#log-error-dialing-seed. polygon-docker already sets the external IP and increased peering for heimdalld in its `config/config.toml` file.

If heimdalld cannot find peers after half an hour or, a workaround is to take a `config/addrbook.json` from a working node, stop heimdalld, copy this file into the `config/` directory on the `heimdall-data` docker volume with the right permissions (`sudo bash` and standard cp/chown commands), and start heimdalld again.

## License

[Apache License v2](https://github.com/CryptoManufaktur-io/polygon-docker/blob/main/LICENSE)

# Version

This is polygon-docker v1.1
