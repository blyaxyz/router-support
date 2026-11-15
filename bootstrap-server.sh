#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_URL="${ROUTER_SUPPORT_REPO_URL:-https://github.com/blyaxyz/router-support.git}"
DEFAULT_REPO_REF="${ROUTER_SUPPORT_REPO_REF:-main}"

[ "$(id -u)" -eq 0 ] || {
    echo "Run as root, for example: curl -fsSL URL | sudo bash" >&2
    exit 1
}
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    init_name="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"
    if [ "$init_name" != "systemd" ]; then
        echo "WSL requires systemd. Add [boot] systemd=true to /etc/wsl.conf," >&2
        echo "run 'wsl.exe --shutdown' in PowerShell, then retry." >&2
        exit 1
    fi
fi

echo "Router Support Panel — bootstrap installer" >&2
REPO_URL="$DEFAULT_REPO_URL"
REPO_REF="$DEFAULT_REPO_REF"
case "$REPO_URL" in
    https://github.com/*|git@github.com:*) ;;
    *) echo "Only GitHub repository URLs are accepted" >&2; exit 2 ;;
esac
case "$REPO_REF" in
    ''|*[!A-Za-z0-9._/-]*) echo "Invalid Git ref" >&2; exit 2 ;;
esac
echo "Source: $REPO_URL ($REPO_REF)" >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git iproute2

BOOTSTRAP_DIR="$(mktemp -d /tmp/router-support-bootstrap.XXXXXX)"
cleanup() {
    rm -rf "$BOOTSTRAP_DIR"
}
trap cleanup EXIT

git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$BOOTSTRAP_DIR/source"
chmod 0755 "$BOOTSTRAP_DIR/source/deploy/install-server.sh" \
    "$BOOTSTRAP_DIR/source/deploy/update-server.sh" \
    "$BOOTSTRAP_DIR/source/deploy/uninstall-server.sh"

installed=0
if [ -f /etc/router-support/backend.env ] && \
   [ -f /etc/systemd/system/router-support.service ] && \
   [ -d /opt/router-support ]; then
    installed=1
fi

if [ "$installed" -eq 0 ]; then
    echo "No existing installation detected. Starting installation..." >&2
    "$BOOTSTRAP_DIR/source/deploy/install-server.sh"
    echo "Bootstrap installation complete"
    exit 0
fi

echo >&2
echo "Existing Router Support installation detected." >&2
echo "  1) Update (recommended)" >&2
echo "  2) Remove" >&2
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
        "$BOOTSTRAP_DIR/source/deploy/update-server.sh"
        echo "Bootstrap update complete"
        ;;
    2|remove|uninstall)
        "$BOOTSTRAP_DIR/source/deploy/uninstall-server.sh"
        ;;
    3|cancel|quit)
        echo "No changes were made."
        ;;
    *)
        echo "Unknown action: $action" >&2
        exit 2
        ;;
esac

