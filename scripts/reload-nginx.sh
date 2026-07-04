#!/usr/bin/env sh
# Reload the currently active generated nginx config. New or changed *.vhost still need docker compose restart nginx.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
echo "nginx config OK and reloaded."
