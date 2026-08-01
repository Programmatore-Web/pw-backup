#!/bin/sh
set -eu

PROJECT_NAME='PW Backup'
PROJECT_ID='pw-backup'
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_VERSION=$(cat "$SCRIPT_DIR/VERSION")

CONFIG_DIR="/etc/$PROJECT_ID"
CACHE_DIR="/var/cache/$PROJECT_ID/restic"
STATE_DIR="/var/lib/$PROJECT_ID"
BIN_PATH="/usr/local/sbin/$PROJECT_ID"
UNINSTALL_PATH="/usr/local/sbin/$PROJECT_ID-uninstall"
SERVICE_PATH="/etc/systemd/system/$PROJECT_ID.service"
TIMER_PATH="/etc/systemd/system/$PROJECT_ID.timer"
MAINTENANCE_SERVICE_PATH="/etc/systemd/system/$PROJECT_ID-maintenance.service"
MAINTENANCE_TIMER_PATH="/etc/systemd/system/$PROJECT_ID-maintenance.timer"

log() { printf '%s: %s\n' "$PROJECT_ID" "$*"; }
fail() { printf '%s: error: %s\n' "$PROJECT_ID" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail 'run this installer as root'
[ -r /etc/os-release ] || fail 'cannot identify the operating system'
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = 'debian' ] || fail "version $PROJECT_VERSION supports Debian only"
[ -d /run/systemd/system ] || fail 'systemd is not running as the system manager'
command -v apt-get >/dev/null 2>&1 || fail 'apt-get is not available'

for required_file in \
    "$SCRIPT_DIR/VERSION" \
    "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/files/pw-backup" \
    "$SCRIPT_DIR/files/pw-backup.service" \
    "$SCRIPT_DIR/files/pw-backup.timer" \
    "$SCRIPT_DIR/files/pw-backup-maintenance.service" \
    "$SCRIPT_DIR/files/pw-backup-maintenance.timer" \
    "$SCRIPT_DIR/examples/config.env" \
    "$SCRIPT_DIR/examples/paths" \
    "$SCRIPT_DIR/examples/excludes"
do
    [ -r "$required_file" ] || fail "required project file is missing: $required_file"
done

log 'refreshing Debian package metadata'
apt-get update
log 'installing packages from the official Debian repositories'
DEBIAN_FRONTEND=noninteractive apt-get install --yes restic openssh-client ca-certificates

log 'installing program files'
install -D -m 0755 "$SCRIPT_DIR/files/pw-backup" "$BIN_PATH"
install -D -m 0755 "$SCRIPT_DIR/uninstall.sh" "$UNINSTALL_PATH"
install -D -m 0644 "$SCRIPT_DIR/files/pw-backup.service" "$SERVICE_PATH"
install -D -m 0644 "$SCRIPT_DIR/files/pw-backup.timer" "$TIMER_PATH"
install -D -m 0644 "$SCRIPT_DIR/files/pw-backup-maintenance.service" "$MAINTENANCE_SERVICE_PATH"
install -D -m 0644 "$SCRIPT_DIR/files/pw-backup-maintenance.timer" "$MAINTENANCE_TIMER_PATH"
install -d -m 0700 "$CONFIG_DIR" "$CACHE_DIR"
install -d -m 0755 "$STATE_DIR"

for name in config.env paths excludes; do
    if [ ! -e "$CONFIG_DIR/$name" ]; then
        install -m 0600 "$SCRIPT_DIR/examples/$name" "$CONFIG_DIR/$name"
        log "created $CONFIG_DIR/$name"
    else
        log "preserved existing $CONFIG_DIR/$name"
    fi
done

if [ ! -e "$CONFIG_DIR/repository-password" ]; then
    : > "$CONFIG_DIR/repository-password"
    log "created empty $CONFIG_DIR/repository-password"
else
    log "preserved existing $CONFIG_DIR/repository-password"
fi
chmod 0600 "$CONFIG_DIR/repository-password"

printf '%s\n' "$PROJECT_VERSION" > "$STATE_DIR/installed-version"
chmod 0644 "$STATE_DIR/installed-version"
systemctl daemon-reload

cat <<INSTALL_SUMMARY

$PROJECT_NAME $PROJECT_VERSION is installed.
The installer has not enabled or started any timer.

Next steps:
  1. Edit $CONFIG_DIR/config.env and $CONFIG_DIR/paths
  2. Write the repository password to $CONFIG_DIR/repository-password
  3. Validate: $BIN_PATH check-config
  4. Initialize a new repository explicitly when needed: $BIN_PATH restic init
  5. Test backup: systemctl start $PROJECT_ID.service
  6. Preview maintenance: $BIN_PATH maintenance --dry-run
  7. Test maintenance: systemctl start $PROJECT_ID-maintenance.service
  8. Enable the selected timers explicitly

Uninstall while preserving configuration:
  $UNINSTALL_PATH
Purge the complete PW Backup configuration and secrets:
  $UNINSTALL_PATH --purge
INSTALL_SUMMARY
