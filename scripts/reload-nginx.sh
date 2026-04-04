#!/usr/bin/env sh
# Перезагрузка текущего сгенерированного конфига. Новые/изменённые *.vhost — docker compose restart nginx
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
echo "nginx config OK and reloaded."
