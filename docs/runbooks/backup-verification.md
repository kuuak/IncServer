# Backup verification: monthly data check and restore drill (kuuak/IncServer#15, Audit M5)

Three layers, each catching what the one before cannot:

| Layer | When | What it proves | Where |
|---|---|---|---|
| `restic check` (structure) | nightly, end of `restic-backup.sh` (00:00) | index, snapshots and trees are consistent; no data is downloaded | role `backup`, unchanged |
| `restic check --read-data-subset=<month>/12` | 1st of the month, 02:30 (`restic-check-data.timer`) | the pack files of that twelfth download and match their hashes; the twelfth is the month's number, so every pack kept a year is read once a year | role `backup`, pinged by role `healthchecks` (key `restic-check-data`) |
| Restore drill | by hand (owner), see below | the latest production dump comes back out of restic byte for byte and loads into PostgreSQL with the same row counts as live | [`restic-restore-drill.sh`](restic-restore-drill.sh) |

The monthly check reads about 1/12 of the repository from Swiss Backup (the whole nightly job, dumps to `check`,
takes under a minute, so a run should take minutes). It runs as root with `/etc/restic/env` like the nightly
backup, `Nice=10`, and is stopped after 90 min so that it fails (and pings `fail`) well before the Tuesday 04:30
reboot window. `--retry-lock 30m` waits out a nightly run that started late. Its schedule avoids 00:00 (backup,
logrotate), 04:30 Tuesday (reboot) and the opening hours.

## Vault values (the owner)

`--check --tags backup` skips `Restic credentials` and `Rclone remote` until these are in
`group_vars/all/vault.yml` (`ansible-vault edit group_vars/all/vault.yml`). Set the five backup values together:
`Restic credentials` runs as soon as `vault_restic_password` is set and templates the repository too.

| Variable | Value | Read from |
|---|---|---|
| `vault_restic_repository` | exactly `RESTIC_REPOSITORY` | `/etc/restic/env` on the box |
| `vault_restic_password` | exactly `RESTIC_PASSWORD` (rotated 2026-09-29) | password manager (= `/etc/restic/env`) |
| `vault_swissbackup_user` | `user` of `[KuuakIncServerBackup]` | `/root/.config/rclone/rclone.conf` |
| `vault_swissbackup_password` | `key` of `[KuuakIncServerBackup]` | same file |
| `vault_swissbackup_tenant` | `tenant` of `[KuuakIncServerBackup]` | same file |
| `vault_healthcheck_restic_check_data_url` | ping URL of a new healthchecks.io check `restic-check-data`: cron `30 2 1 * *`, time zone Europe/Zurich, grace 2 h, email integration | healthchecks.io |

The two templates (`roles/backup/templates/env.j2`, `rclone.conf.j2`) were written without reading the files on the
box. The `--check` below must show both tasks `ok`. `no_log` hides their diff, so if one says `changed`, compare
the shapes on the box (names and non-secret values only) with the template and fix the template, not the box:

```sh
ssh IncServer 'sudo sed "s/=.*/=…/" /etc/restic/env; sudo tail -c1 /etc/restic/env | od -c | head -1'
ssh IncServer 'sudo sed -E "/^(\[|(type|auth|domain|tenant_domain|region|storage_url|auth_version) =)/! s/=.*/= …/" /root/.config/rclone/rclone.conf; sudo tail -c1 /root/.config/rclone/rclone.conf | od -c | head -1'
```

Both mask every value but the ones the template hard-codes; the last line of each shows whether the file ends with a
newline (`\n`), as the rendered template does.

The shapes cannot show a value that differs. Compare each value by hash instead (first 8 characters: a whole sha1 can
be masked as key material on its way back), the box's as systemd parses `EnvironmentFile=`, the vault's as Ansible
holds it; both print hashes only:

```sh
ssh IncServer 'sudo systemd-run --quiet --pipe --wait --collect -p EnvironmentFile=/etc/restic/env sh -c "printf %s \"\$RESTIC_REPOSITORY\" | sha1sum | cut -c1-8"'
ssh IncServer 'sudo systemd-run --quiet --pipe --wait --collect -p EnvironmentFile=/etc/restic/env sh -c "printf %s \"\$RESTIC_PASSWORD\" | sha1sum | cut -c1-8"'
ansible incserver -m ansible.builtin.debug -a "msg={{ {'RESTIC_REPOSITORY': (vault_restic_repository | hash('sha1'))[:8], 'RESTIC_PASSWORD': (vault_restic_password | hash('sha1'))[:8]} }}"
ssh IncServer 'sudo sh -c "grep -E \"^(user|key|tenant) = \" /root/.config/rclone/rclone.conf | while IFS= read -r l; do printf \"%s \" \"\${l%% = *}\"; printf %s \"\${l#* = }\" | sha1sum | cut -c1-8; done"'
ansible incserver -m ansible.builtin.debug -a "msg={{ {'user': (vault_swissbackup_user | hash('sha1'))[:8], 'key': (vault_swissbackup_password | hash('sha1'))[:8], 'tenant': (vault_swissbackup_tenant | hash('sha1'))[:8]} }}"
```

Filled 2026-10-25: every value matched (after one typo fixed in the vault), and both tasks still said `changed` for
two differences nothing reads: the box's `RESTIC_REPOSITORY="…"` was quoted (systemd drops the quotes; the template
writes none, and `vault_restic_password` has no character that would need them), and its `rclone.conf` began with an
empty line (rclone ignores it). The apply of 2026-10-25 rewrote both files without them; `--check --diff --tags
backup,healthchecks` on 2026-10-26: `changed=0`, both tasks `ok`.

## Apply and first monthly check (the owner)

Any time except around 00:00; nothing is restarted (one `daemon-reload`).

```sh
ansible-playbook site.yml --check --diff --tags backup,healthchecks < /dev/null > check.log 2>&1
```

Expected, with the vault filled: `Restic credentials` and `Rclone remote` **ok**; `Data check script` and `Units`
(`restic-check-data.service`, `restic-check-data.timer`) changed; `Enable timers` fails for `restic-check-data.timer`
and is ignored (the unit is not on the box during a dry run, as on the first run of the nightly one);
`healthchecks`: `Ping URLs`, `Drop-in directories` and `Drop-ins` changed for `restic-check-data` only; the release
marker. Every other task `ok`.

```sh
ansible-playbook site.yml --tags backup,healthchecks < /dev/null > apply.log 2>&1
ssh IncServer 'systemctl list-timers restic-check-data.timer --no-pager'      # next: the 1st, 02:30
ssh IncServer 'sudo systemctl start restic-check-data.service'                 # once by hand; returns when done
ssh IncServer 'systemctl show restic-check-data.service -p Result -p ExecMainStartTimestamp -p ExecMainExitTimestamp; journalctl -u restic-check-data -n 20 --no-pager'
```

Expect `Result=success`, `no errors were found` in the journal, and a start + success ping on the healthchecks.io
check `restic-check-data`. A run by hand in October reads subset 10/12, the timer on 1 November reads 11/12.

## Restore drill (the owner)

Run it while the pizzeria is closed, staging first, then production. It restores the dump of the given database
from the latest snapshot into `restore_drill_<db>` (CONNECT revoked from PUBLIC), compares row counts per table with
the live database, drops the scratch database and prints counts only, never rows. Details in the script's header.

```sh
scp docs/runbooks/restic-restore-drill.sh IncServer:
ssh IncServer 'sudo bash ~/restic-restore-drill.sh peperoncini-staging'
ssh IncServer 'sudo bash ~/restic-restore-drill.sh'                    # production: pizzeriapeperoncini
ssh IncServer 'rm ~/restic-restore-drill.sh'
```

Reading the result:

- `sha256 … identical`: the dump restic returned is byte for byte the one still on disk from the same night.
  `differs` is expected only when a nightly run came after the snapshot it used.
- `RESULT: PASS` (exit 0): same tables, every count equal to live. `RESULT: COUNTS DIFFER` (exit 1): the restore
  worked, but rows were written after the snapshot (orders, sessions, the 03:15 token purge). Run it again after the
  next nightly backup (done about 00:01) and before 03:15: from 03:15 on, `purge-expired-tokens` (production and
  staging) deletes the tokens that expired since the snapshot, so a run in the morning can still differ. The drill is
  passed when the counts match.
- `RESULT: FAILED at step: …` (exit 1): restic or the load failed (psql errors show as SQLSTATE codes only). The
  scratch database and the temp dir are cleaned up anyway.
- `REFUSE: …` (or `usage:` / `run as root`) and no `RESULT` line (exit 2): the drill did not start, nothing to
  record. It refuses while the nightly backup (00:00, about a minute) or the monthly data check (the 1st, 02:30, up to
  90 min) is running, since both hold the restic lock: run it again once they are done. Also for an unknown database,
  without root, and when a `restore_drill_…` database already exists, which means a run was killed before its
  cleanup.

Repeat it after a restic or PostgreSQL upgrade, and at least once a year.

## Drill log

Paste the `RESULT:` line.

| Date | Database | RESULT line | By |
|---|---|---|---|
| 2026-10-25 22:16 | `peperoncini-staging` | `RESULT: PASS 2026-10-25 peperoncini-staging from snapshot 80d900f4 (2026-10-25_00:00:03): tables: 26, equal: 26, count differs: 0, only on one side: 0; dump vs disk: identical` | owner |
| 2026-10-25 22:17 | `pizzeriapeperoncini` | `RESULT: COUNTS DIFFER 2026-10-25 pizzeriapeperoncini from snapshot 80d900f4 (2026-10-25_00:00:03): tables: 26, equal: 12, count differs: 14, only on one side: 0; dump vs disk: identical` (all 14 live > restored: that evening's 21 orders and their rows; re-run below) | owner |
| 2026-10-26 00:08 | `pizzeriapeperoncini` | `RESULT: PASS 2026-10-26 pizzeriapeperoncini from snapshot 7c70fc5e (2026-10-26_00:00:03): tables: 26, equal: 26, count differs: 0, only on one side: 0; dump vs disk: identical` | owner |

## Monthly check log

| Date | How | Result |
|---|---|---|
| 2026-10-25 22:14 | by hand after the apply (subset 10/12) | `Result=success`, `no errors were found`: group 10 = 13 of 142 packs, 53 snapshots, 5 s; start + success ping on healthchecks.io |
| 2026-11-01 | timer (subset 11/12) | |
