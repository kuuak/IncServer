# 2026-09: cleanup and security pass (before the Ansible baseline)

Everything removed or changed by hand on IncServer before the box is captured as code. One row per change:
what it was, the evidence, where the "before" state is kept, and how to undo it.

On the box, "before" copies live in `/root/cleanup-2026-09/` (0700, covered by restic via `/root`).

| Date (CEST) | Change | Evidence | Before state | Undo |
|---|---|---|---|---|
| 2026-09-29 22:43 | Pre-cleanup restic snapshot `c7ca451d`, `restic check` clean | Safety net for everything below | – | `restic restore c7ca451d …` (see KuuakServer `docs/runbooks/restore.md`, same scheme) |
| 2026-09-29 22:46 | **Dolce Vita decommissioned** (out of business 2026-05): PM2 daemon + PM2+ agent (`pm2 unlink`, `pm2 kill`), `pm2-dolcevita.service`, certs `pizzeria-dolce-vita.ch`, `www.`, `staging.`, vhosts (were already disabled), DBs `pizzeria-dolcevita` + `pizzeria-dolcevita-staging`, role `dolcevita`, user + home, group `dolcevita-www`, `/var/www/pizzeria-dolce-vita.ch` (3.4 GB) | App deleted from PM2 on 2026-05-15 (`.bash_history`), sites 000 | `/root/cleanup-2026-09/dolcevita/`: final `pg_dump -Fc` of both DBs (23 tables each, verified with `pg_restore -l`), vhosts, unit, cert renewal confs, `.env*`, old `~/backups` | Recreate as a new Tenant; data via `pg_restore` |
| 2026-09-29 22:49 | **demo.kuuak.ch and Tomate leftovers decommissioned, no dump** (owner's call): vhosts, certs `demo.kuuak.ch` + `next.pizzeriatomate.ch`, DBs `demokuuakch` + `pizzeria-tomate`, roles, users `demokuuakch` + `tomate`, `/var/www/demo.kuuak.ch` (3.8 GB), `/var/www/pizzeriatomate.ch` (2.7 GB), their lines in `conf.d/app-ports-map.conf` | demo answered 502 (nothing on :3200); Tomate live on another host, `next.` half-built in January | vhosts + port map in `/root/cleanup-2026-09/demo-tomate/`; data only in older restic snapshots (until retention expires) | Onboard again through the Ansible `tenant` role |
| 2026-09-29 22:49 | Incident, self-inflicted, no impact: the port-map `sed` also deleted the map's closing `}`; `nginx -t` failed so nginx kept the old config in memory. Fixed 22:50 (brace restored, `nginx -t` ok, reload, `www` 200) | – | – | – |
| 2026-09-29 22:51 | restic secrets moved out of the world-readable script (`0755`) into `/etc/restic/env` (`0600`), loaded by drop-in `restic-backup.service.d/env.conf`. `rclone.conf` chowned `ubuntu` → `root` | Any local user could read `RESTIC_PASSWORD` since 2025-10 | `/root/cleanup-2026-09/restic/restic-backup.sh.before` | Copy the script back, remove the drop-in |
| 2026-09-29 22:53 | 2 GB `/swapfile`, `vm.swappiness=10` (`/etc/sysctl.d/99-swap.conf`); `OOMScoreAdjust=-900` drop-ins for `ssh`, `nginx`, `postgresql@16-main`, `systemd-journald`, applied live via `/proc/<pid>/oom_score_adj` | No swap on 3.8 GB; KuuakServer's Sep 2026 outages were global OOMs | `/root/cleanup-2026-09/misc/fstab.before` | `swapoff /swapfile`, drop fstab line + drop-ins |
| 2026-09-29 22:53 | sshd drop-in `/etc/ssh/sshd_config.d/10-incserver.conf`: `PermitRootLogin no`, `X11Forwarding no`. Fresh logins tested: `ubuntu` ok, `peperoncini` ok, `root` refused | Root only had cloud-init's "login as ubuntu" stub key | – | Delete the drop-in, `systemctl reload ssh` |
| 2026-09-29 22:55 | Mailpit (`/var/www/mailhog.kuuak.ch/docker-compose.yml`): UI `127.0.0.1:8025` only, SMTP `0.0.0.0:1025` (no more `[::]`); nginx `proxy_pass` → `127.0.0.1:8025`. Verified: UI 401 via nginx, 8025 closed outside, 1025 open from KuuakServer, closed on v6 | Docker published both ports on v4 + v6, bypassing ufw | `/root/cleanup-2026-09/misc/mailpit-docker-compose.yml.before`, `mailhog.kuuak.ch.conf.before` | Copy back, `docker compose up -d` |
| 2026-09-29 23:10 | **Peperoncini production file layout**: tenant root `root:root 755` (ACL + setgid removed); `production/` `peperoncini:peperoncini`, dirs 755, files `go+r` (exec bits kept), `.env*` / `ecosystem.config.js` / `deploy.sh` 600, `logs/` + `backups/` 700. `www-data` removed from `peperoncini-www` and `peperoncini-webgrp`, nginx reloaded. Verified 200 on `/`, `/uploads/…`, `/_next/static/…` | nginx was in the Tenant's group, which could read `.env.local` (0740): any nginx compromise read the payment credentials. Now nginx reads only world-readable public files | `/root/cleanup-2026-09/peperoncini/vhost-perms.before.acl.gz` (`getfacl -R`), `groups.before` | `cd / && zcat …/vhost-perms.before.acl.gz \| setfacl --restore=-`; `gpasswd -a www-data peperoncini-www` |
| 2026-09-29 23:23–23:28 | **Step 8**, per-Environment identity: see `2026-09-step8-staging-identity.sh` (run by the owner) and its log in `/root/cleanup-2026-09/peperoncini/step8.log`. `~peperoncini` = `…/production`, new `peperoncini-staging` (uid 1009) = `…/staging`, both homes `711`, own `pm2-<user>.service` (active + enabled). DB role `peperoncini-staging` owns the staging DB; CONNECT matrix: each role reaches only its own DB. Verified from outside: prod + staging `/` and `/uploads/…` 200; `pg_stat_activity` shows each app on its own role; no errors in PM2 logs. Staging deploys fail until #553 lands | ADR-0003 says one owner role per Environment; the box had one Unix user + one DB role for prod and staging | `/root/cleanup-2026-09/peperoncini/` (`pm2-peperoncini.service.before`, `passwd.peperoncini.before`, staging `.env*`), `/home/peperoncini.moved-2026-09/` (delete after 2026-10-06) | See "Step 8 rollback" below |
| 2026-09-29 23:35 | Pre-upgrade restic snapshot `809912a5`, check clean | Captures step 8's state | – | – |
| 2026-09-29 23:36 | `apt-get full-upgrade` (48 packages: openssl/libssl3t64, krb5, apparmor, docker-ce + containerd, …; exit 0, 0 left) then **supervised reboot** 23:36:47 → SSH back 23:37:33. Kernel 6.8.0-139 → 6.8.0-142. After: `systemctl --failed` empty; nginx, postgresql@16-main, redis, docker, netdata, both `pm2-*` active (0 restarts); containers up; swap + OOM scores + sshd settings persisted. Outside: prod/staging `/` + `/uploads` 200 (prod needed ~60 s of cold start, first probe timed out), GlitchTip 200 after its own warm-up, root refused, 1025 only from KuuakServer | Security updates had piled up for 20 days (unattended-upgrades never reboots) | `/root/cleanup-2026-09/apt-full-upgrade.log` | Boot `6.8.0-139` from GRUB via the Infomaniak console |
| 2026-09-29 23:39 | **Weekly maintenance reboot**: `/usr/local/sbin/reboot-if-required` + `reboot-if-required.{service,timer}`, `OnCalendar=Tue 04:30 Europe/Zurich`, `Persistent=false`; reboots only if `/var/run/reboot-required` exists. unattended-upgrades `Automatic-Reboot` stays unset (it can't pick a weekday). First window 2026-10-06 04:30 | Owner's decision (Peperoncini closed on Tuesdays) | – | `systemctl disable --now reboot-if-required.timer` |
| 2026-09-29 23:40 | Closing restic snapshot `5fa98624`, check clean. Disk `/` 34 GB → 25 GB used | – | – | – |
| 2026-09-29 23:49–23:55 | **restic password rotated** by the owner: new key `ebd69a36` added, `/etc/restic/env` switched, full run `Result=success` (23:52), old key removed, `restic check` clean (34 snapshots). Exactly one key left; temp files shredded. Master key unchanged, by design: rotation replaces the password that unlocks it | Old password was world-readable in the script 2025-10 → 2026-09-29; Swiss Backup creds (`rclone.conf`) never were, so a new repo was not needed | New password in the owner's password manager | – |
| 2026-09-29 22:31 | Locked passwords of `peperoncini`, `dolcevita`, `tomate`, `demokuuakch`, `glitchtip`, `mailhog` (`passwd -l`) | Every one of them had password == username, set by delivery-order-app `scripts/new-vhost.sh` (`echo "$USER:$USER" \| chpasswd`). SSH password auth was already off, but locally `su - glitchtip` + `docker` group = root. Verified after: key logins and `sudo -iu <user>` still work, PM2 apps untouched | `/root/cleanup-2026-09/shadow.before-lock` | `passwd -u <user>` (do not: use `sudo -iu <user>` from `ubuntu`) |

## Still open after this pass

| What | Where / who |
|---|---|
| Dual-stack web: `listen [::]:80` / `[::]:443 ssl` on the Peperoncini vhosts (AAAA already points here; portal allows v6 80/443; nginx refuses today) | Ansible `nginx` role, or by hand first |
| healthchecks.io: start / success / fail pings for `restic-backup`, `certbot`, `unattended-upgrades` (email only) | Needs the 3 ping URLs from the owner |
| Move GlitchTip to KuuakServer; then drop `glitchtip` + `mailhog` users from the `docker` group, remove `mailhog` user (Mailpit compose owned by root) | Next session |
| Deploy: per-Environment keys, secrets stay on the box, pinned actions + host key, `--chmod` instead of `--chown`; staging deploys fail until then | delivery-order-app #553 (owner, in progress) |
| Node 22 via NodeSource, drop per-user nvm | delivery-order-app #554 + Ansible |
| Delete groups `peperoncini-www`, `peperoncini-webgrp`, `mailhog-www` | After #553 lands |
| Delete `/home/peperoncini.moved-2026-09` | After 2026-10-06 |
| Prune pre-deploy dumps (`<env>/backups`, older than 14 days) | Ansible `tenant` role |
| Bootstrap the Ansible repo against the cleaned box (`--check` = `changed=0`), then onboard Tomate through the `tenant` role | Next session |
| App noise: `[theme] Could not read theme file` logged on every render when `public/theme.json` is absent (317k lines in the old PM2 log) | delivery-order-app, small issue |

## Step 8 rollback

Only needed if the script aborts halfway or prod misbehaves. The last `== ` line in `step8.log` says how far it got.

1. Prod first: `systemctl stop pm2-peperoncini`, `pkill -u peperoncini`; if `/home/peperoncini.moved-2026-09` exists,
   `mv` it back to `/home/peperoncini` and `usermod -d /home/peperoncini peperoncini`; restore
   `/root/cleanup-2026-09/peperoncini/pm2-peperoncini.service.before` to `/etc/systemd/system/pm2-peperoncini.service`,
   `systemctl daemon-reload && systemctl enable --now pm2-peperoncini` (resurrects the old dump: prod + staging).
2. Staging DB (if step 4 ran): `ALTER DATABASE "peperoncini-staging" OWNER TO peperoncini`, then in that DB
   `REASSIGN OWNED BY "peperoncini-staging" TO peperoncini` (this DB only has staging objects; it also moves the
   database back), `GRANT CONNECT ON DATABASE "peperoncini-staging" TO peperoncini`, `DROP ROLE "peperoncini-staging"`.
   Copy the staging `.env.local` / `.env.production.local` back from `/root/cleanup-2026-09/peperoncini/`.
3. `systemctl disable --now pm2-peperoncini-staging; rm /etc/systemd/system/pm2-peperoncini-staging.service`,
   `userdel peperoncini-staging`, `chown -R peperoncini:peperoncini /var/www/pizzeria-peperoncini.ch/staging`.

## Left for the owner (blocked for the agent)

- ~~`certbot delete --cert-name monitoring.pizzeria-peperoncini.ch`~~ done by the owner 2026-09-29 (expired 2025-09, made `certbot.service` fail every run)
- ~~Purge `alloy`~~ done by the owner 2026-09-29 (deb 1.10.2, failed since 2026-09-09)
- ~~journald cap~~ done by the owner 2026-09-29: `/etc/systemd/journald.conf.d/size.conf` `SystemMaxUse=500M`, journald restarted, 1.7 GB → 489.6 MB
- ~~DNS: delete `demo.kuuak.ch` and `next.pizzeriatomate.ch`~~ done by the owner 2026-09-29

## Out-of-band changes (not on the box)

| Date | Change | By |
|---|---|---|
| 2026-09-29 | Infomaniak portal firewall: TCP 1025 (Mailpit SMTP) restricted to IPv4 of IncServer and KuuakServer. IPv6 1025 verified closed | owner |
| 2026-09-29 | DNS `pizzeria-peperoncini.ch` AAAA: stale DigitalOcean `2a03:b0c0:3:f0::3a30:9000` replaced by IncServer `2001:1600:18:100::68`. Web on v6 not served yet (nginx + portal pending) | owner |
