#!/bin/bash
set -euo pipefail
# Secrets (RESTIC_REPOSITORY, RESTIC_PASSWORD) come from /etc/restic/env (0600) via the systemd unit.


BACKUP_DIR="/var/backups/postgres"
# Dumps hold customer data and role password hashes: root only. umask covers new files; a dump that already
# exists is truncated in place and keeps its mode, the 0700 directory covers it anyway.
umask 077
install -d -m 700 "$BACKUP_DIR"

echo "=== $(date) Starting PostgreSQL dumps ==="

# 1. Dump each database individually
sudo -u postgres psql -At -c "SELECT datname FROM pg_database WHERE datistemplate = false;" | while read -r dbname; do
    sudo -u postgres pg_dump "$dbname" > "$BACKUP_DIR/$dbname.sql"
done

# Also backup global roles + privileges
sudo -u postgres pg_dumpall --globals-only > "$BACKUP_DIR/_globals.sql"

echo "=== $(date) PostgreSQL dumps finished ==="

# 2. Run restic backup
echo "=== $(date) Starting restic backup ==="
restic backup \
    /etc \
    /var/www \
    /home/*/.ssh \
    "$BACKUP_DIR" \
    /var/lib/redis \
    /root \
    /usr/local/bin \
    --exclude-file=/etc/restic/excludes.txt

# 3. Apply retention (keep 7 daily, 4 weekly, 12 monthly)
echo "=== $(date) Running forget + prune ==="
restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 12


# 4. Verify repository consistency
echo "=== $(date) Running restic check ==="
restic check

echo "=== $(date) Backup job completed successfully ==="
