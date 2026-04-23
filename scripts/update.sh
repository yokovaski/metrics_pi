#!/usr/bin/env bash
# Pull latest config, restart the Telegraf container, tail logs.
# Run on each Pi: `bash scripts/update.sh` (or `./scripts/update.sh`).
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> git pull"
git pull --ff-only

# --build only when Dockerfile or build context changed; plain `up -d`
# picks up telegraf.conf edits via the bind mount without a rebuild.
if git diff --name-only HEAD@{1} HEAD 2>/dev/null | grep -q '^docker/'; then
  echo "==> docker compose up -d --build (Dockerfile changed)"
  docker compose up -d --build
else
  echo "==> docker compose up -d"
  docker compose up -d
fi

echo "==> tailing telegraf logs (Ctrl-C to exit)"
exec docker compose logs -f telegraf
