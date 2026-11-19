#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="/opt/router-support"

[ -f /etc/router-support/backend.env ] && \
[ -f /etc/systemd/system/router-support.service ] && \
[ -x "$INSTALL_ROOT/.venv/bin/pip" ] || {
    echo "A complete Router Support installation was not found; run install-server.sh" >&2
    exit 1
}

# Migrate installations where useradd left the key-only tunnel account locked.
if passwd -S router-tunnel 2>/dev/null | grep -q ' L '; then
    random_password="$(openssl rand -hex 32)"
    random_password_hash="$(openssl passwd -6 "$random_password")"
    usermod --password "$random_password_hash" router-tunnel
    unset random_password random_password_hash
fi

for directory in backend frontend openwrt-agent deploy scripts docs; do
    install -d -o root -g root -m 0755 "$INSTALL_ROOT/$directory"
    cp -a "$PROJECT_ROOT/$directory/." "$INSTALL_ROOT/$directory/"
done
cp "$PROJECT_ROOT/requirements.txt" "$INSTALL_ROOT/requirements.txt"
cp "$PROJECT_ROOT/README.md" "$INSTALL_ROOT/README.md"
"$INSTALL_ROOT/.venv/bin/pip" install -r "$INSTALL_ROOT/requirements.txt"
systemctl restart router-support.service
sleep 2
curl --fail --silent --show-error http://127.0.0.1:8000/healthz
echo
echo "Update complete"

