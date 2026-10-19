#!/bin/bash
# Read-only check for kuuak/IncServer#6, run from the controller after 2026-10-leftovers-cleanup.sh (no sudo needed):
#
#   ssh IncServer "bash -c $(printf %q "$(cat docs/runbooks/2026-10-leftovers-verify.sh)")" < /dev/null
#
# Prints one PASS/FAIL line per criterion and exits 1 if any fails. Redis keys: prefix and count only, never values.
set -uo pipefail
LIVE_PREFIXES='^(peperoncini-production|staging-peperoncini)$'   # the live Tenant's Environments (Peperoncini)
GONE_HOSTS=(demo.kuuak.ch glitchtip.kuuak.ch pizzeria-dolce-vita.ch staging.pizzeria-dolce-vita.ch pizzeriatomate.ch)
fail=0
check() { if [ "$1" = 0 ]; then echo "PASS  $2"; else echo "FAIL  $2"; fail=1; fi; }

id alloy >/dev/null 2>&1; check $(( $? == 0 )) "id alloy fails"
[ -e /etc/systemd/system/alloy.service.d ]; check $(( $? == 0 )) "Alloy drop-in /etc/systemd/system/alloy.service.d gone"
[ -e /var/lib/alloy ]; check $(( $? == 0 )) "alloy's home /var/lib/alloy gone"

# The checks below must fail, not pass, when they cannot see anything (Redis down or behind auth, wrong host,
# unreadable nginx dirs): an empty listing would otherwise read as "nothing left".
redis_ok=1; [ "$(redis-cli PING 2>/dev/null)" = PONG ] && redis_ok=0
nginx_ok=1; [ -r /var/log/nginx ] && [ -x /var/log/nginx ] && [ -n "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ] && nginx_ok=0

prefixes=$(for db in $(redis-cli INFO keyspace | sed -n 's/^db\([0-9]*\):.*/\1/p'); do
    redis-cli -n "$db" --scan | awk -F: -v db="$db" '{print "db" db " " $1}'
done | sort | uniq -c)
echo "      Redis keys by prefix:"; echo "${prefixes:-      (none)}" | sed 's/^/      /'
others=$(echo "$prefixes" | awk 'NF {print $3}' | grep -Ev "$LIVE_PREFIXES")
check "$([ "$redis_ok" = 0 ] && [ -z "$others" ] && echo 0 || echo 1)" \
    "Redis keys only have Peperoncini prefixes${others:+ (other: $(echo $others))}$([ "$redis_ok" = 0 ] || echo ' (Redis did not answer PING)')"

left=0
for h in "${GONE_HOSTS[@]}"; do
    n=$(find /var/log/nginx -maxdepth 1 \( -name "$h-access.log*" -o -name "$h-error.log*" \) | wc -l)
    [ "$n" = 0 ] || echo "      $h: $n log files"
    left=$((left + n))
done
nginx_why=$([ "$nginx_ok" = 0 ] || echo ' (/var/log/nginx unreadable or /etc/nginx/sites-enabled empty)')
check "$([ "$nginx_ok" = 0 ] && [ "$left" = 0 ] && echo 0 || echo 1)" "no nginx logs left for hosts without a vhost (${#GONE_HOSTS[@]} hosts)$nginx_why"
# Every log prefix left must belong to an enabled vhost or the default/json logs.
vhosts=$(grep -RhoE 'server_name[^;]*' /etc/nginx/sites-enabled/ | sed 's/server_name//' | tr ' ' '\n' | grep -E '\.' | sort -u)
orphans=$(ls /var/log/nginx | sed -nE 's/^(.+)-(access|error)\.log.*/\1/p' | sort -u | grep -vxF "$vhosts")
check "$([ "$nginx_ok" = 0 ] && [ -z "$orphans" ] && echo 0 || echo 1)" \
    "every per-host nginx log belongs to an enabled vhost${orphans:+ (orphans: $(echo $orphans))}$nginx_why"

exit $fail
