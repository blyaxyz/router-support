#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
ENV_FILE="/etc/router-support/backend.env"
DB_FILE="/opt/router-support/data/router-support.db"
DOMAIN="$(sed -n 's/^ROUTER_SUPPORT_PUBLIC_DOMAIN=//p' "$ENV_FILE")"
TLS_IP="$(sed -n 's/^ROUTER_SUPPORT_TLS_IP=//p' "$ENV_FILE")"
TELEMT_INTEGRATION="$(sed -n 's/^ROUTER_SUPPORT_TELEMT_INTEGRATION=//p' "$ENV_FILE")"
[ -n "$DOMAIN" ] || { echo "Public domain is not configured" >&2; exit 1; }

mapfile -t ROUTER_IDS < <(
    python3 -c "import sqlite3; c=sqlite3.connect('$DB_FILE'); [print(r[0]) for r in c.execute('SELECT id FROM routers ORDER BY id')]"
)
[ "${#ROUTER_IDS[@]}" -gt 0 ] || { echo "No registered routers"; exit 0; }
if [ "$TELEMT_INTEGRATION" = "1" ]; then
    [ "${#ROUTER_IDS[@]}" -le 30 ] || {
        echo "More than 30 routers requires a wildcard certificate via DNS challenge" >&2
        exit 1
    }
elif [ -n "$TLS_IP" ]; then
    [ "${#ROUTER_IDS[@]}" -le 7 ] || {
        echo "IP short-lived certificates support this layout for at most 7 routers (25 names)" >&2
        echo "Use domain mode with a wildcard certificate for a larger fleet" >&2
        exit 1
    }
else
    [ "${#ROUTER_IDS[@]}" -le 30 ] || {
        echo "More than 30 routers requires a wildcard certificate via DNS challenge" >&2
        exit 1
    }
fi

CERT_ARGS=(-d "$DOMAIN")
for router_id in "${ROUTER_IDS[@]}"; do
    CERT_ARGS+=(
        -d "luci-r${router_id}.${DOMAIN}"
        -d "v2raya-r${router_id}.${DOMAIN}"
        -d "app-r${router_id}.${DOMAIN}"
    )
done

if [ "$TELEMT_INTEGRATION" = "1" ]; then
    certbot certonly --webroot --webroot-path /var/www/router-support-acme \
        --cert-name router-support-domain --expand \
        --non-interactive --agree-tos "${CERT_ARGS[@]}"
elif [ -n "$TLS_IP" ]; then
    /opt/router-support-certbot/bin/certbot certonly \
        --non-interactive --agree-tos --expand \
        --preferred-profile shortlived \
        --webroot --webroot-path /var/www/router-support-acme \
        --cert-name router-support-ip --ip-address "$TLS_IP" \
        "${CERT_ARGS[@]}"
else
    certbot --apache --cert-name "$DOMAIN" --expand \
        --non-interactive --agree-tos --redirect "${CERT_ARGS[@]}"
fi
apache2ctl configtest
systemctl reload apache2
if [ "$TELEMT_INTEGRATION" = "1" ]; then
    /opt/router-support/deploy/configure-telemt-route.sh
fi
echo "TLS domains synchronized for ${#ROUTER_IDS[@]} router(s)"

