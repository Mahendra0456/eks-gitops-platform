#!/bin/bash
# Usage: ./scripts/traffic.sh <app-host> [parallel]   (stop with: pkill -f traffic.sh)
HOST="$1"
N="${2:-3}"
if [ -z "$HOST" ]; then echo "usage: $0 <app-host> [parallel]"; exit 1; fi
for _ in $(seq "$N"); do
  ( while true; do curl -s -o /dev/null --max-time 15 "http://$HOST/api/products"; sleep 0.2; done ) &
done
wait
