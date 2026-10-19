#!/bin/bash
set -euo pipefail
# Monthly restic data check (kuuak/IncServer#15): downloads one twelfth of the repository's pack files and verifies
# their contents, on top of the nightly `restic check` in restic-backup.sh (structure only, no data read).
# The twelfth is the month's number (January 1/12 ... December 12/12): restic picks subset n/t by pack ID, so the
# same n always reads the same packs, and rotating n reads every pack kept a year once a year.
# Secrets (RESTIC_REPOSITORY, RESTIC_PASSWORD) come from /etc/restic/env via the unit.

subset="$(date +%-m)/12"

# --retry-lock: check takes an exclusive lock; wait out a nightly run that started late (Persistent=true after downtime).
echo "=== $(date) Running restic check --read-data-subset=$subset ==="
restic check --read-data-subset="$subset" --retry-lock 30m

echo "=== $(date) Data check completed successfully ==="
