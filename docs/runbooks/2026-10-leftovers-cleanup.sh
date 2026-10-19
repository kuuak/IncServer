#!/bin/bash
# Remove the leftovers of the 2026-09 cleanup that only the owner can delete (kuuak/IncServer#6, Audit H2, M1, L4):
#   1. the old Alloy systemd drop-in (holds the Grafana Cloud token `kuuakincserver-token`), then daemon-reload
#   2. the `alloy` user (in adm + systemd-journal) and its home /var/lib/alloy (else uid 999 leaves orphaned files)
#   3. the Redis keys of the Decommissioned Tenant Dolce Vita (prefixes `dolce-vita:` and `dolce-vita-staging:`)
#   4. the nginx logs of hosts that have no vhost any more (visitor IPs)
# Nothing of a live Tenant (Peperoncini) is touched; the script counts its Redis keys and nginx logs before and
# after and says so if they changed. No Environment, PM2 unit or nginx process is restarted.
#
# Run by the owner, only AFTER revoking `kuuakincserver-token` in Grafana Cloud:
#
#   scp docs/runbooks/2026-10-leftovers-cleanup.sh IncServer:
#   ssh IncServer 'sudo bash ~/2026-10-leftovers-cleanup.sh --dry-run'         # lists the targets, deletes nothing
#   ssh IncServer 'sudo bash ~/2026-10-leftovers-cleanup.sh --token-revoked'   # lists again, then deletes
#
# The real run writes everything it prints (listings + results) to /root/cleanup-2026-09/leftovers-2026-10.log.
# The token's file is listed by name and size only, Redis keys by prefix and count only (never values).
# Afterwards: docs/runbooks/2026-10-leftovers-verify.sh (read-only, no sudo).
set -euo pipefail
umask 077

MODE=${1:-}
case "$MODE" in
    --dry-run|--token-revoked) ;;
    *) echo "usage: $0 --dry-run | --token-revoked   (revoke kuuakincserver-token in Grafana Cloud first)"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 2; }

DROPIN=/etc/systemd/system/alloy.service.d
ALLOY_HOME=/var/lib/alloy
REDIS_PATTERNS=('dolce-vita:*' 'dolce-vita-staging:*')
GONE_HOSTS=(demo.kuuak.ch glitchtip.kuuak.ch pizzeria-dolce-vita.ch staging.pizzeria-dolce-vita.ch pizzeriatomate.ch)
LOG=/root/cleanup-2026-09/leftovers-2026-10.log

if [ "$MODE" = --token-revoked ]; then
    install -d -m 700 /root/cleanup-2026-09
    exec > >(tee -a "$LOG") 2>&1
fi
step() { echo "== $(date -Is) $*"; }

redis_dbs() { redis-cli INFO keyspace | sed -n 's/^db\([0-9]*\):.*/\1/p'; }
redis_prefix_counts() {   # "<count> db<n> <prefix>" per prefix (text before the first ':'), no values
    local db
    for db in $(redis_dbs); do
        redis-cli -n "$db" --scan | awk -F: -v db="$db" '{print "db" db " " $1}'
    done | sort | uniq -c
}
peperoncini_state() {   # fingerprint of the live Tenant's keys and logs, compared before/after
    redis_prefix_counts | grep -F peperoncini || true
    find /var/log/nginx -maxdepth 1 -name '*peperoncini*' | wc -l
}
gone_logs() {
    local h
    for h in "${GONE_HOSTS[@]}"; do
        find /var/log/nginx -maxdepth 1 -type f \( -name "$h-access.log*" -o -name "$h-error.log*" \)
    done | sort
}

step "preflight (mode $MODE)"
hostname
for h in "${GONE_HOSTS[@]}"; do
    # A host still named anywhere in the nginx config has a vhost: refuse rather than delete its logs.
    if grep -RqsF "$h" /etc/nginx/; then echo "REFUSE: $h is still in /etc/nginx: $(grep -RlsF "$h" /etc/nginx/ | tr '\n' ' ')"; exit 1; fi
done
[ "$(systemctl show -p LoadState --value alloy.service)" = not-found ] || { echo "REFUSE: alloy.service still installed"; exit 1; }
if pgrep -u alloy >/dev/null 2>&1; then echo "REFUSE: processes still run as alloy"; exit 1; fi
# Files owned by user or group alloy outside its home would be orphaned to uid/gid 999 after userdel. The home is
# pruned by exact path, so siblings like /var/lib/alloy.bak are still searched. find aborts on an unknown name, so
# each test is added only if that account exists; a failing find stops the run here (set -e), before any delete.
owned=()
if getent passwd alloy >/dev/null; then owned+=(-user alloy); fi
if getent group alloy >/dev/null; then owned+=(${owned[0]:+-o} -group alloy); fi
other=""
if [ ${#owned[@]} -gt 0 ]; then
    other=$(find / -xdev \( -path /proc -o -path "$ALLOY_HOME" \) -prune -o \( "${owned[@]}" \) -print)
fi
[ -z "$other" ] || { echo "REFUSE: files owned by user or group alloy outside $ALLOY_HOME:"; echo "$other"; exit 1; }
redis-cli PING

step "target 1: Alloy drop-in (names and sizes only, never the content)"
if [ -d "$DROPIN" ]; then ls -la "$DROPIN"; else echo "already gone"; fi
echo "systemd's view: $(systemctl show -p DropInPaths,NeedDaemonReload alloy.service | tr '\n' ' ')"

step "target 2: user alloy and its home"
id alloy 2>&1 || echo "already gone"
if [ -d "$ALLOY_HOME" ]; then
    echo "$ALLOY_HOME: $(du -sh "$ALLOY_HOME" | cut -f1), $(find "$ALLOY_HOME" | wc -l) entries"
    find "$ALLOY_HOME" -maxdepth 2 -printf '%u:%g %M %p\n'
else echo "$ALLOY_HOME already gone"; fi

step "target 3: Redis keys by prefix, all keys (before)"
redis_prefix_counts
for p in "${REDIS_PATTERNS[@]}"; do
    for db in $(redis_dbs); do echo "to delete: db$db $p: $(redis-cli -n "$db" --scan --pattern "$p" | wc -l) keys"; done
done

step "target 4: nginx logs of hosts without a vhost"
gone_logs | xargs -r ls -l
echo "to delete: $(gone_logs | wc -l) files"
for h in "${GONE_HOSTS[@]}"; do printf '  %s: %s\n' "$h" "$(gone_logs | grep -cF "/$h-" || true)"; done

PEP_BEFORE=$(peperoncini_state)
echo "Peperoncini (untouched): keys by prefix + nginx log count:"; echo "$PEP_BEFORE"

if [ "$MODE" = --dry-run ]; then step "dry run: nothing deleted"; exit 0; fi

step "delete 1: Alloy drop-in, daemon-reload"
rm -rf "$DROPIN"
systemctl daemon-reload
echo "systemd's view: $(systemctl show -p DropInPaths,NeedDaemonReload alloy.service | tr '\n' ' ')"

step "delete 2: user alloy (and group), then its home"
if id alloy >/dev/null 2>&1; then userdel alloy; fi   # not -r: it fails on the absent mail spool
rm -rf "$ALLOY_HOME"

step "delete 3: Redis keys ${REDIS_PATTERNS[*]}"
for p in "${REDIS_PATTERNS[@]}"; do
    for db in $(redis_dbs); do
        redis-cli -n "$db" --scan --pattern "$p" | while IFS= read -r k; do redis-cli -n "$db" UNLINK "$k" >/dev/null; done
    done
done

step "delete 4: nginx logs of hosts without a vhost"
gone_logs | xargs -r rm -f

step "after"
if [ -e "$DROPIN" ]; then echo "FAIL: $DROPIN still there"; else echo "drop-in gone"; fi
if id alloy >/dev/null 2>&1; then echo "FAIL: user alloy still there"; else echo "user alloy gone"; fi
if [ -e "$ALLOY_HOME" ]; then echo "FAIL: $ALLOY_HOME still there"; else echo "$ALLOY_HOME gone"; fi
echo "Redis keys by prefix (after):"; redis_prefix_counts
echo "nginx logs of hosts without a vhost left: $(gone_logs | wc -l)"
if [ "$(peperoncini_state)" = "$PEP_BEFORE" ]; then echo "Peperoncini keys + logs unchanged"
else echo "NOTE: Peperoncini state changed during the run (app activity or logrotate?):"; peperoncini_state; fi
step "done (log: $LOG)"
