#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 root@192.168.1.1 https://support.example.com" >&2
    echo "Set ROUTER_SUPPORT_BOOTSTRAP_TOKEN or enter it at the prompt." >&2
    exit 2
}

[ "$#" -eq 2 ] || usage
ROUTER_TARGET="$1"
SERVER_URL="${2%/}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
TOKEN="${ROUTER_SUPPORT_BOOTSTRAP_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    read -r -s -p "Bootstrap token: " TOKEN
    echo
fi
[ -n "$TOKEN" ] || { echo "Empty bootstrap token" >&2; exit 1; }

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
COPYFILE_DISABLE=1 tar -czf "$TEMP_DIR/openwrt-agent.tar.gz" \
    -C "$PROJECT_ROOT" openwrt-agent
REMOTE_DIR="$(ssh "$ROUTER_TARGET" 'mktemp -d /tmp/router-support.XXXXXX')"
case "$REMOTE_DIR" in /tmp/router-support.*) ;; *) echo "Unsafe remote path" >&2; exit 1 ;; esac
scp -O "$TEMP_DIR/openwrt-agent.tar.gz" "$ROUTER_TARGET:$REMOTE_DIR/agent.tar.gz"
# shellcheck disable=SC2029 # REMOTE_DIR is validated as a remote mktemp path above.
ssh "$ROUTER_TARGET" "tar -xzf '$REMOTE_DIR/agent.tar.gz' -C '$REMOTE_DIR'"
printf '%s\n' "$TOKEN" | ssh -T "$ROUTER_TARGET" \
    "read -r TOKEN; export ROUTER_SUPPORT_BOOTSTRAP_TOKEN=\"\$TOKEN\"; '$REMOTE_DIR/openwrt-agent/install.sh' '$SERVER_URL'"
# shellcheck disable=SC2029 # Removal is limited to the validated remote mktemp path.
ssh "$ROUTER_TARGET" "rm -rf '$REMOTE_DIR'"
echo "Agent deployed to $ROUTER_TARGET"

