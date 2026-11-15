#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

assume_yes=0
if [ "${1:-}" = "--yes" ]; then
    assume_yes=1
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--yes]" >&2
    exit 2
fi

if [ "$assume_yes" -eq 0 ]; then
    echo "This removes Router Support services, configuration, database and keys." >&2
    echo "A recovery archive will be created first in /var/backups/router-support." >&2
    printf 'Type REMOVE to continue: ' >&2
    confirmation=""
    if [ -r /dev/tty ]; then
        IFS= read -r confirmation </dev/tty || true
    else
        IFS= read -r confirmation || true
    fi
    [ "$confirmation" = "REMOVE" ] || {
        echo "Removal cancelled."
        exit 0
    }
fi

ENV_FILE="/etc/router-support/backend.env"
TELEMT_CONFIG=""
if [ -r "$ENV_FILE" ]; then
    TELEMT_CONFIG="$(sed -n 's/^ROUTER_SUPPORT_TELEMT_CONFIG=//p' "$ENV_FILE" | head -n 1)"
fi

BACKUP_DIR="/var/backups/router-support"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
BACKUP_ARCHIVE="$BACKUP_DIR/router-support-before-removal-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
backup_paths=()
[ -d /etc/router-support ] && backup_paths+=(/etc/router-support)
[ -d /opt/router-support/data ] && backup_paths+=(/opt/router-support/data)
if [ "${#backup_paths[@]}" -gt 0 ]; then
    tar -czf "$BACKUP_ARCHIVE" "${backup_paths[@]}"
    chmod 0600 "$BACKUP_ARCHIVE"
else
    BACKUP_ARCHIVE=""
fi

systemctl disable --now router-support.service 2>/dev/null || true
systemctl disable --now router-support-certbot.timer 2>/dev/null || true
systemctl stop router-support-certbot.service 2>/dev/null || true

if command -v a2dissite >/dev/null 2>&1; then
    a2dissite router-support.conf router-support-ip-ssl.conf \
        router-support-le-ssl.conf >/dev/null 2>&1 || true
fi
rm -f /etc/apache2/sites-enabled/router-support.conf \
    /etc/apache2/sites-enabled/router-support-ip-ssl.conf \
    /etc/apache2/sites-enabled/router-support-le-ssl.conf \
    /etc/apache2/sites-available/router-support.conf \
    /etc/apache2/sites-available/router-support-ip-ssl.conf \
    /etc/apache2/sites-available/router-support-le-ssl.conf

if [ -f /etc/apache2/ports.conf.router-support-backup ]; then
    cp -a /etc/apache2/ports.conf.router-support-backup /etc/apache2/ports.conf
    rm -f /etc/apache2/ports.conf.router-support-backup
fi
if [ -n "$TELEMT_CONFIG" ] && [[ "$TELEMT_CONFIG" = /* ]] && \
   [ -f "$TELEMT_CONFIG.router-support-backup" ]; then
    cp -a "$TELEMT_CONFIG.router-support-backup" "$TELEMT_CONFIG"
    rm -f "$TELEMT_CONFIG.router-support-backup"
fi

rm -f /etc/ssh/sshd_config.d/router-support.conf \
    /etc/tmpfiles.d/router-support-sshd.conf \
    /etc/systemd/system/router-support.service \
    /etc/systemd/system/router-support-certbot.service \
    /etc/systemd/system/router-support-certbot.timer \
    /etc/letsencrypt/renewal-hooks/deploy/router-support-apache

systemctl daemon-reload
systemctl reset-failed router-support.service router-support-certbot.service \
    router-support-certbot.timer 2>/dev/null || true
systemctl restart apache2 2>/dev/null || true
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
if [ -n "$TELEMT_CONFIG" ]; then
    systemctl restart telemt.service 2>/dev/null || true
fi
systemctl enable --now certbot.timer 2>/dev/null || true

if id router-tunnel >/dev/null 2>&1; then
    userdel router-tunnel 2>/dev/null || true
fi
rm -rf /opt/router-support /opt/router-support-certbot \
    /etc/router-support /var/lib/router-tunnel /var/www/router-support-acme

echo "Router Support has been removed."
if [ -n "$BACKUP_ARCHIVE" ]; then
    echo "Recovery archive: $BACKUP_ARCHIVE"
fi
echo "Installed Debian packages and Let's Encrypt certificate archives were retained."
