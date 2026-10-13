#!/usr/bin/env bash
set -euo pipefail

test_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
checkout=$(cd "$test_directory/../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/monkeyspaw-backup-test.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/backups"
export FAKE_BACKUP_DIRECTORY="$fixture/backups" EXPECTED_CHECKOUT="$checkout"
export FAKE_UTC_TIMESTAMP=20261021T000000Z
export PATH="$fixture/bin:$PATH"
unset BACKUP_KEEP

cat > "$fixture/bin/date" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = '-u +%Y%m%dT%H%M%SZ' ]
printf '%s\n' "$FAKE_UTC_TIMESTAMP"
SH
cat > "$fixture/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$PWD" = "$EXPECTED_CHECKOUT" ]
[ "$1 $2 $3 $4" = 'compose exec -T monkeyspaw-server' ]
shift 4
case "$1" in
    monkeyspaw-server)
        [ "$2" = backup ]
        [ "${FAKE_BACKUP_FAILURE:-0}" = 0 ] || exit 23
        destination="$FAKE_BACKUP_DIRECTORY/${3##*/}"
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || exit 24
        printf '%s\n' snapshot > "$destination"
        printf '%s\n' "$3"
        ;;
    sh)
        [ "$2 $3" = '-eu -c' ]
        program=${4//\/data\/backups/$FAKE_BACKUP_DIRECTORY}
        shift 4
        sh -eu -c "$program" "$@"
        ;;
    *) exit 25 ;;
esac
SH
chmod +x "$fixture/bin/date" "$fixture/bin/docker"

seed() {
    local day
    for day in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        printf '%s\n' snapshot > "$fixture/backups/$(printf '202610%02dT000000Z.db' "$day")"
    done
}
count_backups() {
    local file count=0
    for file in "$fixture/backups/"????????T??????Z.db; do
        if [ ! -f "$file" ] || [ -L "$file" ]; then continue; fi
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}
fail() { printf '%s\n' "$1" >&2; exit 1; }

seed
printf '%s\n' keep > "$fixture/backups/manual.db"
printf '%s\n' keep > "$fixture/backups/monkeyspaw.pre-restore-example.db"
printf '%s\n' keep > "$fixture/backups/.monkeyspaw-backup-incomplete"
mkdir "$fixture/backups/20260101T000000Z.db"
ln -s manual.db "$fixture/backups/20260102T000000Z.db"
cd "$fixture"
bash "$checkout/scripts/backup.sh"
[ "$(count_backups)" = 14 ] || fail 'Default retention must keep exactly 14 backups.'
[ ! -e "$fixture/backups/20261007T000000Z.db" ] || fail 'Old backups survived retention.'
[ -f "$fixture/backups/20261008T000000Z.db" ] || fail 'A retained backup was removed.'
for name in manual.db monkeyspaw.pre-restore-example.db .monkeyspaw-backup-incomplete; do
    [ "$(cat "$fixture/backups/$name")" = keep ] || fail 'An unrelated file was changed.'
done
[ -d "$fixture/backups/20260101T000000Z.db" ] && [ -L "$fixture/backups/20260102T000000Z.db" ]

seed
if FAKE_BACKUP_FAILURE=1 bash "$checkout/scripts/backup.sh"; then fail 'Failed backup returned success.'; fi
[ "$(count_backups)" = 21 ] || fail 'Failed backup ran retention.'
if bash "$checkout/scripts/backup.sh"; then fail 'Occupied backup returned success.'; fi
[ "$(count_backups)" = 21 ] || fail 'Occupied backup ran retention.'

for value in 0 01 invalid 9999999999; do
    if BACKUP_KEEP="$value" bash "$checkout/scripts/backup.sh"; then fail 'Invalid retention returned success.'; fi
    [ "$(count_backups)" = 21 ] || fail 'Invalid retention removed backups.'
done
FAKE_UTC_TIMESTAMP=20261022T000000Z BACKUP_KEEP=2 bash "$checkout/scripts/backup.sh"
[ "$(count_backups)" = 2 ] || fail 'Custom retention did not keep two backups.'
[ -f "$fixture/backups/20261021T000000Z.db" ] && [ -f "$fixture/backups/20261022T000000Z.db" ]
printf '%s\n' 'Backup script tests passed.'
