#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)"
OUTPUT="${1:-$PROJECT_ROOT/router-support-release.tar.gz}"
COPYFILE_DISABLE=1 tar -czf "$OUTPUT" \
    --exclude='.venv' --exclude='data' --exclude='__pycache__' \
    --exclude='.pytest_cache' --exclude='.DS_Store' --exclude='*.tar.gz' \
    -C "$PROJECT_ROOT" \
    backend frontend openwrt-agent deploy scripts docs \
    requirements.txt requirements-dev.txt pyproject.toml README.md .env.example \
    bootstrap-server.sh
echo "$OUTPUT"

