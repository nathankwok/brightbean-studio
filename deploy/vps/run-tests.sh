#!/usr/bin/env bash
# Run the fork's test suite the way CI does: Postgres 16 in a throwaway
# container, makemigrations --check, then pytest. Extra args go to pytest.
set -euo pipefail
cd "$(dirname "$0")/../.."
NET=bbtest-net
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
# Reason: names carry the shell's PID so two runs (an implementer and a
# reviewer) never remove each other's database.
PG=bbtest-pg-$$
docker run -d --rm --name "$PG" --network "$NET" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=brightbean_test postgres:16-alpine >/dev/null
trap 'docker rm -f "$PG" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 60); do docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker build -q -t brightbean-fork:test . >/dev/null
docker run --rm --network "$NET" -e DB_HOST="$PG" -e DJANGO_SETTINGS_MODULE=config.settings.test \
  brightbean-fork:test sh -c 'python manage.py makemigrations --check --dry-run && pytest -q -p no:cacheprovider "$@"' sh "$@"
