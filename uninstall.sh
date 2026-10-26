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

# Serialize the pending-state check and removal with every backup/recovery.
# ExecStopPost exits before acquiring the lock when its group has no state.
[ ! -L /run/pw-backup ] || fail 'unsafe lock directory'
(umask 077; mkdir -p /run/pw-backup)
[ "$(stat -c '%u' /run/pw-backup)" = 0 ] || fail 'lock directory must be owned by root'
chmod 0700 /run/pw-backup
[ ! -L /run/pw-backup/operation.lock ] || fail 'unsafe lock file'
umask 077
exec 9>/run/pw-backup/operation.lock
flock -w 300 9 || fail 'could not acquire the shared local lock within 300s'
if [ -L "$STATE_DIR/pending" ]; then fail 'CRITICAL: unsafe recovery state; uninstall refused'; fi
if [ -e "$STATE_DIR/pending" ]; then
    [ -d "$STATE_DIR/pending" ] || fail 'CRITICAL: invalid recovery state; uninstall refused'
    pending_entry=$(find "$STATE_DIR/pending" -mindepth 1 -maxdepth 1 -print -quit) || \
        fail 'CRITICAL: cannot inspect recovery state; uninstall refused'
    [ -z "$pending_entry" ] || \
        fail 'CRITICAL: pending recovery must be completed before uninstall, including --purge'
fi

# Include running, disabled, and enabled-on-disk instances. Do not pass wildcards
# to systemctl disable: they are not expanded there like list-units patterns.
listed_units=$(systemctl list-units --all --plain --full --no-legend --no-pager \
    'pw-backup@*.service' 'pw-backup@*.timer') || fail 'cannot list group units; uninstall refused'
listed_files=$(systemctl list-unit-files --full --no-legend --no-pager \
    'pw-backup@*.service' 'pw-backup@*.timer') || fail 'cannot list group unit files; uninstall refused'
disk_units=$(find /etc/systemd/system \( -name 'pw-backup@*.service' -o -name 'pw-backup@*.timer' \) \
    -printf '%f\n') || fail 'cannot inspect group unit files; uninstall refused'
group_units=$(printf '%s\n' "$listed_units" "$listed_files" "$disk_units" | \
    awk '$1 ~ /^pw-backup@[a-z0-9][a-z0-9_-]*\.(service|timer)$/ {print $1}' | sort -u)
all_units="$group_units
pw-backup.timer pw-backup-maintenance.timer
pw-backup.service pw-backup-maintenance.service pw-backup-recover.service"

read_unit_state() {
    unit_state=$(systemctl show "$1" --property=LoadState --property=ActiveState) || \
        fail "cannot verify systemd state for $1; uninstall refused"
    unit_load_state=$(printf '%s\n' "$unit_state" | sed -n 's/^LoadState=//p')
    unit_active_state=$(printf '%s\n' "$unit_state" | sed -n 's/^ActiveState=//p')
    case "$unit_load_state" in
        loaded|masked) [ -n "$unit_active_state" ] || fail "missing active state for $1; uninstall refused" ;;
        not-found) [ "$unit_active_state" = inactive ] || fail "unresolved systemd state for $1; uninstall refused" ;;
        *) fail "invalid load state for $1; uninstall refused" ;;
    esac
}

# Stop every timer before services. Do not remove enablement links or installed
# files until all stops have succeeded and systemd confirms quiescent states.
present_units=
for unit_type in timer service; do
    for unit in $all_units; do
        case "$unit" in
            *."$unit_type")
                read_unit_state "$unit"
                [ "$unit_load_state" != not-found ] || continue
                systemctl stop "$unit" || fail "could not stop $unit; uninstall refused"
                present_units="$present_units $unit"
                ;;
        esac
    done
done
verify_stopped_units() {
    for unit in $all_units; do
        read_unit_state "$unit"
        case "$unit_active_state" in
            inactive|failed) ;;
            *) fail "$unit is not stopped (state: $unit_active_state); uninstall refused" ;;
        esac
    done
}
verify_stopped_units
for unit in $present_units; do
    systemctl disable "$unit" || fail "could not disable $unit; uninstall refused"
done
verify_stopped_units

rm -f "$BIN_PATH"
for unit in \
    pw-backup.service pw-backup.timer \
    pw-backup-maintenance.service pw-backup-maintenance.timer pw-backup-recover.service
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
    pw-backup-recover.service \
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
