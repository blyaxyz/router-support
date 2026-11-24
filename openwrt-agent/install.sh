#!/bin/sh
set -eu

usage() {
    echo "usage: $0 [server-url] [bootstrap-token]" >&2
    echo "       $0 -server domain-or-url -token connection-token" >&2
    echo "with no arguments the installer starts an interactive setup" >&2
    echo "or set ROUTER_SUPPORT_BOOTSTRAP_TOKEN in the environment" >&2
    exit 2
}

prompt_secret() {
    prompt="$1"
    secret_value=""
    if [ -r /dev/tty ]; then
        if command -v stty >/dev/null 2>&1; then
            terminal_state="$(stty -g </dev/tty)"
            printf '%s' "$prompt" >&2
            trap 'stty "$terminal_state" </dev/tty' 0 1 2 15
            stty -echo </dev/tty
            IFS= read -r secret_value </dev/tty
            stty "$terminal_state" </dev/tty
            trap - 0 1 2 15
            printf '\n' >&2
        else
            printf '%s' "$prompt" >&2
            IFS= read -r secret_value </dev/tty
            printf '\nWarning: stty is unavailable; the token was visible while typing.\n' >&2
        fi
    else
        printf '%s' "$prompt" >&2
        IFS= read -r secret_value
    fi
    BOOTSTRAP_TOKEN="$secret_value"
}

if [ "${1:-}" = "-server" ] || [ "${1:-}" = "--server" ]; then
    [ "$#" -eq 4 ] || usage
    [ "${3:-}" = "-token" ] || [ "${3:-}" = "--token" ] || usage
    set -- "$2" "$4"
fi
[ "$#" -le 2 ] || usage
if [ "$#" -eq 0 ]; then
    server_input=""
    while [ -z "$server_input" ]; do
        printf 'Router Support HTTPS address (domain or IP): ' >&2
        if [ -t 2 ] && [ -r /dev/tty ]; then
            IFS= read -r server_input </dev/tty
        else
            IFS= read -r server_input
        fi
        [ -n "$server_input" ] || echo "Server address is required." >&2
    done
    case "$server_input" in
        https://*) SERVER_URL="${server_input%/}" ;;
        http://*) echo "Only HTTPS is allowed" >&2; exit 2 ;;
        *) SERVER_URL="https://${server_input%/}" ;;
    esac
else
    server_input="$1"
    case "$server_input" in
        https://*) SERVER_URL="${server_input%/}" ;;
        http://*) echo "Only HTTPS is allowed" >&2; exit 2 ;;
        *) SERVER_URL="https://${server_input%/}" ;;
    esac
fi

BOOTSTRAP_TOKEN="${2:-${ROUTER_SUPPORT_BOOTSTRAP_TOKEN:-}}"
while [ -z "$BOOTSTRAP_TOKEN" ]; do
    prompt_secret 'Bootstrap token: '
    [ -n "$BOOTSTRAP_TOKEN" ] || echo "Bootstrap token is required." >&2
done
SOURCE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_DIR="/etc/router-support"

case "$SERVER_URL" in
    https://*) ;;
    *) echo "server URL must use HTTPS" >&2; exit 2 ;;
esac
case "$SERVER_URL" in
    *[!A-Za-z0-9:/._~=-]*)
        echo "server URL contains unsupported characters" >&2
        exit 2
        ;;
esac
case "$BOOTSTRAP_TOKEN" in
    ''|*[!A-Za-z0-9._~-]*)
        echo "bootstrap token contains unsupported characters" >&2
        exit 2
        ;;
esac

for command_name in dropbearkey jsonfilter uclient-fetch; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing required command: $command_name" >&2
        exit 1
    }
done

echo "[1/6] Prerequisites checked." >&2

umask 077
mkdir -p "$CONFIG_DIR"
if [ ! -s "$CONFIG_DIR/uuid" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        tr -d '\n' </proc/sys/kernel/random/uuid >"$CONFIG_DIR/uuid"
    else
        random_hex="$(hexdump -n 16 -e '16/1 "%02x"' /dev/urandom)"
        printf '%s-%s-%s-%s-%s' \
            "${random_hex%????????????????????????}" \
            "$(printf '%s' "$random_hex" | cut -c9-12)" \
            "$(printf '%s' "$random_hex" | cut -c13-16)" \
            "$(printf '%s' "$random_hex" | cut -c17-20)" \
            "$(printf '%s' "$random_hex" | cut -c21-32)" >"$CONFIG_DIR/uuid"
    fi
fi
echo "[2/6] Device identity ready: $(cat "$CONFIG_DIR/uuid")" >&2

if [ ! -s "$CONFIG_DIR/id_router_support" ]; then
    if ! dropbearkey -t ed25519 -f "$CONFIG_DIR/id_router_support" >/dev/null 2>&1; then
        dropbearkey -t rsa -s 2048 -f "$CONFIG_DIR/id_router_support" >/dev/null
    fi
fi
echo "[3/6] Device SSH key ready." >&2

cat >"$CONFIG_DIR/config" <<EOF
SERVER_URL='$SERVER_URL'
BOOTSTRAP_TOKEN='$BOOTSTRAP_TOKEN'
DEVICE_UUID='$(cat "$CONFIG_DIR/uuid")'
EOF
chmod 600 "$CONFIG_DIR/config" "$CONFIG_DIR/id_router_support" "$CONFIG_DIR/uuid"

cp "$SOURCE_DIR/files/router-support" /usr/sbin/router-support
cp "$SOURCE_DIR/files/router-support.init" /etc/init.d/router-support
cp "$SOURCE_DIR/uninstall.sh" /usr/sbin/router-support-uninstall
chmod 0755 /usr/sbin/router-support /usr/sbin/router-support-uninstall \
    /etc/init.d/router-support
echo "[4/6] Agent files installed." >&2

/usr/sbin/router-support register
echo "[5/6] Device registered on the server." >&2
/etc/init.d/router-support enable
/etc/init.d/router-support restart
echo "[6/6] Service enabled and started." >&2
if ! /usr/sbin/router-support verify 15; then
    echo >&2
    echo "INSTALLATION INCOMPLETE: registration works, but SSH tunnel verification failed." >&2
    exit 1
fi
echo
echo "Router Support installation completed successfully."
echo "UUID: $(cat "$CONFIG_DIR/uuid")"
echo "Status: online (heartbeat and SSH tunnel verified)"

