# PW Backup

PW Backup is a minimal installer for scheduled Restic backups on Debian systems. It uses Restic from the official Debian repositories and native systemd services and timers.

PW Backup is independent and is not affiliated with Restic or Debian.

## Scope

- Debian with systemd
- one backup job per machine with multiple source paths
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
```

The installer preserves existing configuration and secrets under `/etc/pw-backup` and never enables either timer automatically.

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

## Uninstallation

Conservative uninstall removes the program, all four units, their drop-ins, enablement links, cache, and state. It preserves `/etc/pw-backup` and does not remove Restic or remote repositories:

```bash
pw-backup-uninstall
```

Complete purge also deletes `/etc/pw-backup`, including configuration and secrets:

```bash
pw-backup-uninstall --purge
```

## Tests

GitHub Actions runs on Debian 13 and verifies shell syntax, ShellCheck, installation, permissions, all systemd units, independent backup and maintenance behavior, dry-run safety, retention, prune, check, restore, uninstall, and purge.

## License

MIT
