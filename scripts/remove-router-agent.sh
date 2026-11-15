#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: remove-router-agent.sh root@192.168.1.1 [--purge]

Default: remove service and access keys, preserve device identity for reinstall.
--purge: permanently remove UUID, device token and private key from the router.
EOF
    exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
ROUTER_TARGET="$1"
MODE="${2:-}"
case "$MODE" in ""|--purge) ;; *) usage ;; esac

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
REMOTE_SCRIPT="/tmp/router-support-uninstall.$$"

scp -O "$PROJECT_ROOT/openwrt-agent/uninstall.sh" \
    "$ROUTER_TARGET:$REMOTE_SCRIPT"
# shellcheck disable=SC2029 # Remote path contains only the local numeric PID.
ssh "$ROUTER_TARGET" "chmod 700 '$REMOTE_SCRIPT' && '$REMOTE_SCRIPT' $MODE"
# shellcheck disable=SC2029 # Removes only the uploaded temporary script.
ssh "$ROUTER_TARGET" "rm -f '$REMOTE_SCRIPT'" || true

echo "Agent removed from $ROUTER_TARGET"
if [ "$MODE" = "--purge" ]; then
    echo "The panel record remains and will become offline; remove it separately if needed."
fi

