# 2026-10: one Redis ACL user per Environment (#16)

Audit M1: Redis was the last store production and staging shared. It listened on loopback only, but with no password
and no ACL users, so both Environments (and any local process) connected as the `default` user and could read or
write every key, including the other Environment's SSE bookkeeping and broadcast channel.

| | Before | After |
|---|---|---|
| `/etc/redis/redis.conf` | stock (`# aclfile /etc/redis/users.acl`) | stock but `aclfile /etc/redis/users.acl` |
| `/etc/redis/users.acl` | – | from `roles/tenant/templates/redis-users.acl.j2`, `root:redis 0640`, SHA-256 hashes only |
| `default` user | on, no password, every key and command | off (`redis_default_user_enabled: false`, step 7) |
| Environments | as `default` | `peperoncini` (`~peperoncini-production:*`, `&peperoncini-production:*`), `peperoncini-staging` (`~staging-peperoncini:*`, `&staging-peperoncini:*`), each only `redis_app_commands` |
| Local admin | `redis-cli` | `redis-cli --user admin --askpass` (every key and command) |
| Netdata's Redis collector | discovered job `local`, as `default` | same job name from `/etc/netdata/go.d/redis.conf`, as `netdata` (`PING`, `INFO`, `CONFIG GET`) |

## How the app gets its Redis URL

delivery-order-app reads `REDIS_URL` and `REDIS_NAMESPACE` from `process.env` (`src/core/services/redisService.ts`),
filled by Blitz's env loader at `blitz start` (`NODE_ENV=production`): `.env.production.local`, then `.env.production`,
`.env.local`, then the checked-in `.env` (placeholder `redis://localhost:6379`); the first file to define a key wins,
and a variable already in the process environment wins over all of them. `scripts/deploy-server.sh` copies every
`.env.*` of `current/` into each new release, so a change made there survives deploys; `.env.local` is created from
`.env.production.local` only when missing. No app change is needed. Keys and the SSE channel are
`<REDIS_NAMESPACE>:…`; the client connects lazily, on the first SSE stream (`/api/orders/stream`, the admin screens),
as two connections (commands, and the broadcast subscriber). It sends `AUTH <user> <password>` from the URL, so the
URL must be `redis://<user>:<password>@<host>:6379` with no `/<db>` (that would send a `SELECT`, not granted).

Commands granted (`redis_app_commands`), from `redisService.ts`: `SETEX` `SADD` `SREM` `DEL` `SMEMBERS` `SCARD`
`EXISTS` `PUBLISH` `SUBSCRIBE` on main, plus `GET` for production's v1.4.1. That matches the box's `INFO commandstats`
over the 4 days before 2026-10-19 (Netdata's `INFO`, `PING`, `HELLO`, `CONFIG GET` aside). node-redis 5.8.2 also
sends `CLIENT SETINFO`, which Redis 7.0 does not know; the client ignores that error.

What a Redis or ACL change does to the apps: `systemctl restart redis-server` closes every connection, and `ACL LOAD`
(the `Reload Redis ACLs` handler, on any change to `users.acl`) every connection of a non-default user (checked on
7.0.15). node-redis reconnects and
re-subscribes by itself within a second; meanwhile an order event is delivered by the instance that saw it
(delivery-order-app #624), and each closed connection logs one `Redis Client Error` / `Redis Subscriber Error`
(`Socket closed unexpectedly`) to the PM2 error log. So: Redis restarts and ACL changes while the pizzerias are
closed (Mon, Wed–Sun 18:00–22:00 open).

## Rollout (owner)

Staging first; production only while the pizzeria is closed. Every step lists its checks; stop at the first FAIL.
A Tuesday 04:30 reboot between steps is harmless: Redis starts from the validated `users.acl`, and while the default
user is on, an app not switched yet still gets in.
`H=/var/www/pizzeria-peperoncini.ch`. Copy the helper once: `scp docs/runbooks/2026-10-redis-acl.sh IncServer:/tmp/`
(`test`, `env`, `clients`, `mark`, `errors`; it asks for passwords and never prints them or a log line).

### 0. Vault (any time)

Make four passwords in the password manager, hex only (`openssl rand -hex 32`): they go into URLs. Then
`ansible-vault edit group_vars/all/vault.yml` and add (names in `vault.yml.example`):

```yaml
vault_tenant_redis_passwords:
  peperoncini: "<hex>"
  peperoncini-staging: "<hex>"
vault_redis_admin_password: "<hex>"
vault_redis_netdata_password: "<hex>"
```

### 1. Dry run (any time)

```sh
ansible-playbook site.yml --check --diff --tags tenant,netdata < /dev/null > check-16.log 2>&1
```

Expect `changed=6`: `/etc/redis/users.acl` (new, 5 lines: `default` still on as today, `admin`, `netdata`,
`peperoncini`, `peperoncini-staging`), the one `aclfile` line in `redis.conf`, the notice "Redis needs a restart by
hand", `/etc/netdata/go.d/redis.conf` (diff hidden: it holds Netdata's password) and its `Restart netdata` handler,
and motd's apply marker. Nothing else. (Run from this branch on 2026-10-19 with throwaway passwords: exactly that.)

### 2. Apply and restart Redis (pizzerias closed)

```sh
ssh IncServer 'sudo bash /tmp/2026-10-redis-acl.sh mark'
ansible-playbook site.yml --tags tenant < /dev/null > apply-16-tenant.log 2>&1      # writes users.acl + the conf line
ssh IncServer 'sudo systemctl restart redis-server && systemctl is-active redis-server && redis-cli CONFIG GET aclfile'
```

Expect `active` and `aclfile` / `/etc/redis/users.acl`. The apps reconnect as `default` (still on, no password).
`ssh -t IncServer bash /tmp/2026-10-redis-acl.sh clients` (admin password): `user=default` for the apps' and
Netdata's connections, `user=admin` (itself), ACL LOG empty. `ssh IncServer 'sudo bash /tmp/2026-10-redis-acl.sh
errors'`: at most 2 Redis lines per Environment whose app had connected (the restart), and none after that.

If Redis does not come back: `sudo sed -i 's|^aclfile /etc/redis/users.acl|# aclfile /etc/redis/users.acl|'
/etc/redis/redis.conf && sudo systemctl restart redis-server` (stock again), then read
`/var/log/redis/redis-server.log`. The role validated the file in a throwaway Redis before writing it, so this
should not happen.

### 3. Netdata as its own user (any time after 2)

```sh
ansible-playbook site.yml --tags netdata < /dev/null > apply-16-netdata.log 2>&1   # the collector config + restart netdata
```

`clients` again after a minute: `user=netdata resp=3` (Netdata speaks RESP3; the apps RESP2), no `user=default
resp=3` left, ACL LOG empty.

### 4. The NOPERM test (any time after 2)

```sh
ssh -t IncServer bash /tmp/2026-10-redis-acl.sh test peperoncini-staging staging-peperoncini peperoncini-production
ssh -t IncServer bash /tmp/2026-10-redis-acl.sh test peperoncini peperoncini-production staging-peperoncini
```

Each must end `All checks passed.`: as the staging user, `SETEX`/`DEL` on a `peperoncini-production:` key,
`GET`/`SMEMBERS`/`SCARD`/`EXISTS` on production's SSE keys, `PUBLISH`/`SUBSCRIBE` on its channels fail with `NOPERM`,
and so do `SET`, `SCAN`, `KEYS`, `CONFIG GET`, `SELECT`; its own `SETEX`/`GET`/`SCARD`/`PUBLISH`/`DEL` work. The same
the other way round. Tested 2026-10-19 against Ubuntu 24.04's Redis 7.0.15 with this branch's file: all pass; on stock
Redis (as `default`, i.e. today) every cross-Environment and extra-command check fails. Then clear the log of these
intended denials: `ssh -t IncServer redis-cli --user admin --askpass ACL LOG RESET`.

### 5. Staging switch (any time)

```sh
ssh IncServer 'sudo bash /tmp/2026-10-redis-acl.sh mark'
ssh -t IncServer sudo -iu peperoncini-staging bash /tmp/2026-10-redis-acl.sh env peperoncini-staging
ssh IncServer 'sudo systemctl restart pm2-peperoncini-staging'
```

`env` (staging's Redis password): checks the login first and changes nothing if Redis refuses it; then edits each
of `$H/staging/current/.env.production.local`, `.env.production`, `.env.local` that defines `REDIS_URL` (or adds it
to `.env.production.local`), and must end `All checks passed.`, showing
`redis://peperoncini-staging:***@<host>:6379` and `REDIS_NAMESPACE: staging-peperoncini`, and no `REDIS_URL` in the
PM2 dump or `ecosystem.config.js`.

Then use staging: open the admin orders screen (SSE) at https://staging.pizzeria-peperoncini.ch and place a test
order on the storefront; it must show up live. Checks:

- `clients`: two `user=peperoncini-staging` connections (commands + subscriber; there only once an SSE stream is open),
  ACL LOG empty (a NOPERM there = a command missing from `redis_app_commands`).
- `errors`: staging's error log, `0 of them mention Redis` (and no new error lines beyond what staging logs anyway).

Rollback (works while the default user is on): as `peperoncini-staging`, take the user and password out of each
file `env` edited (`perl -i -pe 's{^((?:export\s+)?REDIS_URL=["\x27]?redis://)[^@/]*@}{$1}' <file>`), then restart
`pm2-peperoncini-staging`.

### 6. Production switch (pizzeria closed)

```sh
ssh IncServer 'sudo bash /tmp/2026-10-redis-acl.sh mark'
ssh -t IncServer sudo -iu peperoncini bash /tmp/2026-10-redis-acl.sh env peperoncini
ssh IncServer 'sudo systemctl restart pm2-peperoncini'
```

`env` must end `All checks passed.`, with `redis://peperoncini:***@<host>:6379` and
`REDIS_NAMESPACE: peperoncini-production`. Allow ~60 s of cold start, then https://www.pizzeria-peperoncini.ch 200.
Open the admin orders screen (SSE), then: `clients` shows two `user=peperoncini`, ACL LOG empty; `errors` shows
production's error log with `0 of them mention Redis`. After the next opening evening (orders, SSE to the tablets,
the App jobs every 10 min): `errors` again, still 0 Redis lines, and orders came in as usual. Rollback as in 5.

### 7. Default user off (pizzerias closed)

Only when `clients` shows no `user=default` connection at all. Set `redis_default_user_enabled: false` in
`group_vars/all/vars.yml` (PR), then:

```sh
ssh IncServer 'sudo bash /tmp/2026-10-redis-acl.sh mark'
ansible-playbook site.yml --check --diff --tags tenant < /dev/null > check-16-off.log 2>&1   # only users.acl's first line
ansible-playbook site.yml --tags tenant < /dev/null > apply-16-off.log 2>&1                  # + Reload Redis ACLs: changed
ssh IncServer 'redis-cli PING'                                                                # NOAUTH Authentication required.
```

The check's only change is `user default on nopass ~* &* +@all` → `user default off resetkeys resetchannels -@all`
(+ the handler, + motd's marker); the role refuses it while a vault password is missing. After the apply: `clients`
shows `peperoncini` and `peperoncini-staging` back (×2 each once an SSE stream is open) and `netdata`, no `default`,
ACL LOG empty; `errors`: at most 2 Redis lines per Environment (the reload's reconnect), then none. Run step 4's two
tests once more (then `ACL LOG RESET`). Rollback: `redis_default_user_enabled: true`, apply `--tags tenant`; in a
hurry, on the box: `redis-cli --user admin --askpass ACL SETUSER default on nopass '~*' '&*' +@all` (until the next
apply).

Then close the row in `2026-09-cleanup.md`.
