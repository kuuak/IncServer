#!/bin/bash
# Issue #16, one Redis ACL user per Environment: the owner's checks and env-file edit for
# docs/runbooks/2026-10-redis-acl.md. Copy it over (scp docs/runbooks/2026-10-redis-acl.sh IncServer:/tmp/), then:
#
#   bash /tmp/2026-10-redis-acl.sh test <acl user> <own namespace> <other namespace>   as ubuntu
#   bash /tmp/2026-10-redis-acl.sh env <acl user> <namespace>                          as the Environment's user
#   bash /tmp/2026-10-redis-acl.sh clients                                             as ubuntu
#   bash /tmp/2026-10-redis-acl.sh orphans <old namespace> [delete]                    as ubuntu
#   sudo bash /tmp/2026-10-redis-acl.sh mark | errors                                  as ubuntu (sudo)
#
# test     The user's own keys and channels work; the other namespace's keys and channels, and every command the app
#          does not use, fail with NOPERM. It writes only <own>:acl-test (60 s TTL, deleted at the end) and publishes
#          only on <own>:acl-test and <other>:acl-test, names no app uses: even a broken ACL cannot reach the other
#          Environment's orders stream. Replies from the other namespace are never printed.
# env      Sets REDIS_NAMESPACE=<namespace>, then puts <acl user>:<password> into REDIS_URL, in
#          ~/current/.env.production.local, .env.production and .env.local (each one that defines the key;
#          .env.production.local if none does). Deploys copy these files into every new release. Changes nothing
#          unless Redis takes the login and lets that user use <namespace>:. Then prints the URL as the app resolves
#          it (password masked) and REDIS_NAMESPACE, checks both, and that neither the PM2 dump nor ecosystem.config.js
#          would override the files.
# clients  Redis connections by ACL user and protocol, and the ACL LOG (denials: user, reason, key or command name; never values).
# orphans  As admin: how many keys <old namespace>:* are left (a namespace no Environment uses any more); `delete`
#          UNLINKs them and counts again. Counts only, never a key name. Refuses a namespace an ACL user may still use.
# mark, errors
#          PM2 error-log line counts of every Environment: `mark` before a step, `errors` after it prints the new
#          error lines per log and how many of them mention Redis. Counts only, never a line: production's hold orders.
#
# Passwords are asked for (not echoed, never in argv) unless REDISCLI_AUTH is set. Each check prints PASS/FAIL;
# the exit status is 1 if any failed.
set -uo pipefail

usage() { sed -n '5,9p' "$0" >&2; exit 2; }
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=1; }
ask_password() {   # ask_password <acl user>
	if [ -z "${REDISCLI_AUTH+x}" ]; then
		read -rsp "Redis password for $1: " REDISCLI_AUTH
		echo
	fi
	export REDISCLI_AUTH
}
finish() {
	if [ "$fails" = 0 ]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
	exit "$fails"
}
# login_as <acl user>: Redis's reply to AUTH <user> <REDISCLI_AUTH> (OK, or WRONGPASS…). Every user may run AUTH, and
# a login that works leaves nothing in the ACL LOG (ACL WHOAMI did: an app user may not run it, a logged NOPERM). The
# password goes in on stdin from the printf builtin, never in argv.
login_as() {
	printf 'AUTH %s %s\n' "$1" "$REDISCLI_AUTH" |
		env -u REDISCLI_AUTH timeout 3 redis-cli --no-auth-warning 2>&1 | head -1
}
mark_file=/root/cleanup-2026-09/redis-acl-16.mark

cmd_test() {
	[ $# -eq 3 ] || usage
	local user=$1 own=$2 other=$3 login
	ask_password "$user"
	r() { timeout 3 redis-cli --no-auth-warning --user "$user" "$@" 2>&1; }

	# expect <description> <ERE the first reply line must match> <redis command...>
	# An error reply is shown; any other reply only when it comes from the own namespace.
	expect() {
		local desc=$1 want=$2 got shown
		shift 2
		got=$(r "$@" | head -1)
		case $got in
		NOPERM* | NOAUTH* | WRONGPASS* | ERR* | WRONGTYPE* | "Could not connect"* | "") shown=$got ;;
		*) if [[ "$*" == *"$other:"* ]]; then shown="a reply (not shown)"; else shown=$got; fi ;;
		esac
		if [[ $got =~ $want ]]; then pass "$desc"; else fail "$desc: got ${shown:0:100}"; fi
	}

	echo "== $user, own namespace $own:, other $other:"
	login=$(login_as "$user")
	if [ "$login" = OK ]; then pass "logged in as $user"; else fail "login as $user: ${login:0:100}"; finish; fi

	echo "-- own keys and channels work"
	expect "write own key (SETEX $own:acl-test)" '^OK$' SETEX "$own:acl-test" 60 acl-test
	expect "read own key (GET $own:acl-test)" '^acl-test$' GET "$own:acl-test"
	expect "read own SSE set (SCARD $own:sse:active)" '^[0-9]+$' SCARD "$own:sse:active"
	expect "publish on own channel (PUBLISH $own:acl-test)" '^[0-9]+$' PUBLISH "$own:acl-test" acl-test

	echo "-- the other Environment's keys and channels are refused"
	expect "write other key (SETEX $other:acl-test)" '^NOPERM' SETEX "$other:acl-test" 60 acl-test
	expect "read other key (GET $other:sse:broadcast:latest)" '^NOPERM' GET "$other:sse:broadcast:latest"
	expect "read other set (SMEMBERS $other:sse:active)" '^NOPERM' SMEMBERS "$other:sse:active"
	expect "read other set (SCARD $other:sse:active)" '^NOPERM' SCARD "$other:sse:active"
	expect "test other key (EXISTS $other:sse:active)" '^NOPERM' EXISTS "$other:sse:active"
	expect "delete other key (DEL $other:acl-test)" '^NOPERM' DEL "$other:acl-test"
	expect "publish on other channel (PUBLISH $other:acl-test)" '^NOPERM' PUBLISH "$other:acl-test" acl-test
	expect "subscribe to other channel (SUBSCRIBE $other:sse:broadcast)" '^NOPERM' SUBSCRIBE "$other:sse:broadcast"

	echo "-- commands the app does not use are refused, own keys included"
	expect "SET (not SETEX) on own key" '^NOPERM' SET "$own:acl-test" acl-test
	expect "SCAN" '^NOPERM' SCAN 0 COUNT 1
	expect "KEYS" '^NOPERM' KEYS "$own:*"
	expect "CONFIG GET" '^NOPERM' CONFIG GET maxmemory
	expect "SELECT 1" '^NOPERM' SELECT 1

	expect "clean up own key (DEL $own:acl-test)" '^1$' DEL "$own:acl-test"
	finish
}

cmd_env() {
	[ $# -eq 2 ] && [[ $2 =~ ^[a-z0-9-]+$ ]] || usage
	local user=$1 want_ns=$2 f edited=0 url ns login probe
	cd ~/current || { fail "no ~/current: run this as the Environment's user"; finish; }
	ask_password "$user"
	# Hex only: anything else would need URL escaping in REDIS_URL (vault.yml.example).
	[[ $REDISCLI_AUTH =~ ^[0-9a-f]{32,}$ ]] || { fail "the password is not hex (openssl rand -hex 32)"; finish; }
	# Before touching a file: does Redis take this password?
	login=$(login_as "$user")
	if [ "$login" = OK ]; then pass "Redis accepts $user with this password"
	else fail "Redis login as $user: ${login:0:100} (no file changed)"; finish; fi
	# ...and may this user use the namespace? (An app on its own user with another namespace gets NOPERM everywhere.)
	probe=$(timeout 3 redis-cli --no-auth-warning --user "$user" SCARD "$want_ns:sse:active" 2>&1 | head -1)
	if [[ $probe =~ ^[0-9]+$ ]]; then pass "$user may use $want_ns:"
	else fail "$user on $want_ns:sse:active: ${probe:0:100} (no file changed)"; finish; fi
	export PW=$REDISCLI_AUTH ACL_USER=$user NS=$want_ns

	# The namespace first: should this stop halfway, the app has the new namespace on the default user (harmless
	# while that user is on), never its own user on a namespace it may not use.
	edited=0
	for f in .env.production.local .env.production .env.local; do
		if ! [ -f "$f" ] || ! grep -Eq '^(export[[:space:]]+)?REDIS_NAMESPACE=' "$f"; then continue; fi
		edited=1
		if grep -Eq "^(export[[:space:]]+)?REDIS_NAMESPACE=[\"']?${want_ns}[\"']?[[:space:]]*(#.*)?\$" "$f"; then
			echo "      $f: REDIS_NAMESPACE already $want_ns"; continue
		fi
		# REDIS_NAMESPACE=[quote]old[quote] -> the new one, quotes and the rest of the line kept; mode kept.
		perl -i -pe 's{^((?:export\s+)?REDIS_NAMESPACE=)(["\x27]?)[^"\x27\s]*\2}{$1$2$ENV{NS}$2}' "$f" &&
			echo "      edited REDIS_NAMESPACE in $f"
	done
	if [ "$edited" = 0 ]; then
		(umask 077 && printf 'REDIS_NAMESPACE="%s"\n' "$want_ns" >>.env.production.local) &&
			echo "      added REDIS_NAMESPACE to .env.production.local (no Environment file defined it)"
	fi

	edited=0
	for f in .env.production.local .env.production .env.local; do
		if ! [ -f "$f" ] || ! grep -Eq '^(export[[:space:]]+)?REDIS_URL=' "$f"; then continue; fi
		# redis://[old user[:password]@]host… -> redis://<user>:<password>@host…, quotes and the rest kept; mode kept.
		perl -i -pe 's{^((?:export\s+)?REDIS_URL=["\x27]?redis://)(?:[^@/]*@)?}{$1$ENV{ACL_USER}:$ENV{PW}\@}' "$f" &&
			echo "      edited $f" && edited=1
	done
	if [ "$edited" = 0 ]; then
		(umask 077 && printf 'REDIS_URL="redis://%s:%s@127.0.0.1:6379"\n' "$user" "$PW" >>.env.production.local) &&
			echo "      added REDIS_URL to .env.production.local (no Environment file defined it)"
	fi

	url=$(NODE_ENV=production node scripts/deploy-env.mjs get REDIS_URL 2>/dev/null)
	ns=$(NODE_ENV=production node scripts/deploy-env.mjs get REDIS_NAMESPACE 2>/dev/null)
	echo "      REDIS_URL as the app resolves it: $(printf '%s' "$url" | sed -E 's#(://[^:@/]*:)[^@]*@#\1***@#')"
	echo "      REDIS_NAMESPACE: ${ns:-(unset: the app falls back to delivery-order-app)}"
	if [ "$ns" = "$want_ns" ]; then pass "REDIS_NAMESPACE is $want_ns"
	else fail "REDIS_NAMESPACE resolves to '${ns}', not $want_ns: fix it before restarting PM2"; fi
	# No /<db>: the user may not run SELECT.
	if [[ $url =~ ^redis://$user:[^@/]+@[^/]+$ ]]; then pass "REDIS_URL logs in as $user, no database number"
	else fail "REDIS_URL is not redis://$user:<password>@<host>:<port>"; fi
	if [ "$url" = "redis://$user:$PW@${url#*@}" ]; then pass "REDIS_URL carries the password typed"
	else fail "REDIS_URL carries another password than the one typed"; fi
	for f in ~/.pm2/dump.pm2 ecosystem.config.js; do   # an env set there would win over the files
		[ -f "$f" ] || continue
		if [ "$(grep -cE 'REDIS_(URL|NAMESPACE)' "$f")" = 0 ]; then pass "no REDIS_URL or REDIS_NAMESPACE in $f"
		else fail "$f sets REDIS_URL or REDIS_NAMESPACE too: change it there as well"; fi
	done
	unset PW
	finish
}

cmd_clients() {
	ask_password admin
	local a=(--no-auth-warning --user admin) list
	list=$(redis-cli "${a[@]}" CLIENT LIST 2>&1)
	[[ $list == *"id="* ]] || { fail "CLIENT LIST as admin: ${list:0:100}"; finish; }
	echo "Connections by ACL user and protocol (this one included, as admin; resp=3 is Netdata's HELLO 3, the apps use 2):"
	awk '{ u = r = ""; for (i = 1; i <= NF; i++) { if ($i ~ /^user=/) u = $i; if ($i ~ /^resp=/) r = $i }; print u, r }' \
		<<<"$list" | sort | uniq -c | sed 's/^ */      /'
	# `test`'s refused commands are denials too: run `ACL LOG RESET` after it.
	echo "ACL LOG (denials since the last ACL LOG RESET): entries user reason object"
	redis-cli "${a[@]}" ACL LOG | awk '
		prev == "reason" { r = $0 } prev == "object" { o = $0 }
		prev == "username" { print $0, r, o } { prev = $0 }' | sort | uniq -c | sed 's/^ */      /'
	echo "      (end)"
	finish
}

cmd_orphans() {
	[ $# -ge 1 ] && [ $# -le 2 ] && [ "${2:-delete}" = delete ] && [[ $1 =~ ^[a-z0-9-]+$ ]] || usage
	local ns=$1 n a=(--no-auth-warning --user admin) who
	ask_password admin
	who=$(redis-cli "${a[@]}" ACL WHOAMI 2>&1 | head -1)
	[ "$who" = admin ] || { fail "login as admin: ${who:0:100}"; finish; }
	# An ACL user that may use the namespace = an Environment still on it (vars.yml's redis_namespace).
	if redis-cli "${a[@]}" ACL LIST | grep -Fq " ~$ns:* "; then
		fail "an ACL user may still use $ns: (nothing deleted)"; finish
	fi
	n=$(redis-cli "${a[@]}" --scan --pattern "$ns:*" | wc -l)
	echo "      $n keys $ns:*"
	if [ "${2:-}" = delete ] && [ "$n" -gt 0 ]; then
		n=$(redis-cli "${a[@]}" --scan --pattern "$ns:*" | xargs -r -d '\n' redis-cli "${a[@]}" UNLINK |
			awk '{ s += $1 } END { print s + 0 }')
		echo "      unlinked $n"
	fi
	n=$(redis-cli "${a[@]}" --scan --pattern "$ns:*" | wc -l)
	if [ "${2:-}" != delete ]; then :
	elif [ "$n" = 0 ]; then pass "no $ns:* key left"
	else fail "$n keys $ns:* left"; fi
	finish
}

cmd_mark() {
	[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
	install -d -m 700 /root/cleanup-2026-09
	local f
	for f in /var/www/*/*/.pm2/logs/*-error.log; do
		[ -f "$f" ] && echo "$(wc -l <"$f") $f"
	done >"$mark_file"
	echo "Marked $(wc -l <"$mark_file") PM2 error logs at $(date '+%F %T'):"
	sed 's/^/      /' "$mark_file"
}

cmd_errors() {
	[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 2; }
	[ -f "$mark_file" ] || { echo "no mark yet: run mark first" >&2; exit 2; }
	echo "Since the mark of $(date -r "$mark_file" '+%F %T'):"
	local n f total redis
	while read -r n f; do
		total=$(wc -l <"$f")
		[ "$total" -lt "$n" ] && n=0   # rotated (copytruncate) since the mark: count the whole file
		redis=$(tail -n +"$((n + 1))" "$f" | grep -ci redis)
		echo "      $f: $((total - n)) new error lines, $redis of them mention Redis"
	done <"$mark_file"
}

case ${1:-} in
test) shift; cmd_test "$@" ;;
env) shift; cmd_env "$@" ;;
clients) cmd_clients ;;
orphans) shift; cmd_orphans "$@" ;;
mark) cmd_mark ;;
errors) cmd_errors ;;
*) usage ;;
esac
