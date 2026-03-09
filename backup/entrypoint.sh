#!/bin/sh
set -eu

: "${BACKUP_SCHEDULE:=0 3 * * *}"

printf '%s %s\n' "$BACKUP_SCHEDULE" "/usr/local/bin/backup-and-upload.sh" > /tmp/crontab

exec /usr/local/bin/supercronic /tmp/crontab