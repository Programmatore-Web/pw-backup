#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
ORIGINAL_PATH=$PATH

cleanup() {
    rm -rf "$TEST_ROOT" /etc/pw-backup /var/cache/pw-backup /var/lib/pw-backup
    rm -rf /etc/systemd/system/pw-backup*.d
    rm -f /usr/local/sbin/pw-backup /usr/local/sbin/pw-backup-uninstall
    rm -f /etc/systemd/system/pw-backup.service /etc/systemd/system/pw-backup.timer
    rm -f /etc/systemd/system/pw-backup-maintenance.service /etc/systemd/system/pw-backup-maintenance.timer
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'test failure: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }

[ "$(id -u)" -eq 0 ] || fail 'run tests as root in a disposable Debian environment'
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = 'debian' ] || fail 'tests require Debian'
for command_name in shellcheck systemd-analyze jq restic; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

cd "$PROJECT_ROOT"
sh -n install.sh uninstall.sh files/pw-backup tests/run.sh tests/uninstall.sh
shellcheck install.sh uninstall.sh files/pw-backup tests/run.sh tests/uninstall.sh

mkdir -p "$TEST_ROOT/bin" /run/systemd/system
cat > "$TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod 0755 "$TEST_ROOT/bin/systemctl"
export SYSTEMCTL_LOG
PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
export PATH

./install.sh > "$TEST_ROOT/install.log"
assert_eq '0.2.0' "$(cat /var/lib/pw-backup/installed-version)" 'installed version'
assert_eq 'pw-backup 0.2.0' "$(pw-backup --version)" 'runner version'
for path in \
    /etc/systemd/system/pw-backup.service \
    /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/pw-backup-maintenance.service \
    /etc/systemd/system/pw-backup-maintenance.timer
do
    [ -f "$path" ] || fail "missing installed unit: $path"
done
systemd-analyze verify \
    /etc/systemd/system/pw-backup.service \
    /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/pw-backup-maintenance.service \
    /etc/systemd/system/pw-backup-maintenance.timer
if grep -Eq '(^| )(enable|start|restart)( |$)' "$SYSTEMCTL_LOG"; then
    fail 'installer enabled or started a unit without explicit administrator action'
fi

CONFIG_DIR="$TEST_ROOT/config"
SOURCE_DIR="$TEST_ROOT/source"
REPOSITORY_DIR="$TEST_ROOT/repository"
RESTORE_DIR="$TEST_ROOT/restore"
CACHE_DIR="$TEST_ROOT/cache"
mkdir -p "$CONFIG_DIR" "$SOURCE_DIR"
printf '%s\n' 'test-password' > "$CONFIG_DIR/repository-password"
printf '%s\n' "$SOURCE_DIR" > "$CONFIG_DIR/paths"
: > "$CONFIG_DIR/excludes"
cat > "$CONFIG_DIR/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY=$REPOSITORY_DIR
RESTIC_PASSWORD_FILE=$CONFIG_DIR/repository-password
RESTIC_CACHE_DIR=$CACHE_DIR
PW_BACKUP_TAG=integration-test
PW_BACKUP_HOST=debian-test
PW_BACKUP_SKIP_IF_UNCHANGED=false
PW_BACKUP_RETENTION_ENABLED=true
PW_BACKUP_KEEP_LAST=2
PW_BACKUP_KEEP_HOURLY=
PW_BACKUP_KEEP_DAILY=
PW_BACKUP_KEEP_WEEKLY=
PW_BACKUP_KEEP_MONTHLY=
PW_BACKUP_KEEP_YEARLY=
PW_BACKUP_PRUNE=true
EOF_CONFIG
chmod 0700 "$CONFIG_DIR"
chmod 0600 "$CONFIG_DIR"/*

PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup check-config
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic init
for version in 1 2 3; do
    printf 'version %s\n' "$version" > "$SOURCE_DIR/document.txt"
    PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup run
    sleep 1
done

count=$(PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic snapshots --json | jq 'length')
assert_eq '3' "$count" 'backup must not apply maintenance automatically'

PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup maintenance --dry-run > "$TEST_ROOT/dry-run.log"
count=$(PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic snapshots --json | jq 'length')
assert_eq '3' "$count" 'dry-run changed snapshots'

PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup maintenance
count=$(PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic snapshots --json | jq 'length')
assert_eq '2' "$count" 'maintenance retention count'
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic check
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic restore latest --target "$RESTORE_DIR"
cmp "$SOURCE_DIR/document.txt" "$RESTORE_DIR$SOURCE_DIR/document.txt" || fail 'restored content differs'

sed -i 's/PW_BACKUP_KEEP_LAST=2/PW_BACKUP_KEEP_LAST=/' "$CONFIG_DIR/config.env"
if PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup check-config >"$TEST_ROOT/invalid.log" 2>&1; then
    fail 'enabled retention without policy unexpectedly validated'
fi
grep -Fq 'no keep policy is configured' "$TEST_ROOT/invalid.log" || fail 'missing retention validation message'

printf '%s\n' 'All PW Backup tests passed.'
