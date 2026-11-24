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

sync_clock_from_trusted_https() {
    command -v curl >/dev/null 2>&1 || return 1
    trusted_date="$(
        curl -fsSIL --connect-timeout 15 --max-time 30 https://github.com/ 2>/dev/null |
            sed -n 's/^[Dd]ate:[[:space:]]*//p' |
            tail -n 1 |
            tr -d '\r'
    )"
    # Expected RFC 7231 form: Tue, 24 Nov 2026 11:15:23 GMT
    set -- $trusted_date
    [ "$#" -ge 6 ] || return 1
    clock_day="$2"
    clock_month_name="$3"
    clock_year="$4"
    clock_time="$5"
    case "$clock_month_name" in
        Jan) clock_month=01 ;; Feb) clock_month=02 ;; Mar) clock_month=03 ;;
        Apr) clock_month=04 ;; May) clock_month=05 ;; Jun) clock_month=06 ;;
        Jul) clock_month=07 ;; Aug) clock_month=08 ;; Sep) clock_month=09 ;;
        Oct) clock_month=10 ;; Nov) clock_month=11 ;; Dec) clock_month=12 ;;
        *) return 1 ;;
    esac
    old_ifs="$IFS"
    IFS=:
    set -- $clock_time
    IFS="$old_ifs"
    [ "$#" -eq 3 ] || return 1
    clock_hour="$1"
    clock_minute="$2"
    clock_second="$3"
    case "$clock_year$clock_month$clock_day$clock_hour$clock_minute$clock_second" in
        *[!0-9]*) return 1 ;;
    esac
    date -u -s \
        "${clock_year}${clock_month}${clock_day}${clock_hour}${clock_minute}.${clock_second}" \
        >/dev/null 2>&1
}

ensure_reasonable_clock() {
    echo "[clock] Router UTC time before synchronization: $(date -u 2>/dev/null || date)" >&2
    if sync_clock_from_trusted_https; then
        echo "[clock] Router UTC time synchronized securely via GitHub HTTPS: $(date -u)" >&2
        return 0
    fi
    if command -v ntpd >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && \
       timeout 20 ntpd -q -p time.cloudflare.com >/dev/null 2>&1; then
        echo "[clock] Router UTC time synchronized via NTP: $(date -u)" >&2
        return 0
    fi
    echo "[clock] Warning: automatic time synchronization failed." >&2
    echo "[clock] TLS registration may fail; configure NTP or set the router date manually." >&2
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

ensure_reasonable_clock
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

echo "[5/6] Registering device on the server..." >&2
/usr/sbin/router-support register
echo "      Device registered successfully." >&2
/etc/init.d/router-support enable
# This path is only used for new or incomplete installations. A silent stop
# clears remnants without exposing procd's harmless "service delete: Not found".
/etc/init.d/router-support stop >/dev/null 2>&1 || true
/etc/init.d/router-support start
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

