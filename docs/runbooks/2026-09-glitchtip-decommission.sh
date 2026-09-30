#!/bin/bash
# Decommission GlitchTip on IncServer after its move to KuuakServer (2026-09-30), drop the `mailhog` user,
# empty the `docker` group. Run by the owner (the agent's permissions block certbot delete / userdel):
#
#   scp docs/runbooks/2026-09-glitchtip-decommission.sh IncServer:
#   ssh IncServer 'sudo bash ~/2026-09-glitchtip-decommission.sh 2>&1 | sudo tee /root/cleanup-2026-09/glitchtip/decommission.log'
#
# Run only once glitchtip.kuuak.ch resolves to KuuakServer (v4 and v6) and the old 3600 s TTL has passed:
# the script refuses otherwise. Before-state already in /root/cleanup-2026-09/glitchtip/ (pg_dumpall.sql,
# glitchtip.kuuak.ch.conf.before); the script adds .env, home dirs and group memberships.
set -euo pipefail
umask 077
D=/root/cleanup-2026-09/glitchtip
step() { echo "== $(date -Is) $*"; }

step "preflight"
[ "$(dig +short A glitchtip.kuuak.ch @ns11.infomaniak.ch)" = 83.228.217.113 ] || { echo "A record not on KuuakServer yet"; exit 1; }
[ "$(dig +short AAAA glitchtip.kuuak.ch @ns11.infomaniak.ch)" = 2001:1600:18:200::3d2 ] || { echo "AAAA record not on KuuakServer yet"; exit 1; }
[ "$(curl -s -o /dev/null -w '%{http_code}' --resolve glitchtip.kuuak.ch:443:83.228.217.113 https://glitchtip.kuuak.ch/_health/)" = 200 ] \
    || { echo "GlitchTip on KuuakServer not healthy"; exit 1; }
[ -s "$D/pg_dumpall.sql" ] || { echo "final dump missing"; exit 1; }

step "keep before-state"
install -m 600 /var/www/glitchtip.kuuak.ch/.env "$D/env.before"
tar -C /home -czf "$D/homes-glitchtip-mailhog.tgz" glitchtip mailhog
getent group docker mailhog-www > "$D/groups.before"
stat -c '%U:%G %a %n' /var/www/mailhog.kuuak.ch /var/www/mailhog.kuuak.ch/docker-compose.yml > "$D/mailpit-perms.before"

step "GlitchTip stack: containers, network, images"
(cd /var/www/glitchtip.kuuak.ch && docker compose down < /dev/null)
docker image rm glitchtip/glitchtip:6 glitchtip/glitchtip:latest postgres:18 postgres:17 valkey/valkey:9 valkey/valkey:latest || true
docker volume rm glitchtipkuuakch_pg-data glitchtipkuuakch_uploads || true   # empty leftovers, data was in ./data

step "nginx vhost"
rm -f /etc/nginx/sites-enabled/glitchtip.kuuak.ch.conf
mv /etc/nginx/sites-available/glitchtip.kuuak.ch.conf "$D/glitchtip.kuuak.ch.conf.proxy"
nginx -t
systemctl reload nginx

step "certificate"
certbot delete --non-interactive --cert-name glitchtip.kuuak.ch

step "files and user glitchtip"
rm -rf /var/www/glitchtip.kuuak.ch
userdel glitchtip && rm -rf /home/glitchtip   # not -r: it fails on the absent mail spool

step "user mailhog (Mailpit compose now owned by root)"
chown root:root /var/www/mailhog.kuuak.ch /var/www/mailhog.kuuak.ch/docker-compose.yml
chmod 644 /var/www/mailhog.kuuak.ch/docker-compose.yml
userdel mailhog && rm -rf /home/mailhog   # group mailhog-www stays until #553 lands (handoff step 6)

step "docker group: netdata out (owner's call 2026-09-30), must end empty"
gpasswd -d netdata docker
systemctl restart netdata
[ -z "$(getent group docker | cut -d: -f4)" ] || { echo "docker group not empty: $(getent group docker)"; exit 1; }

step "verify"
(cd /var/www/mailhog.kuuak.ch && docker compose ps --format '{{.Name}} {{.State}}' < /dev/null)
curl -s -o /dev/null -w 'mailpit UI via nginx: %{http_code} (401 expected)\n' --resolve mailhog.kuuak.ch:443:127.0.0.1 https://mailhog.kuuak.ch/
curl -s -o /dev/null -w 'www: %{http_code}\n' --resolve www.pizzeria-peperoncini.ch:443:127.0.0.1 https://www.pizzeria-peperoncini.ch/
systemctl is-active nginx netdata docker
id glitchtip 2>&1 | tail -1; id mailhog 2>&1 | tail -1
step "done"
