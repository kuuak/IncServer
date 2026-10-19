#!/bin/bash
# Restore drill (kuuak/IncServer#15, Audit M5): proves a production dump comes back out of restic and loads into
# PostgreSQL, which the nightly `restic check` (structure only) and the monthly data check (pack contents) do not.
#   1. takes the latest restic snapshot and restores /var/backups/postgres/<db>.sql from it into a root-only temp dir
#   2. compares its sha256 with the dump still on disk (identical while no nightly run came after the snapshot)
#   3. loads it into a scratch database (CONNECT revoked from PUBLIC before the load), stopping at the first error
#   4. counts the rows of every table in the scratch DB and in the live DB, and prints both side by side
#   5. drops the scratch database and deletes the temp dir, also when a step fails
# Prints table names and counts only, never rows; psql errors are reduced to their SQLSTATE code (no DETAIL line
# with values). The live DB is only read (one read-only transaction for the counts). restic gets its credentials as
# the nightly unit does, from systemd's EnvironmentFile=/etc/restic/env: this shell never reads the file.
#
# Run by the owner, while the pizzeria is closed (the load takes one CPU for a minute or so):
#
#   scp docs/runbooks/restic-restore-drill.sh IncServer:
#   ssh IncServer 'sudo bash ~/restic-restore-drill.sh'          # default DB: pizzeriapeperoncini (production)
#   ssh IncServer 'rm ~/restic-restore-drill.sh'
#
# Then record the date and the RESULT line in docs/runbooks/backup-verification.md.
# Exit 0 = RESULT: PASS (restored, same tables, every count equal to live). Exit 1 = anything else: counts that
# differ (rows written since the snapshot; run it again before the first order of the day) or a failed step.
set -euo pipefail
umask 077
cd /

DB=${1:-pizzeriapeperoncini}
DUMP_DIR=/var/backups/postgres
[[ $DB =~ ^[a-z0-9_-]+$ ]] || { echo "usage: $0 [database]   (default pizzeriapeperoncini)"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 2; }
SCRATCH="restore_drill_${DB//-/_}"
DUMP_PATH="$DUMP_DIR/$DB.sql"

step() { echo "== $(date '+%F %T') $*"; }
pg() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate "$@"; }
# restic with the nightly unit's environment: systemd parses /etc/restic/env (as for restic-backup.service), the
# transient unit runs as root without HOME like the nightly, so rclone finds the same remote. stdout is passed through.
restic_() {
    systemd-run --quiet --pipe --wait --collect -p EnvironmentFile=/etc/restic/env \
        /usr/bin/restic --no-cache "$@" < /dev/null
}

current="preflight"
tmp="" created=0
cleanup() {
    local rc=$?
    set +e
    if [ "$created" = 1 ]; then
        pg -d postgres -v scratch="$SCRATCH" <<<'DROP DATABASE IF EXISTS :"scratch" WITH (FORCE);' \
            && echo "scratch database $SCRATCH dropped" || echo "WARNING: could not drop $SCRATCH: drop it by hand"
    fi
    [ -z "$tmp" ] || rm -rf "$tmp"
    if [ "$rc" != 0 ] && [ "$current" != "done" ]; then echo "RESULT: FAILED at step: $current"; fi
    exit "$rc"
}
trap cleanup EXIT

step "preflight: database $DB, scratch database $SCRATCH"
hostname
if [ "$(systemctl is-active restic-backup.service || true)" = active ]; then
    echo "REFUSE: the nightly backup is running; try again when it is done"; exit 2
fi
exists() { [ "$(pg -At -d postgres -v name="$1" <<<"SELECT count(*) FROM pg_database WHERE datname = :'name';")" = 1 ]; }
exists "$DB" || { echo "REFUSE: no live database $DB"; exit 2; }
if exists "$SCRATCH"; then
    echo "REFUSE: $SCRATCH already exists (an interrupted drill?). Check it is one, then:"
    echo "  sudo -u postgres dropdb '$SCRATCH'"; exit 2
fi
tmp=$(mktemp -d /root/restore-drill.XXXXXX)

current="1: restore from restic"
step "1: latest snapshot, restore $DUMP_PATH from it"
restic_ snapshots latest --json > "$tmp/snap.json"
read -r SNAP_ID SNAP_SHORT SNAP_TIME SNAP_HOST < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))[-1]
print(s["id"], s["short_id"], s["time"][:19].replace("T", "_"), s["hostname"])' "$tmp/snap.json")
echo "snapshot $SNAP_SHORT taken $SNAP_TIME on $SNAP_HOST"
restic_ dump "$SNAP_ID" "$DUMP_PATH" > "$tmp/dump.sql"
size=$(stat -c %s "$tmp/dump.sql")
[ "$size" -gt 0 ] || { echo "restored dump is empty"; exit 1; }
echo "restored $DB.sql: $size bytes"

current="2: compare with the dump on disk"
step "2: compare with $DUMP_PATH on disk"
if [ -f "$DUMP_PATH" ]; then
    restored_sum=$(sha256sum < "$tmp/dump.sql" | cut -d' ' -f1)
    disk_sum=$(sha256sum < "$DUMP_PATH" | cut -d' ' -f1)
    if [ "$restored_sum" = "$disk_sum" ]; then same_file="identical"
    else same_file="differs (the file on disk was written after the snapshot?)"; fi
    echo "sha256 of the restored dump vs the file on disk (modified $(date -r "$DUMP_PATH" '+%F %T')): $same_file"
else
    same_file="no file on disk"; echo "$DUMP_PATH not on disk: nothing to compare"
fi

current="3: load into $SCRATCH"
step "3: load into $SCRATCH (stops at the first error; errors as SQLSTATE only)"
pg -d postgres -v scratch="$SCRATCH" <<'SQL'
CREATE DATABASE :"scratch";
REVOKE ALL ON DATABASE :"scratch" FROM PUBLIC;
SQL
created=1
pg -d "$SCRATCH" -o /dev/null < "$tmp/dump.sql"
echo "loaded"

current="4: count rows"
step "4: row counts, restored vs live (live counted in one read-only snapshot)"
count_rows() {   # "<schema>.<table>\t<rows>" per ordinary or partitioned table outside the system schemas
    pg -At -F $'\t' -d "$1" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT format('SELECT %L, count(*) FROM %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p') AND n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\_%'
 ORDER BY n.nspname, c.relname
\gexec
COMMIT;
SQL
}
count_rows "$SCRATCH" > "$tmp/restored.tsv"
count_rows "$DB" > "$tmp/live.tsv"
[ -s "$tmp/restored.tsv" ] || { echo "the restored database has no tables"; exit 1; }
# One line per table: name, restored, live ("-" = no such table on that side).
awk -F'\t' -v OFS='\t' '
    FNR == NR { r[$1] = $2; seen[$1] = 1; next }
    { l[$1] = $2; seen[$1] = 1 }
    END { for (t in seen) print t, ((t in r) ? r[t] : "-"), ((t in l) ? l[t] : "-") }
' "$tmp/restored.tsv" "$tmp/live.tsv" | LC_ALL=C sort > "$tmp/both.tsv"
awk -F'\t' '
    BEGIN { printf "%-44s %12s %12s  %s\n", "table", "restored", "live", "" }
    {
        if ($2 == "-")      { note = "only in live"; other++ }
        else if ($3 == "-") { note = "only in restored"; other++ }
        else if ($2 == $3)  { note = ""; same++ }
        else                { note = sprintf("differs (%+d)", $3 - $2); diff++ }
        printf "%-44s %12s %12s  %s\n", $1, $2, $3, note
    }
    END { printf "tables: %d, equal: %d, count differs: %d, only on one side: %d\n", NR, same, diff, other }
' "$tmp/both.tsv" | tee "$tmp/report.txt"

current="5: drop $SCRATCH"
step "5: drop $SCRATCH"
pg -d postgres -v scratch="$SCRATCH" <<<'DROP DATABASE :"scratch" WITH (FORCE);'
created=0
echo "scratch database $SCRATCH dropped"

summary=$(tail -1 "$tmp/report.txt")
current="done"
if grep -q 'count differs: 0, only on one side: 0$' <<<"$summary"; then
    echo "RESULT: PASS $(date '+%F') $DB from snapshot $SNAP_SHORT ($SNAP_TIME): $summary; dump vs disk: $same_file"
else
    echo "RESULT: COUNTS DIFFER $(date '+%F') $DB from snapshot $SNAP_SHORT ($SNAP_TIME): $summary; dump vs disk: $same_file"
    exit 1
fi
