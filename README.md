# IncServer

Source of truth for the VPS `IncServer` (`83.228.208.186` / `2001:1600:18:100::68`, Infomaniak, Ubuntu 24.04,
4 GB), the production host of the delivery-order-app (`kuuak/delivery-order-app`).
The server is a deploy target: change config here, dry-run, apply. Do not edit on the box.
Vocabulary (Tenant, Environment, ...): [CONTEXT.md](CONTEXT.md).

## What runs there

| Service | Where | Public via | Role |
|---|---|---|---|
| Tenant Environments (Next.js under PM2, one Unix user each) | `/var/www/<domain>/<env>`, `pm2-<user>.service` | tenant domains → port map | `tenant` (+ `nginx` port map) |
| Node 22 + PM2 for the Environments | host (NodeSource apt) | – | `nodejs` |
| App jobs (`POST /api/cron/*`: payment check every 10 min, token purge daily 03:15) per Environment | `app-<user>-<job>.timer` | – (localhost; nginx answers `/api/cron/*` with 404) | `tenant` |
| PM2 log rotation per Environment (`<home>/.pm2/logs/*.log`, `pm2.log`): daily, `copytruncate`, 14 days kept (gzipped but the newest) | `/etc/logrotate.d/pm2-tenants` (logrotate.timer, 00:00–01:00) | – | `tenant` |
| PostgreSQL 16 (one role + DB per Environment), Redis 7.0 (one ACL user per Environment, see below) | host | localhost only | `tenant` (roles/DBs, Redis users) |
| nginx + certbot | host | 80, 443 (v4 + v6) | `nginx` |
| Mailpit (catches all app mail, ADR-0003) | compose, `/var/www/mailhog.kuuak.ch` | UI mailhog.kuuak.ch (basic auth); SMTP 1025 v4 | `mailpit` |
| Netdata | host (apt repo) | netdata.kuuak.ch (basic auth) | `netdata` |
| restic → Swiss Backup cluster 04, nightly 00:00 (structural `restic check` each run); data check of one twelfth of the packs on the 1st, 02:30 | host (systemd: `restic-backup.timer`, `restic-check-data.timer`) | – | `backup` |
| Weekly reboot window, Tue 04:30, only if required | host (systemd) | – | `base` |
| healthchecks.io pings (email) for restic-backup, the monthly restic data check, certbot, unattended-upgrades, production app jobs | systemd drop-ins + `/usr/local/sbin/hc-ping` | – | `healthchecks` (wired once the URLs are in the vault) |
| Login status screen for admins (`incserver-status`, at login for `sudo` members; replaces Ubuntu's help links, ads and sysinfo) | `/usr/local/bin/incserver-status`, cache by `motd-collect.timer` (5 min) in `/run/incserver-status` | – | `motd` |

## Usage

```sh
python3 -m venv ~/.venvs/ansible && ~/.venvs/ansible/bin/pip install ansible ansible-lint
export PATH=~/.venvs/ansible/bin:$PATH
ansible-galaxy collection install -r requirements.yml

ansible-playbook site.yml --check --diff      # always first; must show only what you intend
ansible-playbook site.yml --tags nginx        # apply one role
```

SSH goes through the `IncServer` entry in `~/.ssh/config` (user `ubuntu`, passwordless sudo). sshd only lets in
`ubuntu` and the Environment users (`AllowUsers`), with `MaxAuthTries 3` and no TCP or agent forwarding (no `ssh -L`).
On the box, `incserver-status` answers "is anything wrong, is it safe to touch things?" (also shown at login);
`sudo systemctl start motd-collect` refreshes it. Every apply records the controller's commit, time, user and tags in `/etc/incserver-release`.

Written on 2026-09-30 against the box as cleaned in `docs/runbooks/2026-09-cleanup.md`. The templates
render byte-identical to the live files; the goal is a full `--check` reporting `changed=0`.
Hardening is behind switches in `group_vars/all/vars.yml`, all off. Turn on one at a time.

## Tenants

Every Environment is one entry under `tenants:` in `group_vars/all/vars.yml`. Onboarding one (e.g. Tomate):

1. DNS for its hosts → IncServer (A + AAAA); add its DB password (`vault_tenant_db_passwords`) and its Redis password
   (`vault_tenant_redis_passwords`, hex) to the vault.
2. Add the entry (with its `redis_namespace`), `--check --diff --tags base,tenant,nginx`, apply: sshd `AllowUsers`, user,
   home, PM2 unit (enabled, not started), Postgres role + DB, Redis ACL user, port-map line, vhost. The Redis user
   change reconnects every Environment's Redis clients (below): apply while the pizzerias are closed.
3. `certbot certonly --nginx -d <host>` (certificates are not managed here), then `nginx -t && systemctl reload nginx`.
4. First deploy from the app repo; restore data if it moves from another host.
5. App jobs run from the first deploy on (skipped until `current/` exists); the release's env files need `CRON_SECRET`,
   and `REDIS_URL=redis://<user>:<password>@127.0.0.1:6379` + `REDIS_NAMESPACE=<redis_namespace>`.
   For production, add two healthchecks.io checks (see `healthchecks_jobs`) and their URLs to the vault.

The production vhost of Peperoncini is shipped verbatim (`roles/tenant/files/vhosts/`, legacy redirects);
new Environments use `roles/tenant/templates/vhost.conf.j2`.

Every Tenant HTTPS server includes `/etc/nginx/snippets/tenant-headers.conf` (role `nginx`): HSTS
(`max-age=31536000`, no `preload`), `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`,
all `always`; `app-locations.conf` includes it again in `/uploads/` (its own `add_header` drops the server's). A new vhost,
template or verbatim, includes it in each `listen 443` server. Per-Environment option on a `tenants` entry:

- `noindex: true`: every response also carries `X-Robots-Tag: noindex, nofollow` (a host → value map in
  `conf.d/tenant-robots.conf`, rendered by the `nginx` role). Set it on staging Environments, never on production.

### Redis: one ACL user per Environment

Each Environment reaches Redis as its own ACL user, named like its Unix user (`peperoncini`, `peperoncini-staging`),
with its password from `vault_tenant_redis_passwords`. It may touch only keys `<redis_namespace>:*` and the channels
of the same name (`<tenant>-<environment>`: `peperoncini-production`, `peperoncini-staging`; the app's `REDIS_NAMESPACE`),
and run only `redis_app_commands`, the ones delivery-order-app uses for SSE (`vars.yml`). The app logs in through its
`REDIS_URL` (`redis://<user>:<password>@<host>:6379`, no `/<db>`) in the release's `.env.*` files, which every deploy
carries over. Besides them: `admin` (local admin, every key and command: `redis-cli --user admin --askpass`) and
`netdata` (its collector: `PING`, `INFO`, `CONFIG GET`). The stock `default` user (no password, everything) was on
for the switch-over (`redis_default_user_enabled: true`) and is off (`false`) from the rollout's step 7 on: unauthenticated
`redis-cli PING` gets `NOAUTH`, and a look around needs `redis-cli --user admin --askpass`.

The users live in `/etc/redis/users.acl` (template `redis-users.acl.j2`, SHA-256 hashes only, `aclfile` in
`redis.conf`); the role tries a new file in a throwaway Redis before writing it, and its `Reload Redis ACLs` handler
loads it with `ACL LOAD`. Never `ACL SETUSER` / `ACL SAVE` on the box: the next apply undoes it. `ACL LOAD` closes
every connection of a non-default user, and a Redis restart every connection: the apps reconnect in about a second
(an order event meanwhile reaches only the instance that saw it) and log one Redis error per connection. So change
Redis users while the pizzerias are closed. Rollout and checks: [2026-10-redis-acl.md](docs/runbooks/2026-10-redis-acl.md).

## Secrets

Never in plain text. `group_vars/all/vault.yml.example` lists what is needed; fill a copy,
`ansible-vault encrypt` it, commit only the encrypted file. Tasks that need a vault value skip
themselves while it is undefined. **Read the note at the top of `vault.yml.example` before the first run
with a filled vault**: the restic env and rclone.conf templates were written without reading those files.

## Not captured yet

- Packages (beyond restic/rclone/nodejs), certbot certificates, the apt sources (Docker, Netdata), unattended-upgrades
  config (only the third-party origin drop-ins are managed: NodeSource by `nodejs`, Docker by `docker`, Netdata by `netdata`)
- Tenant `authorized_keys`: per-Environment deploy keys arrive with delivery-order-app #553
- PostgreSQL config (stock apart from what the package ships), Redis config (stock but `aclfile`), the Tenants' app files and `.env`

## Gotchas

- From a non-TTY (scripts, agents) run Ansible with `< /dev/null` and output redirected to a file, or it aborts with "requires blocking IO".
- `/etc/incserver-release` (role `motd`, every apply whatever the tags) is rewritten on every apply, so an apply always reports
  one changed task; a `--check` reports it only when the box's last apply was another commit or uncommitted diff.
- An interrupted run can write a file without firing its handler; the next run says `changed=0` and the handler never runs. Run the handler's command by hand.
- No role restarts a Tenant's PM2, dockerd, ssh, journald, Postgres or Redis. Those take the pizzerias down or restart every container: do them by hand, outside opening hours.
  The one exception is unattended-upgrades: a Docker CE update restarts dockerd (so Mailpit) during apt-daily-upgrade (06:00 + up to 60 min).
- The box has no `python3-psycopg2`, so the `tenant` role talks to Postgres through `psql`: in `--check` a drifted DB shows as a changed "Postgres drift" task; an owner mismatch fails the run on purpose (fix it with a REASSIGN, as in step 8 of the cleanup runbook).
- Docker-published ports bypass ufw. Mailpit's SMTP (1025, v4) is limited by `DOCKER-USER` (`mailpit_smtp_filter_enabled`,
  unit `mailpit-smtp-filter`, re-applied on every dockerd start) and by the portal firewall.
- Docker log options (`daemon.json`, 10 MB x 3) only reach containers created after a dockerd restart: recreate them.
- Every Environment runs on the system Node 22 (role `nodejs`); there is no per-user nvm. A `~/.nvm` in an Environment's
  home (e.g. copied over with a migrated Tenant) makes `deploy-server.sh` refuse to deploy: remove it, don't source it.
  Nothing else catches it: the Peperoncini PM2 dumps still carry nvm's bin dir in `PATH` (checked 2026-10-14), so
  the next PM2 restart or reboot would run the app on that nvm's Node.
- PM2 logs rotate with `copytruncate` (no PM2 reload), as each Environment's user. Never `cat`/`tail` them to look around: production's out-log holds whole orders (delivery-order-app#630). Measure with `wc`/`ls`.
  Rotated copies are excluded from restic (role `backup`), like the live `*.log`.
- After a reboot, production Next.js needs ~60 s of cold start before the first 200.
- Never `source` or print a secrets file; inspect shapes (length, prefix) only.

## Runbooks

- [2026-09 cleanup and security pass](docs/runbooks/2026-09-cleanup.md)
- [2026-10 Node 22 switch, staging then production](docs/runbooks/2026-10-node22.md)
- [2026-10 one Redis ACL user per Environment, staging then production](docs/runbooks/2026-10-redis-acl.md)
- [Backup verification: monthly data check, restore drill and its log](docs/runbooks/backup-verification.md)
