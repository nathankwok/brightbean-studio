#!/usr/bin/env bash
# Build and start the VPS stack (Supabase Postgres, Caddy on 127.0.0.1:8710),
# then check ports and .env.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ ! -f .env ]; then
  echo "No .env in $PWD. Create it from deploy/vps/env.example with mode 0600." >&2
  exit 1
fi
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.vps.yml up -d --build
deploy/vps/check-ports.sh
