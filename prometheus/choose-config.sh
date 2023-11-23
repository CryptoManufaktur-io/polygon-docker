#!/bin/sh
# Avoid needing multiple grafana.yml files by checking CLIENT, which is COMPOSE_FILE, for the
# Prometheus config we need.
# Expects a full prometheus command with parameters as argument(s)

# Start fresh every time
cp /etc/prometheus/global.yml /etc/prometheus/prometheus.yml

if [ -f "/etc/prometheus/custom-prom.yml" ]; then
    cat /etc/prometheus/custom-prom.yml >> /etc/prometheus/prometheus.yml
fi

exec "$@" --config.file=/etc/prometheus/prometheus.yml
