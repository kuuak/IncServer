#!/bin/bash
# 2026-09 cleanup, step 8: one identity per Environment for Peperoncini.
#
#   - `peperoncini` (production): home moves /home/peperoncini -> /var/www/pizzeria-peperoncini.ch/production
#   - new `peperoncini-staging`: home /var/www/pizzeria-peperoncini.ch/staging, own PM2 + systemd unit
#   - new Postgres role `peperoncini-staging` owns the `peperoncini-staging` DB and all its objects,
#     fresh password written into staging's .env files (never printed)
#   - REVOKE CONNECT ... FROM PUBLIC on both Peperoncini DBs; `peperoncini` loses access to staging
#
# Run on IncServer as root:   sudo bash 2026-09-step8-staging-identity.sh 2>&1 | tee /root/cleanup-2026-09/peperoncini/step8.log
#
# Downtime: production ~10-20 s (PM2 restarts under the new home), staging ~1-2 min.
# Aborts on the first error (set -e). Where it stopped is the last "== " line in the log;
# see "Rollback" at the bottom of docs/runbooks/2026-09-cleanup.md.
set -euo pipefail

T=/var/www/pizzeria-peperoncini.ch
P=$T/production            # = ~peperoncini
S=$T/staging               # = ~peperoncini-staging
OLD_HOME=/home/peperoncini
MOVED_HOME=/home/peperoncini.moved-2026-09   # kept as a backup copy; delete after 2026-10-06
SU=peperoncini-staging
NODE_V=v20.19.5
C=/root/cleanup-2026-09/peperoncini
PM2_BIN=lib/node_modules/pm2/bin/pm2

say() { printf '\n== %s  %s\n' "$(date +%T)" "$*"; }
# Ubuntu's ~/.bashrc returns early for non-interactive shells, so nvm must be sourced explicitly
as() { local u=$1; shift; sudo -iu "$u" bash -c "source ~/.nvm/nvm.sh; $*"; }

say "0. Preconditions"
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -d "$OLD_HOME" ] || { echo "$OLD_HOME missing: already moved?"; exit 1; }
getent passwd "$SU" >/dev/null && { echo "user $SU already exists"; exit 1; }
test -f "$P/current/ecosystem.config.js"
test -f "$S/current/ecosystem.config.js"
grep -q 'name: "Pizzeria-Peperoncini"' "$P/current/ecosystem.config.js"
grep -q 'name: "staging"' "$S/current/ecosystem.config.js"
install -d -m 700 "$C"
cp -p /etc/systemd/system/pm2-peperoncini.service "$C/pm2-peperoncini.service.before"
getent passwd peperoncini > "$C/passwd.peperoncini.before"
cp -p "$S/current/.env.local" "$S/current/.env.production.local" "$C/" && chmod 600 "$C"/.env*
echo ok

say "1. Stop peperoncini's PM2 (prod + staging go down)"
systemctl stop pm2-peperoncini.service || true
as peperoncini 'pm2 kill >/dev/null 2>&1 || true'
pkill -u peperoncini || true; sleep 2
pgrep -u peperoncini >/dev/null && { echo "peperoncini still has processes"; exit 1; }
systemctl disable pm2-peperoncini.service
rm /etc/systemd/system/pm2-peperoncini.service; systemctl daemon-reload

say "2. Move peperoncini's home into the production Environment"
# .pm2 is NOT carried over: its dump has HOME/PATH baked in. PM2 starts fresh from ecosystem.config.js.
rsync -a --exclude=/.pm2 --exclude=/www "$OLD_HOME"/ "$P"/
mv "$OLD_HOME" "$MOVED_HOME"          # stale absolute paths now fail loudly instead of silently working
usermod -d "$P" peperoncini
chown peperoncini:peperoncini "$P"; chmod 711 "$P"
chmod 700 "$P/.ssh" "$P/backups"; chmod 600 "$P/.ssh/authorized_keys"
getent passwd peperoncini

say "3. Create peperoncini-staging (home = staging Environment, no password)"
useradd -d "$S" -M -s /bin/bash -U "$SU"
cp /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout "$S"/
printf '\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"\n' >> "$S/.bashrc"
rsync -a "$P/.nvm/" "$S/.nvm/"
install -d -m 700 "$S/.ssh" "$S/backups"
# Same deploy key as today, locked down with `restrict`. Per-Environment keys come with #553.
grep 'github-deploy' "$P/.ssh/authorized_keys" | sed 's/^/restrict /' > "$S/.ssh/authorized_keys"
chmod 600 "$S/.ssh/authorized_keys"
chown -R "$SU:$SU" "$S"
find "$S" -type d -exec chmod u=rwx,go=rx,g-s {} +
find "$S" -type f -exec chmod u+rw,go+r,go-w {} +
find "$S/current" -maxdepth 1 \( -name '.env*' -o -name ecosystem.config.js \) -type f -exec chmod 600 {} +
[ -d "$S/current/logs" ] && chmod 700 "$S/current/logs"
chmod 711 "$S"; chmod 700 "$S/.ssh" "$S/backups" "$S/.nvm"
passwd -S "$SU"

say "4. Postgres: role peperoncini-staging owns the staging DB"
PW=$(openssl rand -hex 24)
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -v pw="$PW" <<'SQL'
CREATE ROLE "peperoncini-staging" LOGIN PASSWORD :'pw';
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -q -d peperoncini-staging <<'SQL'
BEGIN;
ALTER DATABASE "peperoncini-staging" OWNER TO "peperoncini-staging";
ALTER SCHEMA public OWNER TO "peperoncini-staging";
DO $$ DECLARE r record; BEGIN
  -- Tables first: ALTER TABLE also moves the sequences they own
  FOR r IN SELECT c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m') AND pg_get_userbyid(c.relowner) = 'peperoncini' LOOP
    EXECUTE format('ALTER %s public.%I OWNER TO %I',
      CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
      r.relname, 'peperoncini-staging');
  END LOOP;
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind = 'S' AND pg_get_userbyid(c.relowner) = 'peperoncini' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO %I', r.relname, 'peperoncini-staging');
  END LOOP;
  -- Prisma enums
  FOR r IN SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE n.nspname = 'public' AND t.typtype IN ('e','d') AND pg_get_userbyid(t.typowner) = 'peperoncini' LOOP
    EXECUTE format('ALTER TYPE public.%I OWNER TO %I', r.typname, 'peperoncini-staging');
  END LOOP;
END $$;
COMMIT;
SQL
sudo -u postgres psql -v ON_ERROR_STOP=1 -q <<'SQL'
REVOKE CONNECT, TEMPORARY ON DATABASE "peperoncini-staging" FROM PUBLIC;
REVOKE CONNECT, TEMPORARY ON DATABASE "pizzeriapeperoncini" FROM PUBLIC;
REVOKE ALL ON DATABASE "peperoncini-staging" FROM peperoncini;
SQL
left=$(sudo -u postgres psql -d peperoncini-staging -Atc "
  SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND pg_get_userbyid(c.relowner)='peperoncini'")
[ "$left" = 0 ] || { echo "$left objects still owned by peperoncini"; exit 1; }
echo "objects owned by peperoncini in staging DB: $left"

say "5. Point staging's .env files at the new role (password not printed)"
for f in "$S/current/.env.local" "$S/current/.env.production.local"; do
  PW="$PW" python3 - "$f" <<'PY'
import os, re, sys
p = sys.argv[1]; s = open(p).read()
new, n = re.subn(r'postgresql://peperoncini:[^@]*@(localhost|127\.0\.0\.1)(:\d+)?/peperoncini-staging\b',
                 lambda m: "postgresql://peperoncini-staging:%s@%s%s/peperoncini-staging"
                           % (os.environ["PW"], m.group(1), m.group(2) or ""), s)
assert n >= 1, "no staging DATABASE_URL found in " + p
open(p, "w").write(new)
print("%s: %d URL(s) updated" % (p, n))
PY
done
unset PW

say "6. Start production under the new home, supervised by systemd"
as peperoncini "cd $P/current && pm2 start ecosystem.config.js >/dev/null && pm2 save >/dev/null && pm2 kill >/dev/null"
env PATH="$PATH:$P/.nvm/versions/node/$NODE_V/bin" "$P/.nvm/versions/node/$NODE_V/$PM2_BIN" \
  startup systemd -u peperoncini --hp "$P" >/dev/null
systemctl start pm2-peperoncini.service

say "7. Start staging as peperoncini-staging, supervised by systemd"
as "$SU" "cd $S/current && pm2 start ecosystem.config.js >/dev/null && pm2 save >/dev/null && pm2 kill >/dev/null"
env PATH="$PATH:$S/.nvm/versions/node/$NODE_V/bin" "$S/.nvm/versions/node/$NODE_V/$PM2_BIN" \
  startup systemd -u "$SU" --hp "$S" >/dev/null
systemctl start "pm2-$SU.service"

say "8. restic: don't back up per-user Node installs now that homes live under /var/www"
grep -qx '\*\*/.nvm' /etc/restic/excludes.txt || printf '**/.nvm\n**/.npm\n' >> /etc/restic/excludes.txt
cat /etc/restic/excludes.txt

say "9. Verify"
sleep 8
for u in peperoncini "$SU"; do
  echo "-- $u: $(systemctl is-active pm2-$u) / $(systemctl is-enabled pm2-$u)"
  as "$u" 'pm2 jlist' | python3 -c 'import sys,json; [print("  ", p["name"], p["pm2_env"]["status"], p["pm2_env"]["pm_cwd"]) for p in json.load(sys.stdin)]'
done
for hp in "www.pizzeria-peperoncini.ch 3000" "staging.pizzeria-peperoncini.ch 3010"; do
  set -- $hp
  echo "-- $1 via :$2 -> $(curl -s -o /dev/null -m 15 -w '%{http_code}' -H "Host: $1" http://127.0.0.1:$2/)"
done
sudo -u postgres psql -Atc "
  SELECT r, d, has_database_privilege(r, d, 'CONNECT')
    FROM unnest(array['peperoncini','peperoncini-staging']) r,
         unnest(array['pizzeriapeperoncini','peperoncini-staging']) d ORDER BY 1,2"
stat -c '%A %U:%G %n' "$T" "$P" "$S" "$P/.ssh" "$S/.ssh" "$S/current/.env.local"
say "done"
