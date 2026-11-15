#!/bin/sh
set -eu

RAW_ROOT="${ROUTER_SUPPORT_RAW_ROOT:-https://raw.githubusercontent.com/blyaxyz/router-support/main}"
INSTALL_DIR="/tmp/router-support-bootstrap.$$"

[ "$(id -u)" -eq 0 ] || {
    echo "Run this installer as root on OpenWrt" >&2
    exit 1
}

download() {
    source_url="$1"
    destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$source_url" -o "$destination"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$destination" "$source_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destination" "$source_url"
    else
        echo "curl, uclient-fetch or wget is required" >&2
        exit 1
    fi
}

cleanup() {
    rm -rf "$INSTALL_DIR"
}
trap cleanup EXIT HUP INT TERM

echo "Downloading Router Support agent from GitHub..." >&2
mkdir -p "$INSTALL_DIR/files"
download "$RAW_ROOT/openwrt-agent/install.sh" "$INSTALL_DIR/install.sh"
download "$RAW_ROOT/openwrt-agent/update.sh" "$INSTALL_DIR/update.sh"
download "$RAW_ROOT/openwrt-agent/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
download "$RAW_ROOT/openwrt-agent/files/router-support" "$INSTALL_DIR/files/router-support"
download "$RAW_ROOT/openwrt-agent/files/router-support.init" "$INSTALL_DIR/files/router-support.init"
chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/update.sh" \
    "$INSTALL_DIR/uninstall.sh" \
    "$INSTALL_DIR/files/router-support" "$INSTALL_DIR/files/router-support.init"

if [ -x /etc/init.d/router-support ] && [ -x /usr/sbin/router-support ] && \
   [ -r /etc/router-support/config ]; then
    echo >&2
    echo "Existing Router Support agent detected." >&2
    echo "  1) Update (recommended)" >&2
    echo "  2) Remove (preserve device identity)" >&2
    echo "  3) Cancel" >&2
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
        2|remove|uninstall)
            "$INSTALL_DIR/uninstall.sh"
            ;;
        3|cancel|quit)
            echo "No changes were made."
            ;;
        *)
            echo "Unknown action: $action" >&2
            exit 2
            ;;
    esac
else
    echo "No existing agent detected. Starting installation..." >&2
    if [ -t 2 ] && [ -r /dev/tty ]; then
        # wget|sh leaves stdin at EOF. Give the downloaded interactive installer
        # the controlling terminal so every quiz answer can still be read.
        "$INSTALL_DIR/install.sh" </dev/tty
    else
        "$INSTALL_DIR/install.sh"
    fi
    echo "Router Support agent installation complete" >&2
fi
