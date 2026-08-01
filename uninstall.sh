#!/bin/sh
set -eu

PROJECT_NAME='PW Backup'
PROJECT_ID='pw-backup'
CONFIG_DIR="/etc/$PROJECT_ID"
CACHE_DIR="/var/cache/$PROJECT_ID"
STATE_DIR="/var/lib/$PROJECT_ID"
BIN_PATH="/usr/local/sbin/$PROJECT_ID"
UNINSTALL_PATH="/usr/local/sbin/$PROJECT_ID-uninstall"
PURGE=false

log() { printf '%s: %s\n' "$PROJECT_ID" "$*"; }
fail() { printf '%s: error: %s\n' "$PROJECT_ID" "$*" >&2; exit 1; }

show_help() {
    cat <<'HELP'
Usage:
  pw-backup-uninstall [--purge]
  ./uninstall.sh [--purge]

Options:
  --purge   Also remove /etc/pw-backup, including configuration and secrets.
  --help    Show this help.

Without --purge, configuration and secrets under /etc/pw-backup are preserved.
The Debian restic package and remote repositories are never removed.
HELP
}

case "${1:-}" in
    '') ;;
    --purge) PURGE=true ;;
    --help|-h) show_help; exit 0 ;;
    *) fail "unknown option: $1" ;;
esac
[ "$#" -le 1 ] || fail 'too many arguments'
[ "$(id -u)" -eq 0 ] || fail 'run this uninstaller as root'
command -v systemctl >/dev/null 2>&1 || fail 'systemctl is not available'

for unit in pw-backup.timer pw-backup-maintenance.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done
for unit in pw-backup.service pw-backup-maintenance.service; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
done

rm -f "$BIN_PATH"
for unit in \
    pw-backup.service pw-backup.timer \
    pw-backup-maintenance.service pw-backup-maintenance.timer
do
    rm -f "/etc/systemd/system/$unit"
    rm -rf "/etc/systemd/system/$unit.d"
done
find /etc/systemd/system -type l \
    \( -name 'pw-backup.service' -o -name 'pw-backup.timer' \
       -o -name 'pw-backup-maintenance.service' -o -name 'pw-backup-maintenance.timer' \) \
    -delete 2>/dev/null || true
rm -rf "$CACHE_DIR" "$STATE_DIR"

if [ "$PURGE" = true ]; then
    log 'purging configuration and secrets'
    rm -rf "$CONFIG_DIR"
else
    log "preserving configuration and secrets in $CONFIG_DIR"
fi

systemctl daemon-reload
systemctl reset-failed \
    pw-backup.service pw-backup.timer \
    pw-backup-maintenance.service pw-backup-maintenance.timer \
    >/dev/null 2>&1 || true
rm -f "$UNINSTALL_PATH"

printf '\n%s has been uninstalled.\n' "$PROJECT_NAME"
if [ "$PURGE" = false ] && [ -e "$CONFIG_DIR" ]; then
    printf 'Preserved: %s\n' "$CONFIG_DIR"
fi
printf 'The Debian restic package and remote repositories were not modified.\n'
