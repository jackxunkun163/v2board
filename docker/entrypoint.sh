#!/bin/sh
# V2Board container entrypoint.
#
# Responsibilities (idempotent, safe to re-run on every container start):
#   1. Build .env from container environment on first boot.
#   2. Wait for the external MySQL to be reachable.
#   3. Import install.sql + create admin user on first boot only.
#   4. Refresh config cache.
#   5. Hand off to the main process (supervisord).
set -e

APP_DIR=/var/www/v2board
cd "$APP_DIR"

# ---------- helpers ----------
log() { printf '[entrypoint] %s\n' "$*"; }

set_env() {
    # set_env KEY VALUE  ->  replace or append KEY in .env
    key="$1"; val="$2"
    if grep -q "^${key}=" .env 2>/dev/null; then
        # Use a delimiter unlikely to appear in values.
        escaped=$(printf '%s' "$val" | sed 's/[&\\|]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped}|" .env
    else
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}

# ---------- 1. .env ----------
# APP_KEY is the JWT signing key (AuthService uses it for auth_data). If it
# changes across container rebuilds, every signed login token is invalidated
# and users get kicked back to the login page. We therefore persist it in the
# storage volume (which IS a named volume and survives rebuilds).
APPKEY_CACHE="${APP_DIR}/storage/.app-key"

if [ ! -f .env ]; then
    log "Initializing .env from .env.example"
    cp .env.example .env

    # APP_KEY precedence:
    #   1) cached copy in storage/ (stable across rebuilds — preferred)
    #   2) APP_KEY env var (lets users pin it via .env.docker)
    #   3) freshly generated (first boot only)
    if [ -f "$APPKEY_CACHE" ]; then
        APP_KEY=$(cat "$APPKEY_CACHE")
        log "Reusing APP_KEY from $APPKEY_CACHE"
    elif [ -n "$APP_KEY" ]; then
        log "Using APP_KEY from environment"
    else
        APP_KEY=$(php artisan key:generate --show)
        log "Generated new APP_KEY"
    fi
    set_env APP_KEY  "$APP_KEY"
    mkdir -p "$(dirname "$APPKEY_CACHE")"
    echo "$APP_KEY" > "$APPKEY_CACHE"

    set_env APP_ENV  "${APP_ENV:-production}"
    set_env APP_DEBUG "${APP_DEBUG:-false}"
    set_env APP_URL  "${APP_URL:-http://localhost}"

    set_env DB_CONNECTION "${DB_CONNECTION:-mysql}"
    set_env DB_HOST       "${DB_HOST:-127.0.0.1}"
    set_env DB_PORT       "${DB_PORT:-3306}"
    set_env DB_DATABASE   "${DB_DATABASE:-v2board}"
    set_env DB_USERNAME   "${DB_USERNAME:-root}"
    set_env DB_PASSWORD   "${DB_PASSWORD:-}"

    set_env REDIS_HOST     "${REDIS_HOST:-127.0.0.1}"
    set_env REDIS_PORT     "${REDIS_PORT:-6379}"
    [ -n "$REDIS_PASSWORD" ] && [ "$REDIS_PASSWORD" != "null" ] && set_env REDIS_PASSWORD "$REDIS_PASSWORD"

    # v2board requires redis-backed cache/queue/session in production.
    set_env CACHE_DRIVER     redis
    set_env QUEUE_CONNECTION redis
    set_env SESSION_DRIVER   redis

    log ".env written"
else
    log ".env exists, skipping initialization"
fi

# ---------- 2. wait for MySQL ----------
# Use PHP PDO (same driver Laravel uses) instead of `mysqladmin ping`:
# the mariadb-client shipped in Alpine produces false negatives against
# mysql:5.7 in some auth configurations.
MYSQL_READY=0
for i in $(seq 1 60); do
    if php /tmp/db-ping.php 2>/dev/null; then
        MYSQL_READY=1
        break
    fi
    log "Waiting for MySQL at ${DB_HOST}:${DB_PORT}... (${i}/60)"
    sleep 2
done
if [ "$MYSQL_READY" -ne 1 ]; then
    log "WARNING: MySQL not reachable after 120s; continuing anyway (init may fail)."
fi

# ---------- 3. first-boot DB init ----------
# Marker file lives under storage/ (persisted across container rebuilds via volume).
MARKER=storage/.docker-db-initialized
if [ ! -f "$MARKER" ]; then
    log "First-boot DB initialization"
    php /tmp/init-db.php || log "WARNING: init-db.php returned non-zero"
    mkdir -p storage
    touch "$MARKER"
else
    log "DB init marker present, skipping first-boot init"
fi

# ---------- 4. cache ----------
log "Refreshing config cache"
php artisan config:cache || log "WARNING: config:cache failed"
php artisan event:cache 2>/dev/null || true

# ---------- 5. hand off ----------
log "Starting: $*"
exec "$@"
