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
pw-backup-recover.service
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

## Group hooks and recovery

Hooks are optional and available only for groups:

```sh
PW_BACKUP_PRE_HOOK=/usr/local/libexec/example-pre
PW_BACKUP_POST_HOOK=/usr/local/libexec/example-post
```

Both values are absolute paths to regular executable scripts, invoked directly without shell evaluation. Scripts and all path components must be root-owned and protected against replacement: no symlinks, group/other write permissions, or `.`/`..` path segments. Root-owned sticky directories such as `/tmp` are allowed because their root-owned children cannot be replaced by other users. Configuration paths for hook-enabled groups must meet the same security checks. Leave both settings empty to retain the existing `exec restic` path without recovery records. POST alone is allowed; PRE always requires an idempotent POST.

Scripts run synchronously with a clean environment and this single environment-variable contract:

| Variable | Values |
| --- | --- |
| `PW_BACKUP_CONFIG_DIR` | Canonical configuration root for this group |
| `PW_BACKUP_GROUP` | Group name |
| `PW_BACKUP_HOOK_PHASE` | `pre` or `post` |
| `PW_BACKUP_HOOK_MODE` | `normal` or `recovery` |
| `PW_BACKUP_BACKUP_STATUS` | `not-run`, `success`, `failed`, `interrupted`, or `unknown` |

PATH is `/usr/sbin:/usr/bin:/sbin:/bin`; scripts must obtain any other context from their own secure files. Each hook has a fixed 300-second timeout, followed by forced termination after a 10-second grace period. Scripts must remain synchronous, avoid detached/background work, and return success only after verifying their work. They must not recursively invoke `pw-backup` while its lock is held.

Before PRE (or backup for a POST-only group), the runner durably publishes a small pending record under `/var/lib/pw-backup/pending`. It contains only a format version, configuration root, group, POST path, POST checksum and group configuration checksum. Directories are root-only `0700`, records `0600`. The record is not shell code. A reserved state directory and an atomic record rename with filesystem synchronization prevent overwrite or silent loss after interruption; an incomplete record is preserved and fails safely.

The same local lock covers PRE, Restic, POST and recovery. Failed PRE prevents Restic and still attempts POST, including partial PRE failures. Failed/incomplete Restic backups still run POST; Restic exit code 3 remains an error. On catchable signals, the runner terminates and waits for the active process group before attempting cleanup. POST failure is logged as `CRITICAL`, returns failure and preserves the record. A successful POST removes the record durably. Original PRE/Restic exit codes, including 3, are preserved; POST failure after successful backup returns 1. Catchable HUP/INT/TERM use 129/130/143. Hook timeouts normally return 124; failed recovery returns nonzero.

POST must be safe to repeat, even if PRE never completed or a previous POST already completed immediately before a crash. It owns the knowledge of the initial external state: it must not assume an external service should always be started. No application-specific state is inferred by PW Backup.

```bash
pw-backup recover                    # all pending roots and groups
pw-backup recover --group documents  # this group in PW_BACKUP_CONFIG_DIR
```

Recovery validates the stored record, current configuration bytes and exact authorized POST bytes before executing POST in recovery mode, with backup status `unknown`. It never starts a backup. Changed/missing configurations or scripts and damaged records cause a `CRITICAL` failure and are preserved. Restore the reviewed original files before retrying; do not edit or delete a pending record to bypass the check. A blocked group cannot start another backup, while independent groups can continue. Completed recovery is a no-op on subsequent calls. Configuration roots are distinguished, so a custom root remains recoverable even when boot recovery uses the default environment.

The group service uses `ExecStopPost` for cleanup after abnormal service exit; the same unit environment, including an alternate configuration root, is retained. The separate boot unit is installed **disabled**. Before enabling groups whose PRE changes external availability, explicitly enable recovery:

```bash
systemctl enable pw-backup-recover.service
systemctl start pw-backup-recover.service
```

Recovery runs after local filesystems and network availability; group services are ordered after it. Add application-specific ordering through local drop-ins. The group stop timeout allows the bounded cleanup and lock wait. No recovery timer or resident monitor is used.

SIGKILL and sudden power loss cannot run traps. Pending records survive; systemd's service cleanup, a fresh group run, explicit `recover`, or enabled boot recovery can replay POST. Killing only a manually launched runner may leave its child alive and holding the lock: recovery waits rather than overlapping it. Wait for or terminate that child before retrying. Restarting a runner in the tests simulates boot replay; it is not a real reboot or proof of systemd as PID 1.

Hooks never run during `maintenance`, dry-run, `check-config` or Restic passthrough. These commands keep their existing purpose; `check-config` also validates hook paths. Uninstall, including `--purge`, refuses while **any** pending state exists, keeping the runner, configuration and recovery units available.

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

GitHub Actions runs the existing suite on Debian 13, including real Restic snapshots, parent isolation with identical paths, skip-if-unchanged, filtered retention, shared prune, restore, concurrent operations, hooks, durable cleanup/recovery, lock timeout/error/termination handling, and conservative uninstall/purge. It verifies installed systemd units and `ExecStopPost`, and uses a `systemctl` fixture rather than starting services. Timeout tests shorten only real test waits after checking production limits. PRE/POST scripts in tests only manipulate fictitious temporary files. Signal and crash tests exercise real runner processes; boot replay is simulated by starting a fresh runner. No test claims to run systemd as PID 1.

Run the complete suite only as root in a disposable Debian container: the tests install and remove `/etc/pw-backup`, program files and units.

```bash
sudo ./tests/run.sh
sudo ./tests/uninstall.sh
```

Legacy commands, configuration paths and version identifiers remain unchanged in this development phase. Group selection is optional; no groups are created or enabled automatically.

## License

MIT
