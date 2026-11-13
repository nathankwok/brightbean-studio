#!/usr/bin/env bash
# Check that no container publishes a port on a public address and that .env
# holds production values. Prints PASS lines; prints FAIL and exits 1 otherwise.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Reason: capture first, so a docker ps that fails aborts the script instead of
# feeding grep nothing and printing a false PASS.
ports=$(docker ps --format '{{.Names}} {{.Ports}}')
if grep -E '0\.0\.0\.0|:::|\[::\]:' <<<"$ports"; then
  echo "FAIL public port"
  exit 1
fi
echo "PASS ports loopback only"

fail() { echo "FAIL env $1"; exit 1; }
[ -f .env ] || fail "missing .env"
[ "$(stat -c %a .env)" = 600 ] || fail "mode is not 600"
grep -qx 'SIGNUP_MODE=closed' .env || fail "SIGNUP_MODE is not closed"
grep -qx 'DEBUG=false' .env || fail "DEBUG is not false"
if grep -qE '^(SECRET_KEY|ENCRYPTION_KEY_SALT|WEBHOOK_SECRET)=(change-me.*)?$' .env; then
  fail "SECRET_KEY, ENCRYPTION_KEY_SALT or WEBHOOK_SECRET is empty or change-me"
fi
echo "PASS env"
