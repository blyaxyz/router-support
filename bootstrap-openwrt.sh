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
download "$RAW_ROOT/openwrt-agent/uninstall.sh" "$INSTALL_DIR/uninstall.sh"
download "$RAW_ROOT/openwrt-agent/files/router-support" "$INSTALL_DIR/files/router-support"
download "$RAW_ROOT/openwrt-agent/files/router-support.init" "$INSTALL_DIR/files/router-support.init"
chmod 0755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/uninstall.sh" \
    "$INSTALL_DIR/files/router-support" "$INSTALL_DIR/files/router-support.init"

"$INSTALL_DIR/install.sh"
echo "Router Support agent installation complete" >&2
