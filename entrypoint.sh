#!/bin/sh
# Semaphore UI Railway wrapper entrypoint.
#
# What it does, in order:
# - PORT: Railway injects PORT at runtime. Semaphore reads its HTTP
#   port from SEMAPHORE_PORT only (default :3000; verified in
#   semaphoreui/semaphore v2.20.23 util/config.go:683 — env
#   "SEMAPHORE_PORT"). Export SEMAPHORE_PORT=$PORT on every boot.
#   Fail loud if the remap did not land — a server listening on the
#   wrong port is a silent dead deploy.
# - VOLUME: fail loud if /data is not available, then pre-create
#   the config and DB dirs on it. config.json (cookie hash +
#   encryption keys, written by `semaphore setup` on first boot)
#   and database.sqlite both live here, so both survive redeploys.
# - ACCESS KEY ENCRYPTION: generate once per volume and reuse on
#   every boot. SEMAPHORE_ACCESS_KEY_ENCRYPTION must be base64 of
#   32 random bytes (validated by util/config.go); unset means
#   stored credentials are kept in plain text. The value is never
#   in the repo or the deploy form.
# - PUBLIC URL: derive SEMAPHORE_WEB_ROOT at boot from the live
#   RAILWAY_PUBLIC_DOMAIN. A template-expression default
#   (https://${{RAILWAY_PUBLIC_DOMAIN}}) resolves to a bare
#   "https://" on first deploy (no domain exists yet); env is read
#   over config.json on every boot, so the boot-derived value
#   always wins.
# - HANDOFF: exec tini + the image's own server-wrapper exactly as
#   the image does. On first boot it runs `semaphore setup -` and
#   seeds the admin account from SEMAPHORE_ADMIN* env vars, then
#   starts the server.

set -eu

PORT_VALUE="${PORT:-3000}"
export SEMAPHORE_PORT="$PORT_VALUE"

if [ "$SEMAPHORE_PORT" != "$PORT_VALUE" ]; then
  echo "Semaphore: ERROR HTTP port remap failed; refusing to start."
  exit 1
fi

# The volume must be mounted: config.json and the SQLite DB both
# live under /data and must survive redeploys.
[ -d /data ] || { echo "Semaphore: ERROR /data not available; refusing to start."; exit 1; }
mkdir -p /data/config /data/db

# Access-key encryption key, seeded exactly once per volume.
KEY_FILE=/data/config/access-key-encryption
if [ ! -f "$KEY_FILE" ]; then
  head -c32 /dev/urandom | base64 | tr -d '\n' > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  echo "Semaphore: generated access-key encryption key (stored on volume)"
fi
export SEMAPHORE_ACCESS_KEY_ENCRYPTION="$(cat "$KEY_FILE")"

# Public URL: derive at boot from the live Railway domain.
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export SEMAPHORE_WEB_ROOT="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

echo "Semaphore: HTTP on :${PORT_VALUE}, config+db in /data"
exec /sbin/tini -- /usr/local/bin/server-wrapper
