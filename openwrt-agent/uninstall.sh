#!/bin/sh
set -eu

CONFIG_DIR="${ROUTER_SUPPORT_CONFIG_DIR:-/etc/router-support}"
CONFIG_FILE="$CONFIG_DIR/config"
STATE_FILE="$CONFIG_DIR/state"
PURGE=0

usage() {
    cat >&2 <<'EOF'
Usage: uninstall.sh [--purge]

Without --purge the service is removed but UUID, device token and keys are preserved.
With --purge all router-support identity files are permanently removed.
EOF
    exit 2
}

case "${1:-}" in
    "") ;;
    --purge) PURGE=1 ;;
    -h|--help) usage ;;
    *) usage ;;
esac
[ "$#" -le 1 ] || usage

SSH_HOST=""
SSH_SERVER_PORT="22"
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi
if [ -r "$STATE_FILE" ]; then
    # shellcheck source=/dev/null
    . "$STATE_FILE"
fi

if [ -x /etc/init.d/router-support ]; then
    /etc/init.d/router-support stop || true
    /etc/init.d/router-support disable || true
fi

remove_matching_line() {
    file="$1"
    pattern="$2"
    [ -f "$file" ] || return 0
    temporary="$file.router-support.tmp"
    grep -vF "$pattern" "$file" >"$temporary" || true
    chmod 600 "$temporary"
    mv "$temporary" "$file"
}

authorized_keys="/etc/dropbear/authorized_keys"
if [ -f "$authorized_keys" ]; then
    temporary="$authorized_keys.router-support.tmp"
    grep -v ' router-support-server$' "$authorized_keys" >"$temporary" || true
    chmod 600 "$temporary"
    mv "$temporary" "$authorized_keys"
fi

if [ -n "$SSH_HOST" ]; then
    if [ "${SSH_SERVER_PORT:-22}" = "22" ]; then
        known_host_target="$SSH_HOST"
    else
        known_host_target="[$SSH_HOST]:$SSH_SERVER_PORT"
    fi
    for known_hosts in \
        /.ssh/known_hosts \
        /root/.ssh/known_hosts \
        "$CONFIG_DIR/.ssh/known_hosts"; do
        remove_matching_line "$known_hosts" "$known_host_target "
    done
fi

rm -f /etc/init.d/router-support
rm -f /usr/sbin/router-support
rm -f /usr/sbin/router-support-uninstall

if [ "$PURGE" -eq 1 ]; then
    rm -f "$CONFIG_DIR/config"
    rm -f "$CONFIG_DIR/state"
    rm -f "$CONFIG_DIR/uuid"
    rm -f "$CONFIG_DIR/id_router_support"
    rm -f "$CONFIG_DIR/.ssh/known_hosts"
    rmdir "$CONFIG_DIR/.ssh" 2>/dev/null || true
    rmdir "$CONFIG_DIR" 2>/dev/null || true
    echo "router-support removed; UUID, token and device key purged"
else
    echo "router-support removed; identity preserved in $CONFIG_DIR"
    echo "Run with --purge to permanently remove UUID, token and device key"
fi

