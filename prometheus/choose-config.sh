#!/bin/sh
# Avoid needing multiple grafana.yml files by checking CLIENT, which is COMPOSE_FILE, for the
# Prometheus config we need.
# Expects a full prometheus command with parameters as argument(s)

# Start fresh every time
cp /etc/prometheus/global.yml /etc/prometheus/prometheus.yml

case "$CLIENT" in
  *bor* ) cat /etc/prometheus/bor-prom.yml >> /etc/prometheus/prometheus.yml ;;
esac

case "$CLIENT" in
  *traefik-* ) cat /etc/prometheus/traefik-prom.yml >> /etc/prometheus/prometheus.yml;;
esac

if [ -f "/etc/prometheus/custom-prom.yml" ]; then
    cat /etc/prometheus/custom-prom.yml >> /etc/prometheus/prometheus.yml
fi

exec "$@" --config.file=/etc/prometheus/prometheus.yml
