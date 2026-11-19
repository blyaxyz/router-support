#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "Run this connection setup as root on OpenWrt" >&2
    exit 1
}

SOURCE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_DIR="${ROUTER_SUPPORT_CONFIG_DIR:-/etc/router-support}"
BACKUP_DIR="/tmp/router-support-reconfigure.$$"
COMMITTED=0

[ -r "$CONFIG_DIR/config" ] && [ -r "$CONFIG_DIR/state" ] && \
[ -s "$CONFIG_DIR/uuid" ] && [ -s "$CONFIG_DIR/id_router_support" ] || {
    echo "A registered Router Support agent was not found; run install.sh" >&2
    exit 1
}

mkdir -p "$BACKUP_DIR"
cp "$CONFIG_DIR/config" "$BACKUP_DIR/config"
cp "$CONFIG_DIR/state" "$BACKUP_DIR/state"
if [ -f /root/.ssh/known_hosts ]; then
    cp /root/.ssh/known_hosts "$BACKUP_DIR/known_hosts"
fi
if [ -f /etc/dropbear/authorized_keys ]; then
    cp /etc/dropbear/authorized_keys "$BACKUP_DIR/authorized_keys"
fi

rollback() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$COMMITTED" -eq 0 ]; then
        cp "$BACKUP_DIR/config" "$CONFIG_DIR/config"
        cp "$BACKUP_DIR/state" "$CONFIG_DIR/state"
        if [ -f "$BACKUP_DIR/known_hosts" ]; then
            mkdir -p /root/.ssh
            cp "$BACKUP_DIR/known_hosts" /root/.ssh/known_hosts
            chmod 600 /root/.ssh/known_hosts
        else
            rm -f /root/.ssh/known_hosts
        fi
        if [ -f "$BACKUP_DIR/authorized_keys" ]; then
            cp "$BACKUP_DIR/authorized_keys" /etc/dropbear/authorized_keys
            chmod 600 /etc/dropbear/authorized_keys
        elif [ -f /etc/dropbear/authorized_keys ]; then
            temporary="/etc/dropbear/authorized_keys.router-support-rollback"
            grep -v ' router-support-server$' /etc/dropbear/authorized_keys \
                >"$temporary" || true
            chmod 600 "$temporary"
            mv "$temporary" /etc/dropbear/authorized_keys
        fi
        chmod 600 "$CONFIG_DIR/config" "$CONFIG_DIR/state"
        /etc/init.d/router-support restart 2>/dev/null || true
        echo "New connection failed; the previous connection was restored." >&2
    fi
    rm -rf "$BACKUP_DIR"
    exit "$status"
}
trap rollback EXIT HUP INT TERM

/etc/init.d/router-support stop 2>/dev/null || true
echo "Enter the new Router Support server and its connection token." >&2
"$SOURCE_DIR/install.sh" "$@"
COMMITTED=1
trap - EXIT HUP INT TERM
rm -rf "$BACKUP_DIR"
echo "The old connection was replaced successfully."
