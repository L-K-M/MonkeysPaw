#!/usr/bin/env bash
# Online compose backup. Prune only after the CLI publishes a valid snapshot.
set -euo pipefail

backup_keep=${BACKUP_KEEP:-14}
case "$backup_keep" in
    ''|0*|*[!0-9]*)
        printf '%s\n' 'BACKUP_KEEP must be a positive integer (at most 9 digits).' >&2
        exit 1
        ;;
esac
if [ "${#backup_keep}" -gt 9 ]; then
    printf '%s\n' 'BACKUP_KEEP must be a positive integer (at most 9 digits).' >&2
    exit 1
fi

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_directory/.."
backup_path="/data/backups/$(date -u +%Y%m%dT%H%M%SZ).db"
docker compose exec -T monkeyspaw-server monkeyspaw-server backup "$backup_path"

# The quoted program expands its variables inside the container.
# shellcheck disable=SC2016
docker compose exec -T monkeyspaw-server sh -eu -c '
    keep=$1
    export LC_ALL=C
    cd /data/backups
    set -- [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.db
    count=0
    for file do
        if [ ! -f "$file" ] || [ -L "$file" ]; then continue; fi
        count=$((count + 1))
    done
    # The fixed-width UTC names sort oldest first in the C locale.
    for file do
        [ "$count" -gt "$keep" ] || break
        if [ ! -f "$file" ] || [ -L "$file" ]; then continue; fi
        rm -- "$file"
        count=$((count - 1))
    done
' backup-retention "$backup_keep"
