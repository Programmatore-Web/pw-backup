# PW Backup

PW Backup is a minimal installer for scheduled Restic backups on Debian systems. It uses Restic from the official Debian repositories and native systemd services and timers.

PW Backup is independent and is not affiliated with Restic or Debian.

## Scope

- Debian with systemd
- an optional legacy backup job and independent named groups, each with multiple source paths
- any repository supported by Restic
- logs through the systemd journal
- no implicit repository initialization
- optional retention and prune, disabled by default
- backup and repository maintenance scheduled independently
- no source deletion

## Installation

Run as `root` from a checked-out release:

```bash
./install.sh
```

Installed units:

```text
pw-backup.service
pw-backup.timer
pw-backup-maintenance.service
pw-backup-maintenance.timer
pw-backup@.service
pw-backup@.timer
```

The installer preserves existing configuration and secrets under `/etc/pw-backup` and never enables or starts timers automatically.

## Configuration

Edit `/etc/pw-backup/config.env`, `/etc/pw-backup/paths`, and optionally `/etc/pw-backup/excludes`. Store the repository password in `/etc/pw-backup/repository-password`.

A new repository must be initialized explicitly:

```bash
pw-backup restic init
```

Validate and test the backup before enabling its timer:

```bash
pw-backup check-config
systemctl start pw-backup.service
journalctl -u pw-backup.service
systemctl enable --now pw-backup.timer
```

## Backup groups

Groups reuse `PW_BACKUP_CONFIG_DIR` (default `/etc/pw-backup`) as their configuration root:

```text
/etc/pw-backup/
    config.env
    paths
    groups/
        documents/
            config.env
            paths
            excludes    # optional
```

Group names contain 1–64 lowercase ASCII letters, digits, `_` or `-`, starting with a letter or digit. Each group has its own root-owned `config.env`, not writable by group or others. It does not load legacy settings, another group's settings, or legacy file overrides. `RESTIC_REPOSITORY` and a non-empty `PW_BACKUP_HOST` must be configured in each group. The tag is always `pw-backup-group-<name>`; setting `PW_BACKUP_TAG` in a group is an error.

Start with the fictitious files in `examples/groups/documents`. For example, as root:

```bash
install -d -m 0700 /etc/pw-backup/groups/documents
install -m 0600 examples/groups/documents/config.env /etc/pw-backup/groups/documents/config.env
install -m 0600 examples/groups/documents/paths /etc/pw-backup/groups/documents/paths
```

Edit the repository, host and source paths before use. Credentials are never copied. Set `RESTIC_PASSWORD_FILE` explicitly to share a password file; otherwise it defaults to the group's own `repository-password` file. The default cache is `/var/cache/pw-backup/groups/<name>`. Other optional settings have the same defaults as legacy configuration.

```bash
pw-backup check-config --group documents
pw-backup restic --group documents init  # only for a new repository
pw-backup run --group documents
```

Group backups select parents using `--group-by host,paths,tags`. Groups with identical hosts and source paths therefore keep separate snapshot histories and independently skip unchanged content. Existing snapshots are not retagged or modified.

## Retention and prune

Retention is configured independently on each machine. Empty keep values are ignored, so policies can use any combination of last, hourly, daily, weekly, monthly, and yearly snapshots:

```text
PW_BACKUP_RETENTION_ENABLED=true
PW_BACKUP_KEEP_LAST=
PW_BACKUP_KEEP_HOURLY=
PW_BACKUP_KEEP_DAILY=7
PW_BACKUP_KEEP_WEEKLY=4
PW_BACKUP_KEEP_MONTHLY=12
PW_BACKUP_KEEP_YEARLY=5
PW_BACKUP_PRUNE=true
```

Preview without changing the repository:

```bash
pw-backup maintenance --dry-run
```

Apply manually:

```bash
pw-backup maintenance
```

`pw-backup run` creates backups only. The separate maintenance command performs `restic forget`, grouped by host, paths, and tags. When `PW_BACKUP_PRUNE=true`, it also reclaims repository data no longer referenced by retained snapshots.

Changing a machine's policy only requires editing `/etc/pw-backup/config.env`, validating it, and previewing it again. Increasing a policy later cannot recreate snapshots that were already removed.

With groups present, the same `maintenance` command validates **all** group configurations before any forget operation, then applies each enabled policy. Group retention always filters by its explicit host and generated tag and groups snapshots by `host,paths,tags`. Each configuration is loaded in a separate process. Disabled legacy retention does not prevent group maintenance; its repository and password may remain unconfigured. Keep the legacy `config.env` present and set `PW_BACKUP_RETENTION_ENABLED=false` when only groups are used.

Without groups, legacy behavior is unchanged: an empty `PW_BACKUP_HOST` omits the host filter, so retention can affect all hosts selected by the legacy tag, with a separate policy per host/paths/tags combination. **With groups present**, enabled legacy retention requires a non-empty host and a single, non-group tag. Ambiguous legacy policies fail before any snapshot is removed. The `pw-backup-group-*` tag namespace is reserved for groups.

For shared repositories, designate one maintenance configuration with `PW_BACKUP_PRUNE=true` and enabled retention. All other configurations using that repository must set it false. With groups, all forget policies complete before the designated owner's `restic prune`; dry-run also previews prune without deleting data. Multiple local configurations declaring prune for the **same exact `RESTIC_REPOSITORY` string** are rejected, including disabled configurations. Different strings or backend aliases may refer to the same repository and cannot be detected; configure the same repository string consistently and designate a single prune owner across machines as well. There is no repository registry or custom distributed lock.

## Scheduling

The default backup timer runs daily at 03:00 with up to 30 minutes of randomized delay. The default maintenance timer runs weekly on Sunday at 05:30 with up to 30 minutes of randomized delay. Both use `Persistent=true` and can be customized independently with systemd drop-ins:

```bash
systemctl edit pw-backup.timer
systemctl edit pw-backup-maintenance.timer
```

Enable the maintenance timer only after a successful dry-run and manual maintenance test:

```bash
systemctl enable --now pw-backup-maintenance.timer
```

Each group uses only its own backup instance. Set independent calendars with drop-ins:

```bash
systemctl edit pw-backup@documents.timer
```

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 02:00:00
```

```bash
systemctl daemon-reload
systemctl start pw-backup@documents.service
systemctl enable --now pw-backup@documents.timer
```

The group template defaults to the legacy daily calendar; each instance can override it independently. There are no maintenance templates: the existing `pw-backup-maintenance.timer` schedules maintenance for legacy and groups together. All four legacy units remain available.

## Local coordination

Legacy and group backups, maintenance and the `restic` passthrough all take one exclusive `flock` on `/run/pw-backup/operation.lock`. Debian's existing `flock` from util-linux is used. The root-owned runtime directory has mode `0700`; the fixed wait timeout is 300 seconds. Timeout is a failed operation with an explicit error. Lock messages go to stderr so passthrough JSON remains usable.

The descriptor is inherited by Restic and released when the operation and its children exit, including errors and termination. Maintenance keeps it held across all policies and prune without reacquiring it. Do not delete the lock file while operations may be running; it is intentionally left in place until reboot. Restic's native repository locks still coordinate different machines. Invoking Restic outside `pw-backup` bypasses this local coordination, and the passthrough remains an administrator interface to native Restic commands.

## Uninstallation

Conservative uninstall stops and disables group instances and removes the program, legacy units, templates, instance files, drop-ins, enablement links, cache, and state. It preserves `/etc/pw-backup`, including all group configurations, and does not remove Restic or remote repositories:

```bash
pw-backup-uninstall
```

Complete purge also deletes `/etc/pw-backup`, including configuration and secrets:

```bash
pw-backup-uninstall --purge
```

## Tests

GitHub Actions runs the existing suite on Debian 13, including real Restic snapshots, parent isolation with identical paths, skip-if-unchanged, filtered retention, shared prune, restore, concurrent operations, lock timeout/error/termination handling, and conservative uninstall/purge. It verifies installed systemd units and uses a `systemctl` fixture rather than starting services. The timeout test shortens only its real contended flock wait after checking that production requested 300 seconds.

Run the complete suite only as root in a disposable Debian container: the tests install and remove `/etc/pw-backup`, program files and units.

```bash
sudo ./tests/run.sh
sudo ./tests/uninstall.sh
```

Legacy commands, configuration paths and version identifiers remain unchanged in this development phase. Group selection is optional; no groups are created or enabled automatically.

## License

MIT
