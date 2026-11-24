#!/bin/sh
set -eu

RAW_ROOT="${ROUTER_SUPPORT_RAW_ROOT:-https://raw.githubusercontent.com/blyaxyz/router-support/openwrt-agent-2026.11.24.1}"
INSTALL_DIR="/tmp/router-support-bootstrap.$$"
SERVER_ARG=""
TOKEN_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -server|--server)
            [ "$#" -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }
            SERVER_ARG="$2"
            shift 2
            ;;
        -token|--token)
            [ "$#" -ge 2 ] || { echo "$1 requires a value" >&2; exit 2; }
            TOKEN_ARG="$2"
            shift 2
            ;;
        -h|--help)
            echo "usage: $0 [-server domain-or-url -token connection-token]" >&2
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if { [ -n "$SERVER_ARG" ] && [ -z "$TOKEN_ARG" ]; } || \
   { [ -z "$SERVER_ARG" ] && [ -n "$TOKEN_ARG" ]; }; then
    echo "-server and -token must be supplied together" >&2
    exit 2
fi

[ "$(id -u)" -eq 0 ] || {
    echo "Run this installer as root on OpenWrt" >&2
    exit 1
}

download() {
    source_url="$1"
    destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 60 "$source_url" -o "$destination"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -T 60 -O "$destination" "$source_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$destination" "$source_url"
    else
        echo "curl, uclient-fetch or wget is required" >&2
        exit 1
    fi
}

cleanup() {
    rm -rf "$INSTALL_DIR"
}
abort() {
    trap - EXIT HUP INT TERM
    cleanup
    echo "Installation interrupted; temporary files removed." >&2
    exit 130
}
trap cleanup EXIT
trap abort HUP INT TERM

echo "[bootstrap 1/2] Downloading Router Support agent from GitHub..." >&2
mkdir -p "$INSTALL_DIR/files"
download "$RAW_ROOT/openwrt-agent/install.sh" "$INSTALL_DIR/install.sh"
download "$RAW_ROOT/openwrt-agent/update.sh" "$INSTALL_DIR/update.sh"
download "$RAW_ROOT/openwrt-agent/reconfigure.sh" "$INSTALL_DIR/reconfigure.sh"
download "$RAW_ROOT/openwrt-agent/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
download "$RAW_ROOT/openwrt-agent/files/router-support" "$INSTALL_DIR/files/router-support"
download "$RAW_ROOT/openwrt-agent/files/router-support.init" "$INSTALL_DIR/files/router-support.init"
chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/update.sh" \
    "$INSTALL_DIR/reconfigure.sh" "$INSTALL_DIR/uninstall.sh" \
    "$INSTALL_DIR/files/router-support" "$INSTALL_DIR/files/router-support.init"
echo "[bootstrap 2/2] Download complete; starting agent setup." >&2

if [ -x /etc/init.d/router-support ] && [ -x /usr/sbin/router-support ] && \
   [ -s /etc/router-support/config ] && [ -s /etc/router-support/state ] && \
   [ -s /etc/router-support/uuid ] && [ -s /etc/router-support/id_router_support ] && \
   grep -q '^DEVICE_TOKEN=' /etc/router-support/state && \
   grep -q '^SSH_HOST=' /etc/router-support/state && \
   grep -q '^REVERSE_PORT=' /etc/router-support/state; then
    if [ -n "$SERVER_ARG" ]; then
        echo "Existing agent detected; replacing its server connection..." >&2
        "$INSTALL_DIR/reconfigure.sh" "$SERVER_ARG" "$TOKEN_ARG"
        exit 0
    fi
    echo >&2
    echo "Existing Router Support agent detected." >&2
    echo "  1) Update (recommended)" >&2
    echo "  2) Configure a new server connection" >&2
    echo "  3) Remove (preserve device identity)" >&2
    echo "  4) Cancel" >&2
    printf 'Choose an action [1]: ' >&2
    action="${ROUTER_SUPPORT_ACTION:-}"
    if [ -z "$action" ]; then
        if [ -r /dev/tty ]; then
            IFS= read -r action </dev/tty || true
        else
            IFS= read -r action || true
        fi
    fi
    action="${action:-1}"
    case "$action" in
        1|update)
            "$INSTALL_DIR/update.sh"
            ;;
        2|configure|reconfigure|connect)
            "$INSTALL_DIR/reconfigure.sh"
            ;;
        3|remove|uninstall)
            "$INSTALL_DIR/uninstall.sh"
            ;;
        4|cancel|quit)
            echo "No changes were made."
            ;;
        *)
            echo "Unknown action: $action" >&2
            exit 2
            ;;
    esac
else
    if [ -r /etc/router-support/config ] || [ -x /usr/sbin/router-support ]; then
        echo "Incomplete previous installation detected; resuming setup..." >&2
    else
        echo "No existing agent detected. Starting installation..." >&2
    fi
    if [ -n "$SERVER_ARG" ]; then
        "$INSTALL_DIR/install.sh" "$SERVER_ARG" "$TOKEN_ARG"
    elif [ -t 2 ] && [ -r /dev/tty ]; then
        # wget|sh leaves stdin at EOF. Give the downloaded interactive installer
        # the controlling terminal so every quiz answer can still be read.
        "$INSTALL_DIR/install.sh" </dev/tty
    else
        "$INSTALL_DIR/install.sh"
    fi
    echo "Router Support agent installation complete" >&2
fi
