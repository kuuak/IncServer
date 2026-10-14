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
| App jobs (`POST /api/cron/*`: payment check every 10 min, token purge daily 03:15) per Environment | `app-<user>-<job>.timer` | – (localhost) | `tenant` |
| PM2 log rotation per Environment (`<home>/.pm2/logs/*.log`, `pm2.log`): daily, `copytruncate`, 14 days gzipped | `/etc/logrotate.d/pm2-tenants` (logrotate.timer, 00:00) | – | `tenant` |
| PostgreSQL 16 (one role + DB per Environment), Redis | host | localhost only | `tenant` (roles/DBs) |
| nginx + certbot | host | 80, 443 (v4 + v6) | `nginx` |
| Mailpit (catches all app mail, ADR-0003) | compose, `/var/www/mailhog.kuuak.ch` | UI mailhog.kuuak.ch (basic auth); SMTP 1025 v4 | `mailpit` |
| Netdata | host (apt repo) | netdata.kuuak.ch (basic auth) | `netdata` |
| restic → Swiss Backup cluster 04, nightly 00:00 | host (systemd) | – | `backup` |
| Weekly reboot window, Tue 04:30, only if required | host (systemd) | – | `base` |
| healthchecks.io pings (email) for restic-backup, certbot, unattended-upgrades, production app jobs | systemd drop-ins + `/usr/local/sbin/hc-ping` | – | `healthchecks` (wired once the URLs are in the vault) |

## Usage

```sh
python3 -m venv ~/.venvs/ansible && ~/.venvs/ansible/bin/pip install ansible ansible-lint
export PATH=~/.venvs/ansible/bin:$PATH
ansible-galaxy collection install -r requirements.yml

ansible-playbook site.yml --check --diff      # always first; must show only what you intend
ansible-playbook site.yml --tags nginx        # apply one role
```

SSH goes through the `IncServer` entry in `~/.ssh/config` (user `ubuntu`, passwordless sudo).

Written on 2026-09-30 against the box as cleaned in `docs/runbooks/2026-09-cleanup.md`. The templates
render byte-identical to the live files; the goal is a full `--check` reporting `changed=0`.
Hardening is behind switches in `group_vars/all/vars.yml`, all off. Turn on one at a time.

## Tenants

Every Environment is one entry under `tenants:` in `group_vars/all/vars.yml`. Onboarding one (e.g. Tomate):

1. DNS for its hosts → IncServer (A + AAAA); add its DB password to the vault (`vault_tenant_db_passwords`).
2. Add the entry, `--check --diff --tags tenant,nginx`, apply: user, home, PM2 unit (enabled, not
   started), Postgres role + DB, port-map line, vhost.
3. `certbot certonly --nginx -d <host>` (certificates are not managed here), then `nginx -t && systemctl reload nginx`.
4. First deploy from the app repo; restore data if it moves from another host.
5. App jobs run from the first deploy on (skipped until `current/` exists); the release's env files need `CRON_SECRET`.
   For production, add two healthchecks.io checks (see `healthchecks_jobs`) and their URLs to the vault.

The production vhost of Peperoncini is shipped verbatim (`roles/tenant/files/vhosts/`, legacy redirects);
new Environments use `roles/tenant/templates/vhost.conf.j2`.

## Secrets

Never in plain text. `group_vars/all/vault.yml.example` lists what is needed; fill a copy,
`ansible-vault encrypt` it, commit only the encrypted file. Tasks that need a vault value skip
themselves while it is undefined. **Read the note at the top of `vault.yml.example` before the first run
with a filled vault**: the restic env and rclone.conf templates were written without reading those files.

## Not captured yet

- Packages (beyond restic/rclone/nodejs), certbot certificates, the apt sources (Docker, Netdata), unattended-upgrades
  config (only the NodeSource origin drop-in is managed, by `nodejs`)
- Tenant `authorized_keys`: per-Environment deploy keys arrive with delivery-order-app #553
- PostgreSQL / Redis config (both stock apart from what the packages ship), the Tenants' app files and `.env`

## Gotchas

- From a non-TTY (scripts, agents) run Ansible with `< /dev/null` and output redirected to a file, or it aborts with "requires blocking IO".
- An interrupted run can write a file without firing its handler; the next run says `changed=0` and the handler never runs. Run the handler's command by hand.
- No role restarts a Tenant's PM2, dockerd, ssh, journald or Postgres. Those take the pizzerias down or restart every container: do them by hand, outside opening hours.
- The box has no `python3-psycopg2`, so the `tenant` role talks to Postgres through `psql`: in `--check` a drifted DB shows as a changed "Postgres drift" task; an owner mismatch fails the run on purpose (fix it with a REASSIGN, as in step 8 of the cleanup runbook).
- Docker-published ports bypass ufw. Mailpit's SMTP (1025, v4) is only limited by the portal firewall until `mailpit_smtp_filter_enabled` is on.
- Every Environment runs on the system Node 22 (role `nodejs`); there is no per-user nvm. A `~/.nvm` in an Environment's
  home (e.g. copied over with a migrated Tenant) makes `deploy-server.sh` refuse to deploy: remove it, don't source it.
  Nothing else catches it: the Peperoncini PM2 dumps still carry nvm's bin dir in `PATH` (checked 2026-10-14), so
  the next PM2 restart or reboot would run the app on that nvm's Node.
- PM2 logs rotate with `copytruncate` (no PM2 reload), as each Environment's user. Never `cat`/`tail` them to look around: production's out-log holds whole orders (delivery-order-app#630). Measure with `wc`/`ls`.
- After a reboot, production Next.js needs ~60 s of cold start before the first 200.
- Never `source` or print a secrets file; inspect shapes (length, prefix) only.

## Runbooks

- [2026-09 cleanup and security pass](docs/runbooks/2026-09-cleanup.md)
- [2026-10 Node 22 switch, staging then production](docs/runbooks/2026-10-node22.md)
