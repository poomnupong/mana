#!/bin/bash
# Entrypoint: supervise required services and stream their logs.
set -euo pipefail

service_pids=()
cleanup() {
  kill "${service_pids[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Start SearXNG in background
echo "Starting SearXNG on :8080..."
SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml \
  /opt/hermes/.venv/bin/python -m searx.webapp &
service_pids+=("$!")
# Start Camofox in background
echo "Starting Camofox on :9377..."
HOME=/opt/data/home camofox-browser serve --port 9377 &
service_pids+=("$!")

    wait -n "${service_pids[@]}" || true
echo "A Hermes search/browser service exited; stopping the container. Check 'mana hermes logs'." >&2
    exit 1
