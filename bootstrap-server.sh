#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO_URL="${ROUTER_SUPPORT_REPO_URL:-}"
DEFAULT_REPO_REF="${ROUTER_SUPPORT_REPO_REF:-main}"

ask() {
    prompt="$1"
    default_value="${2:-}"
    if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$prompt" "$default_value" >&2
    else
        printf '%s: ' "$prompt" >&2
    fi
    if [ ! -r /dev/tty ]; then
        echo "Interactive terminal is required" >&2
        exit 1
    fi
    IFS= read -r answer </dev/tty
    printf '%s' "${answer:-$default_value}"
}

[ "$(id -u)" -eq 0 ] || {
    echo "Run as root, for example: curl -fsSL URL | sudo bash" >&2
    exit 1
}

echo "Router Support Panel — bootstrap installer" >&2
REPO_URL="$(ask 'GitHub repository URL' "$DEFAULT_REPO_URL")"
REPO_REF="$(ask 'Git branch or tag' "$DEFAULT_REPO_REF")"
case "$REPO_URL" in
    https://github.com/*|git@github.com:*) ;;
    *) echo "Only GitHub repository URLs are accepted" >&2; exit 2 ;;
esac
case "$REPO_REF" in
    ''|*[!A-Za-z0-9._/-]*) echo "Invalid Git ref" >&2; exit 2 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git

BOOTSTRAP_DIR="$(mktemp -d /tmp/router-support-bootstrap.XXXXXX)"
cleanup() {
    rm -rf "$BOOTSTRAP_DIR"
}
trap cleanup EXIT

git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$BOOTSTRAP_DIR/source"
chmod 0755 "$BOOTSTRAP_DIR/source/deploy/install-server.sh"
"$BOOTSTRAP_DIR/source/deploy/install-server.sh"

echo "Bootstrap installation complete"

