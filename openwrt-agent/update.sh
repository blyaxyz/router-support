#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || {
    echo "Run this updater as root on OpenWrt" >&2
    exit 1
}

SOURCE_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
[ -r /etc/router-support/config ] && [ -r /etc/router-support/state ] || {
    echo "A registered Router Support agent was not found; run install.sh" >&2
    exit 1
}

cp "$SOURCE_DIR/files/router-support" /usr/sbin/router-support
cp "$SOURCE_DIR/files/router-support.init" /etc/init.d/router-support
cp "$SOURCE_DIR/uninstall.sh" /usr/sbin/router-support-uninstall
chmod 0755 /usr/sbin/router-support /usr/sbin/router-support-uninstall \
    /etc/init.d/router-support

/etc/init.d/router-support enable
/etc/init.d/router-support restart
echo "Router Support agent updated and restarted."
