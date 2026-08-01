# PW Backup

PW Backup is a minimal installer for scheduled Restic backups on Debian systems. It uses Restic from the official Debian repositories and native systemd services and timers.

PW Backup is independent and is not affiliated with Restic or Debian.

## Scope

- Debian with systemd
- one scheduled backup job per machine
- multiple source paths
- any repository supported by Restic
- logs through the systemd journal
- no implicit repository initialization
- optional retention and prune, disabled by default
- no source deletion

## Installation

Run as `root` from a checked-out release:

```bash
./install.sh
```

Installed files:

```text
/usr/local/sbin/pw-backup
/usr/local/sbin/pw-backup-uninstall
/etc/pw-backup/
/etc/systemd/system/pw-backup.service
/etc/systemd/system/pw-backup.timer
/var/cache/pw-backup/
/var/lib/pw-backup/
```

The installer preserves existing configuration and secrets under `/etc/pw-backup` and never enables the timer automatically.

## Configuration

Edit `/etc/pw-backup/config.env`, `/etc/pw-backup/paths`, and optionally `/etc/pw-backup/excludes`. Store the Restic repository password in `/etc/pw-backup/repository-password`.

Generic repository examples:

```text
RESTIC_REPOSITORY=/mnt/backup/restic
RESTIC_REPOSITORY=sftp:backup@backup.example.net:/repositories/server01
RESTIC_REPOSITORY=rest:https://backup.example.net/server01
RESTIC_REPOSITORY=s3:https://objects.example.net/example-bucket/server01
```

Validate and test before enabling the timer:

```bash
pw-backup check-config
pw-backup restic snapshots
systemctl start pw-backup.service
journalctl -u pw-backup.service
systemctl enable --now pw-backup.timer
```

A new repository must be initialized explicitly:

```bash
pw-backup restic init
```

## Retention and prune

Retention is disabled by default. Enable it in `/etc/pw-backup/config.env` and set at least one keep value:

```text
PW_BACKUP_RETENTION_ENABLED=true
PW_BACKUP_KEEP_DAILY=7
PW_BACKUP_KEEP_WEEKLY=4
PW_BACKUP_KEEP_MONTHLY=12
PW_BACKUP_KEEP_YEARLY=5
PW_BACKUP_PRUNE=true
```

Preview the policy without changing the repository:

```bash
pw-backup retention --dry-run
```

Apply it manually:

```bash
pw-backup retention
```

When retention is enabled, `pw-backup run` applies the policy after a successful backup. Snapshots are grouped by host, paths, and tags. `PW_BACKUP_PRUNE=true` physically removes repository data no longer referenced by any retained snapshot.

## Schedule

The default timer runs daily at 03:00, with up to 30 minutes of randomized delay and `Persistent=true`. Use a systemd drop-in to customize it:

```bash
systemctl edit pw-backup.timer
```

## Uninstallation

Conservative uninstall removes the program, units, all systemd drop-ins and enablement links, cache, and state. It preserves `/etc/pw-backup` and does not remove Restic or other Debian packages:

```bash
pw-backup-uninstall
```

Complete purge also deletes `/etc/pw-backup`, including configuration and secrets:

```bash
pw-backup-uninstall --purge
```

The source script supports the same operation:

```bash
./uninstall.sh
./uninstall.sh --purge
```

`--purge` does not delete the remote Restic repository and does not uninstall the Debian `restic` package.

## Tests

GitHub Actions runs on Debian 13 and verifies shell syntax, ShellCheck, installation, idempotency, permissions, systemd units, a real local Restic backup/check/restore cycle, conservative uninstall, reinstall, complete purge, drop-in cleanup, enablement-link cleanup, and purge idempotency.

## License

MIT
