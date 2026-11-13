# VPS deployment

BrightBean Studio on one VPS: the database is a hosted Supabase project, every
container port is bound to 127.0.0.1, and a Cloudflare Tunnel with Cloudflare
Access is the only way in from the internet. Caddy listens on
`127.0.0.1:8710` and the tunnel points at it.

The stack is the two upstream compose files plus the VPS override, always run
from the repo root:

```bash
COMPOSE="docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.vps.yml"
```

## Files

| File | What it does |
|---|---|
| `docker-compose.vps.yml` | Override on top of `docker-compose.yml` and `docker-compose.prod.yml`. Moves the bundled `postgres` service into the unused `local-db` profile, drops the `DATABASE_URL` that `docker-compose.prod.yml` pins on `migrate` (so it comes from `.env`), clears every public port, binds Caddy to `127.0.0.1:8710`, gives Caddy the fixed address `172.31.71.10` on subnet `172.31.71.0/24`, mounts `deploy/vps/certs` read-only at `/app/certs`, and sets the memory settings below. |
| `Caddyfile.vps` | Plain HTTP on port 80 inside the network (TLS ends at Cloudflare). Serves only `/media/media_library/`, `/media/avatars/` and `/media/workspaces/icons/` from the read-only media volume and returns 404 for any other `/media/` path. Returns 404 for `/api/v1/docs` and `/api/v1/openapi.json`. Proxies the rest to `app:8000` with `X-Forwarded-Proto: https` and `X-Forwarded-For` set from Cloudflare's `CF-Connecting-IP`. |
| `deploy/vps/env.example` | Every `.env` key the VPS needs, grouped and commented. |
| `deploy/vps/up.sh` | Refuses to run without `.env`, builds and starts the stack, then runs `check-ports.sh`. |
| `deploy/vps/check-ports.sh` | Prints `PASS ports loopback only` when no running container publishes on `0.0.0.0` or `::`, then `PASS env` when `.env` has mode 600, `SIGNUP_MODE=closed`, `DEBUG=false`, and no empty or `change-me` value for `SECRET_KEY`, `ENCRYPTION_KEY_SALT` or `WEBHOOK_SECRET`. Prints `FAIL ...` and exits 1 otherwise. |
| `deploy/vps/run-tests.sh` | Runs the test suite the way CI does: Postgres 16 in a throwaway container, `makemigrations --check`, then pytest. Extra arguments go to pytest. |
| `deploy/vps/certs/` | Holds `supabase-ca.crt`. Ignored by git and by Docker builds. |

`.dockerignore` keeps `.env`, `.env.*`, `deploy/vps/certs/` and `.git` out of
the build context. The Dockerfile copies the whole context into the image, and
Django reads `.env` from the app directory at startup, so without these lines
every image would carry the Supabase password and `SECRET_KEY`, and test runs
would read production values.

## Setup order

1. **Supabase.** From the project's Connect page copy the Session pooler string
   (port 5432, user `postgres.<ref>`). From Database settings download the SSL
   CA certificate and save it on the VPS:

   ```bash
   mkdir -p deploy/vps/certs
   # copy the downloaded certificate to deploy/vps/certs/supabase-ca.crt
   ```

2. **`.env`.** Create it from the example with mode 0600, then fill the values
   its header lists in an editor on the VPS. Never paste them into chat or a
   ticket.

   ```bash
   install -m 600 deploy/vps/env.example .env
   python3 -c "import secrets; print(secrets.token_urlsafe(64))"   # once per generated secret
   ```

   `DATABASE_URL` takes the pooler string with the password URL-encoded and
   `?sslmode=verify-full&sslrootcert=/app/certs/supabase-ca.crt` appended.

3. **Start.** `deploy/vps/up.sh`. The `migrate` container runs the migrations
   against Supabase and exits 0 before `app` and `worker` start. The script
   ends with `PASS ports loopback only` and `PASS env`.

4. **First user.** Sign-up is closed, so create the first account here:

   ```bash
   $COMPOSE exec app python manage.py createsuperuser
   ```

5. **Cloudflare Tunnel and Access.** Two public hostname rules on the tunnel,
   above the catch-all and in this order:

   - Rule 1: hostname `social.metamcpserver.xyz`, path
     `^/(webhooks/facebook/$|api/v1/[A-Za-z0-9/_-]*$|media/media_library/(thumbs/|versions/)?[0-9]{4}/[0-9]{2}/[A-Za-z0-9_-][A-Za-z0-9_.-]*$)`,
     service `http://localhost:8710`, no Access enforcement.
   - Rule 2: hostname `social.metamcpserver.xyz`, no path, service
     `http://localhost:8710`, with Protect with Access on (team name and the
     AUD tag of the `social` application).

   Access applications:

   - `social`: self-hosted, host `social.metamcpserver.xyz`, Allow policy for
     the operator's email addresses, one-time email code login, 1 month session.
   - `social-admin`: destinations `social.metamcpserver.xyz/admin` and
     `social.metamcpserver.xyz/admin/*`, same policy, 1 week session.
   - `social-public`: destinations `/webhooks/facebook/`, `/media/media_library/`
     and `/api/v1/` on the same host, Bypass policy for everyone.

   A WAF custom rule skips Browser Integrity Check for that host when the path
   starts with `/webhooks/facebook/`, `/media/media_library/` or `/api/v1/`,
   so platform webhooks, platform media fetches and API clients get through.

## Day to day

All commands run from the repo root.

| Task | Command |
|---|---|
| Start or rebuild | `deploy/vps/up.sh` |
| Stop | `$COMPOSE down` (never add `-v`: it deletes the media volume) |
| Status | `$COMPOSE ps -a` |
| Logs | `$COMPOSE logs -f --tail 200 app worker caddy` |
| Migration log | `$COMPOSE logs migrate` |
| Django shell | `$COMPOSE exec app python manage.py shell` |
| Port and `.env` check | `deploy/vps/check-ports.sh` |
| Tests | `deploy/vps/run-tests.sh` (extra arguments go to pytest) |

## Memory and connection settings

The memory budget for the whole stack is 1.5 GB, and the Supabase session
pooler allows 15 connections.

- **Gunicorn 1 worker, 4 threads** (`docker-compose.vps.yml`, `app`).
  `docker-compose.prod.yml` runs 4 workers with 2 threads. Each worker process
  costs about 100 MB just to import the app, and the Dockerfile budgets about
  250 MB per worker, so 4 workers alone would use most of the 1.5 GB. One threaded worker handles
  this single-user load.
- **`MALLOC_ARENA_MAX=2`** (`app` and `worker`). glibc gives each thread its
  own malloc arena, up to 8 per CPU core, and memory freed in one arena is not
  reused by another, so a threaded process keeps growing. Two arenas keep the
  resident size close to what the process is using.
- **`run_studio_worker --sleep 5`** (`worker`). The dispatcher polls the
  database every second by default. Over the network to Supabase that is a
  steady stream of queries and egress; a 5 second poll delays a scheduled post
  by at most 5 seconds.
- **`PUBLISHER_MAX_CONCURRENT_POSTS=2` and
  `PUBLISHER_MAX_CONCURRENT_PLATFORM_PUBLISHES=3`** (`.env`). Each publish
  thread holds its own database connection. These two plus the 4 Gunicorn
  threads keep the peak near 12 connections, under the pooler's 15.
- **`PUBLISHER_PUBLISH_CONFIRM_TIMEOUT=3600`** (`.env`). A post the platform
  accepted but is still processing (video transcoding) gets up to an hour to
  confirm before it is marked failed.
