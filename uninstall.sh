#!/bin/sh
set -eu

PROJECT_NAME='PW Backup'
PROJECT_ID='pw-backup'
CONFIG_DIR="/etc/$PROJECT_ID"
CACHE_DIR="/var/cache/$PROJECT_ID"
STATE_DIR="/var/lib/$PROJECT_ID"
BIN_PATH="/usr/local/sbin/$PROJECT_ID"
UNINSTALL_PATH="/usr/local/sbin/$PROJECT_ID-uninstall"
SERVICE_PATH="/etc/systemd/system/$PROJECT_ID.service"
TIMER_PATH="/etc/systemd/system/$PROJECT_ID.timer"
SERVICE_DROPIN_DIR="$SERVICE_PATH.d"
TIMER_DROPIN_DIR="$TIMER_PATH.d"
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
The Debian restic package and other system packages are never removed.
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

log 'stopping and disabling scheduled backups'
systemctl disable --now "$PROJECT_ID.timer" >/dev/null 2>&1 || true
systemctl stop "$PROJECT_ID.service" >/dev/null 2>&1 || true
systemctl disable "$PROJECT_ID.service" >/dev/null 2>&1 || true

log 'removing installed files and systemd customizations'
rm -f "$BIN_PATH" "$SERVICE_PATH" "$TIMER_PATH"
rm -rf "$SERVICE_DROPIN_DIR" "$TIMER_DROPIN_DIR"
find /etc/systemd/system -type l \
    \( -name "$PROJECT_ID.service" -o -name "$PROJECT_ID.timer" \) \
    -delete 2>/dev/null || true
rm -rf "$CACHE_DIR" "$STATE_DIR"

if [ "$PURGE" = true ]; then
    log 'purging configuration and secrets'
    rm -rf "$CONFIG_DIR"
else
    log "preserving configuration and secrets in $CONFIG_DIR"
fi

systemctl daemon-reload
systemctl reset-failed "$PROJECT_ID.service" "$PROJECT_ID.timer" >/dev/null 2>&1 || true
rm -f "$UNINSTALL_PATH"

printf '\n%s has been uninstalled.\n' "$PROJECT_NAME"
if [ "$PURGE" = false ] && [ -e "$CONFIG_DIR" ]; then
    printf 'Preserved: %s\n' "$CONFIG_DIR"
fi
printf 'The Debian restic package and its repositories were not modified.\n'
