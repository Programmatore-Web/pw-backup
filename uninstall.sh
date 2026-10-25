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

# Include running, disabled, and enabled-on-disk instances. Do not pass wildcards
# to systemctl disable: they are not expanded there like list-units patterns.
group_units=$(
    {
        systemctl list-units --all --plain --no-legend --no-pager 'pw-backup@*.service' 'pw-backup@*.timer' || true
        systemctl list-unit-files --no-legend --no-pager 'pw-backup@*.service' 'pw-backup@*.timer' || true
        find /etc/systemd/system \( -name 'pw-backup@*.service' -o -name 'pw-backup@*.timer' \) -printf '%f\n'
    } | awk '$1 ~ /^pw-backup@[a-z0-9][a-z0-9_-]*\.(service|timer)$/ {print $1}' | sort -u
)
for unit in $group_units; do
    case "$unit" in
        *.timer) systemctl disable --now "$unit" >/dev/null 2>&1 || true ;;
    esac
done

for unit in pw-backup.timer pw-backup-maintenance.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done
# Stop every timer before services so an instance cannot be triggered again
# while its service and files are being removed.
for unit in $group_units; do
    case "$unit" in
        *.service)
            systemctl stop "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
            ;;
    esac
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
for path in /etc/systemd/system/pw-backup@*.service /etc/systemd/system/pw-backup@*.timer; do
    rm -f "$path"
done
for path in /etc/systemd/system/pw-backup@*.service.d /etc/systemd/system/pw-backup@*.timer.d; do
    rm -rf "$path"
done
find /etc/systemd/system -type l \
    \( -name 'pw-backup.service' -o -name 'pw-backup.timer' \
       -o -name 'pw-backup-maintenance.service' -o -name 'pw-backup-maintenance.timer' \
       -o -name 'pw-backup@*.service' -o -name 'pw-backup@*.timer' \) \
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
for unit in $group_units; do
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
done
rm -f "$UNINSTALL_PATH"

printf '\n%s has been uninstalled.\n' "$PROJECT_NAME"
if [ "$PURGE" = false ] && [ -e "$CONFIG_DIR" ]; then
    printf 'Preserved: %s\n' "$CONFIG_DIR"
fi
printf 'The Debian restic package and remote repositories were not modified.\n'
