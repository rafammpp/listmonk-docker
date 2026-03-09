#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

usage() {
    echo "Usage:" >&2
    echo "  scripts/restore-from-r2.sh [--list] [--no-stop] [--yes] [backup-key]" >&2
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

confirm_restore() {
    prompt_message=$1

    if [ ! -t 0 ]; then
        echo "Restore requires confirmation. Re-run with --yes in non-interactive mode." >&2
        exit 1
    fi

    printf "%s [y/N]: " "$prompt_message" >&2
    read -r reply
    case "$reply" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Restore cancelled." >&2
            exit 1
            ;;
    esac
}

list_only=false
stop_app=true
assume_yes=false
backup_key=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list)
            list_only=true
            ;;
        --no-stop)
            stop_app=false
            ;;
        --yes)
            assume_yes=true
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            if [ -n "$backup_key" ]; then
                usage
            fi
            backup_key=$1
            ;;
    esac
    shift
done

ensure_compose
ensure_env

if [ "$list_only" = true ]; then
    exec docker compose exec backup /usr/local/bin/restore-from-r2.sh --list
fi

if [ "$assume_yes" != true ]; then
    if [ -n "$backup_key" ]; then
        confirm_restore "This will overwrite the PostgreSQL database using backup '$backup_key'. Continue?"
    else
        confirm_restore "This will overwrite the PostgreSQL database using the latest backup available in R2. Continue?"
    fi
fi

app_was_running=false
if [ "$stop_app" = true ]; then
    if docker compose ps --status running --services | grep -qx 'app'; then
        app_was_running=true
        echo "Stopping app before restore..."
        docker compose stop app
    fi
fi

cleanup() {
    if [ "$app_was_running" = true ]; then
        echo "Starting app after restore..."
        docker compose start app
    fi
}

trap cleanup EXIT INT TERM

if [ -n "$backup_key" ]; then
    docker compose exec backup /usr/local/bin/restore-from-r2.sh "$backup_key"
else
    docker compose exec backup /usr/local/bin/restore-from-r2.sh
fi