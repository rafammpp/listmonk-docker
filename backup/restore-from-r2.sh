#!/bin/sh
set -eu

DB_HOST=db
DB_PORT=5432
DB_USER=listmonk
DB_NAME=listmonk

usage() {
    echo "Usage:" >&2
    echo "  restore-from-r2.sh --list" >&2
    echo "  restore-from-r2.sh [backup-key]" >&2
    exit 1
}

require_var() {
    var_name=$1
    eval "var_value=\${$var_name:-}"
    if [ -z "$var_value" ]; then
        echo "Missing required variable: $var_name" >&2
        exit 1
    fi
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1" >&2
        exit 1
    fi
}

normalize_prefix() {
    printf '%s' "$1" | sed 's#^/*##; s#/*$##'
}

latest_backup_key() {
    aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/${remote_prefix}" --recursive \
    | awk '/\.sql\.gz\.age$/ {print $1 " " $2 " " $4}' \
        | sort \
        | tail -n 1 \
        | awk '{print $3}'
}

require_cmd age
require_cmd aws
require_cmd psql
require_cmd sha256sum
require_cmd gzip

require_var POSTGRES_PASSWORD
require_var R2_BUCKET
require_var R2_ENDPOINT
require_var R2_ACCESS_KEY_ID
require_var R2_SECRET_ACCESS_KEY

read_age_secret_key() {
    if ! IFS= read -r backup_age_secret_key; then
        echo "Missing age secret key on stdin." >&2
        exit 1
    fi

    backup_age_secret_key=$(printf '%s' "$backup_age_secret_key" | tr -d '\r')
    case "$backup_age_secret_key" in
        AGE-SECRET-KEY-1*)
            ;;
        *)
            echo "Invalid age secret key provided on stdin." >&2
            exit 1
            ;;
    esac
}

export PGPASSWORD="$POSTGRES_PASSWORD"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export AWS_EC2_METADATA_DISABLED=true

r2_prefix=$(normalize_prefix "${R2_PREFIX:-backups}")
if [ -n "$r2_prefix" ]; then
    remote_prefix="${r2_prefix}/"
else
    remote_prefix=""
fi

if [ "${1:-}" = "--list" ]; then
    aws --endpoint-url "$R2_ENDPOINT" s3 ls "s3://${R2_BUCKET}/${remote_prefix}" --recursive
    exit 0
fi

[ "$#" -le 1 ] || usage

if [ "$#" -eq 1 ]; then
    backup_key=$1
else
    backup_key=$(latest_backup_key)
    if [ -z "$backup_key" ]; then
        echo "No encrypted backups were found in s3://${R2_BUCKET}/${remote_prefix}" >&2
        exit 1
    fi
    echo "No backup key supplied. Using latest available backup: $backup_key"
fi

case "$backup_key" in
    s3://*)
        echo "Pass only the object key, not a full s3:// URI" >&2
        exit 1
        ;;
esac

read_age_secret_key

mkdir -p /tmp/restore-work
encrypted_file="/tmp/restore-work/$(basename "$backup_key")"
checksum_file="${encrypted_file}.sha256"
identity_file=

cleanup() {
    rm -f "$encrypted_file" "$checksum_file" "${identity_file:-}"
}

trap cleanup EXIT INT TERM

aws --endpoint-url "$R2_ENDPOINT" s3 cp "s3://${R2_BUCKET}/${backup_key}" "$encrypted_file"
aws --endpoint-url "$R2_ENDPOINT" s3 cp "s3://${R2_BUCKET}/${backup_key}.sha256" "$checksum_file"

expected_sum=$(awk '{print $1}' "$checksum_file")
actual_sum=$(sha256sum "$encrypted_file" | awk '{print $1}')

if [ "$expected_sum" != "$actual_sum" ]; then
    echo "Checksum verification failed for $backup_key" >&2
    exit 1
fi

case "$backup_key" in
    *.sql.gz.age)
        ;;
    *)
        echo "Unsupported backup format: $backup_key" >&2
        exit 1
        ;;
esac

identity_file="/tmp/restore-work/backup.agekey"
printf '%s\n' "$backup_age_secret_key" > "$identity_file"
backup_age_secret_key=
chmod 600 "$identity_file"
age -d -i "$identity_file" "$encrypted_file" \
    | gzip -d \
    | psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
trap - EXIT INT TERM
cleanup

echo "Restore completed successfully from: s3://${R2_BUCKET}/${backup_key}"