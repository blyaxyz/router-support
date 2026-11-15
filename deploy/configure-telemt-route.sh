#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

ENV_FILE="${ROUTER_SUPPORT_ENV_FILE:-/etc/router-support/backend.env}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_FILE="${ROUTER_SUPPORT_TELEMT_CONFIG:-}"
TELEMT_SERVICE="${ROUTER_SUPPORT_TELEMT_SERVICE:-telemt.service}"
INTERNAL_PORT="${ROUTER_SUPPORT_INTERNAL_HTTPS_PORT:-}"
DB_FILE="/opt/router-support/data/router-support.db"

if [ -f "$ENV_FILE" ]; then
    [ -n "$CONFIG_FILE" ] || \
        CONFIG_FILE="$(sed -n 's/^ROUTER_SUPPORT_TELEMT_CONFIG=//p' "$ENV_FILE")"
    [ -n "$INTERNAL_PORT" ] || \
        INTERNAL_PORT="$(sed -n 's/^ROUTER_SUPPORT_INTERNAL_HTTPS_PORT=//p' "$ENV_FILE")"
fi
[ -n "$INTERNAL_PORT" ] || INTERNAL_PORT=8443

if [ -z "$CONFIG_FILE" ]; then
    for candidate in /etc/telemt/telemt.toml /etc/telemt/config.toml; do
        if [ -f "$candidate" ]; then
            CONFIG_FILE="$candidate"
            break
        fi
    done
fi
[ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || {
    echo "Telemt configuration was not found; set ROUTER_SUPPORT_TELEMT_CONFIG" >&2
    exit 1
}
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE" >&2; exit 1; }
systemctl is-active --quiet "$TELEMT_SERVICE" || {
    echo "$TELEMT_SERVICE is not active" >&2
    exit 1
}

DOMAIN="$(sed -n 's/^ROUTER_SUPPORT_PUBLIC_DOMAIN=//p' "$ENV_FILE")"
[ -n "$DOMAIN" ] || { echo "Public domain is not configured" >&2; exit 1; }
case "$DOMAIN" in *[!A-Za-z0-9.-]*) echo "Unsafe public domain" >&2; exit 1 ;; esac
case "$INTERNAL_PORT" in ''|*[!0-9]*) echo "Invalid internal HTTPS port" >&2; exit 1 ;; esac
[ "$INTERNAL_PORT" -ge 1 ] && [ "$INTERNAL_PORT" -le 65535 ] || {
    echo "Invalid internal HTTPS port" >&2
    exit 1
}

DOMAINS=("$DOMAIN")
if [ -f "$DB_FILE" ]; then
    mapfile -t ROUTER_IDS < <(
        python3 -c "import sqlite3; c=sqlite3.connect('$DB_FILE'); [print(r[0]) for r in c.execute('SELECT id FROM routers ORDER BY id')]"
    )
    for router_id in "${ROUTER_IDS[@]}"; do
        DOMAINS+=(
            "luci-r${router_id}.${DOMAIN}"
            "v2raya-r${router_id}.${DOMAIN}"
            "app-r${router_id}.${DOMAIN}"
        )
    done
fi

ROLLBACK_FILE="$(mktemp /tmp/router-support-telemt.XXXXXX)"
cp -a "$CONFIG_FILE" "$ROLLBACK_FILE"
if [ ! -f "$CONFIG_FILE.router-support-backup" ]; then
    cp -a "$CONFIG_FILE" "$CONFIG_FILE.router-support-backup"
fi

ROLLBACK_NEEDED=1
finish() {
    status="$?"
    trap - EXIT
    if [ "$status" -ne 0 ] && [ "$ROLLBACK_NEEDED" -eq 1 ]; then
        echo "Restoring the previous Telemt configuration" >&2
        cp -a "$ROLLBACK_FILE" "$CONFIG_FILE"
        systemctl restart "$TELEMT_SERVICE" || true
    fi
    rm -f "$ROLLBACK_FILE"
    exit "$status"
}
trap finish EXIT

python3 "$SCRIPT_DIR/update_telemt_config.py" \
    "$CONFIG_FILE" "$INTERNAL_PORT" "${DOMAINS[@]}"

if ! systemctl restart "$TELEMT_SERVICE"; then
    echo "Telemt rejected the Router Support routes" >&2
    exit 1
fi
if ! systemctl is-active --quiet "$TELEMT_SERVICE"; then
    echo "Telemt is not active after restart" >&2
    exit 1
fi
if ! curl -fsS --connect-timeout 5 --max-time 10 \
    --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/healthz" >/dev/null; then
    echo "Telemt SNI route health check failed; the previous configuration was restored" >&2
    exit 1
fi

ROLLBACK_NEEDED=0
echo "Telemt routes synchronized for ${#DOMAINS[@]} domain(s) via 127.0.0.1:$INTERNAL_PORT"
