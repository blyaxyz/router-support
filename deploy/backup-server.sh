#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
BACKUP_DIR="${1:-/var/backups/router-support}"
install -d -o root -g root -m 0700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="$BACKUP_DIR/router-support-$STAMP.tar.gz"
tar -czf "$ARCHIVE" \
    /etc/router-support/backend.env \
    /opt/router-support/data \
    /etc/apache2/sites-available/router-support.conf \
    /etc/ssh/sshd_config.d/router-support.conf
chmod 0600 "$ARCHIVE"
echo "$ARCHIVE"

