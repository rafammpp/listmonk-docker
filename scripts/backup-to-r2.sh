#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

usage() {
    echo "Usage:" >&2
    echo "  scripts/backup-to-r2.sh" >&2
    exit 1
}

ensure_compose() {
    if ! docker compose version >/dev/null 2>&1; then
        echo "docker compose is required" >&2
        exit 1
    fi
}

ensure_env() {
    if [ ! -f ./.env ]; then
        echo "Missing .env file in $ROOT_DIR" >&2
        exit 1
    fi
}

[ "$#" -eq 0 ] || usage

ensure_compose
ensure_env

exec docker compose exec backup /usr/local/bin/backup-and-upload.sh