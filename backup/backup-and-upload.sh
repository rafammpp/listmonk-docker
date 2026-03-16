#!/bin/sh
set -eu

DB_HOST=db
DB_PORT=5432
DB_USER=listmonk
DB_NAME=listmonk
BACKUPS_DIR=/backups

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

require_cmd age
require_cmd aws
require_cmd gzip
require_cmd pg_dump
require_cmd sha256sum

require_var POSTGRES_PASSWORD
require_var BACKUP_AGE_PUBLIC_KEY
require_var R2_BUCKET
require_var R2_ENDPOINT
require_var R2_ACCESS_KEY_ID
require_var R2_SECRET_ACCESS_KEY

export PGPASSWORD="$POSTGRES_PASSWORD"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="auto"
export AWS_EC2_METADATA_DISABLED=true

mkdir -p "$BACKUPS_DIR" /tmp/backup-work

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
filename="db-${timestamp}.sql.gz.age"
local_file="${BACKUPS_DIR}/${filename}"
local_checksum="${local_file}.sha256"
temp_file="/tmp/backup-work/${filename}"
temp_checksum="${temp_file}.sha256"

pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" \
    | gzip -9 \
    | age -r "$BACKUP_AGE_PUBLIC_KEY" -o "$temp_file"

sha256sum "$temp_file" > "$temp_checksum"

mv "$temp_file" "$local_file"
mv "$temp_checksum" "$local_checksum"

r2_prefix=$(normalize_prefix "${R2_PREFIX:-backups}")
if [ -n "$r2_prefix" ]; then
    remote_prefix="${r2_prefix}/"
else
    remote_prefix=""
fi

remote_file_uri="s3://${R2_BUCKET}/${remote_prefix}${filename}"
remote_checksum_uri="${remote_file_uri}.sha256"

aws --endpoint-url "$R2_ENDPOINT" s3 cp "$local_file" "$remote_file_uri"
aws --endpoint-url "$R2_ENDPOINT" s3 cp "$local_checksum" "$remote_checksum_uri"

retention_days=${BACKUP_RETENTION_DAYS:-7}

case "$retention_days" in
    ''|*[!0-9]*)
        echo "BACKUP_RETENTION_DAYS must be an integer number of days" >&2
        exit 1
        ;;
esac

find "$BACKUPS_DIR" -type f \( -name '*.sql.gz.age' -o -name '*.sql.gz.age.sha256' \) -mtime +"$retention_days" -delete

echo "Encrypted backup created: $local_file"
echo "Encrypted backup uploaded: $remote_file_uri"