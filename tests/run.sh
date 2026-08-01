#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
ORIGINAL_PATH=$PATH

cleanup() {
    rm -rf "$TEST_ROOT"
    rm -rf /etc/pw-backup /var/cache/pw-backup /var/lib/pw-backup
    rm -rf /etc/systemd/system/pw-backup.service.d
    rm -rf /etc/systemd/system/pw-backup.timer.d
    rm -f /usr/local/sbin/pw-backup
    rm -f /usr/local/sbin/pw-backup-uninstall
    rm -f /etc/systemd/system/pw-backup.service
    rm -f /etc/systemd/system/pw-backup.timer
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test failure: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    expected=$1
    actual=$2
    description=$3
    [ "$actual" = "$expected" ] || \
        fail "$description: expected '$expected', got '$actual'"
}

assert_mode() {
    expected=$1
    path=$2
    actual=$(stat -c '%a' "$path")
    assert_eq "$expected" "$actual" "mode for $path"
}

assert_fails() {
    output_file=$1
    shift
    if "$@" >"$output_file" 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

[ "$(id -u)" -eq 0 ] || fail 'run tests as root in a disposable Debian environment'
[ -r /etc/os-release ] || fail '/etc/os-release is unavailable'

# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = 'debian' ] || fail 'tests require Debian'

for command_name in shellcheck systemd-analyze jq restic; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done

cd "$PROJECT_ROOT"

test -x install.sh || fail 'install.sh is not executable'
test -x uninstall.sh || fail 'uninstall.sh is not executable'
test -x files/pw-backup || fail 'files/pw-backup is not executable'
test -x tests/run.sh || fail 'tests/run.sh is not executable'
test -x tests/uninstall.sh || fail 'tests/uninstall.sh is not executable'

printf '%s\n' 'Running shell syntax and ShellCheck tests...'
sh -n install.sh
sh -n uninstall.sh
sh -n files/pw-backup
sh -n tests/run.sh
sh -n tests/uninstall.sh
shellcheck install.sh uninstall.sh files/pw-backup tests/run.sh tests/uninstall.sh

printf '%s\n' 'Preparing a disposable systemctl stub...'
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

printf '%s\n' 'Running first installer execution...'
./install.sh > "$TEST_ROOT/install-first.log"
grep -Fq 'PW Backup 0.1.0 is installed.' "$TEST_ROOT/install-first.log" || \
    fail 'installer reported the wrong project version'
assert_eq '0.1.0' "$(cat /var/lib/pw-backup/installed-version)" 'installed version'
assert_eq 'pw-backup 0.1.0' "$(pw-backup --version)" 'runner version'

assert_mode 755 /usr/local/sbin/pw-backup
assert_mode 755 /usr/local/sbin/pw-backup-uninstall
assert_mode 700 /etc/pw-backup
assert_mode 600 /etc/pw-backup/config.env
assert_mode 600 /etc/pw-backup/paths
assert_mode 600 /etc/pw-backup/excludes
assert_mode 600 /etc/pw-backup/repository-password
assert_mode 700 /var/cache/pw-backup/restic
assert_mode 755 /var/lib/pw-backup
assert_mode 644 /var/lib/pw-backup/installed-version
assert_mode 644 /etc/systemd/system/pw-backup.service
assert_mode 644 /etc/systemd/system/pw-backup.timer

grep -Fxq 'daemon-reload' "$SYSTEMCTL_LOG" || fail 'installer did not reload systemd'
if grep -Eq '(^| )(enable|start|restart)( |$)' "$SYSTEMCTL_LOG"; then
    fail 'installer enabled or started a unit without explicit administrator action'
fi

printf '%s\n' 'Checking idempotent installation and configuration preservation...'
printf '%s\n' '# preservation marker' >> /etc/pw-backup/config.env
config_checksum=$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')
./install.sh > "$TEST_ROOT/install-second.log"
assert_eq "$config_checksum" "$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')" \
    'configuration preservation'
assert_eq '0.1.0' "$(cat /var/lib/pw-backup/installed-version)" \
    'installed version after repeated installation'

printf '%s\n' 'Validating systemd units...'
systemd-analyze verify \
    /etc/systemd/system/pw-backup.service \
    /etc/systemd/system/pw-backup.timer

printf '%s\n' 'Preparing an actual local Restic repository...'
CONFIG_DIR="$TEST_ROOT/config"
SOURCE_DIR="$TEST_ROOT/source"
REPOSITORY_DIR="$TEST_ROOT/repository"
RESTORE_DIR="$TEST_ROOT/restore"
CACHE_DIR="$TEST_ROOT/cache"
mkdir -p "$CONFIG_DIR" "$SOURCE_DIR/subdir"

printf '%s\n' 'first version' > "$SOURCE_DIR/subdir/document.txt"
printf '%s\n' 'excluded data' > "$SOURCE_DIR/ignored.tmp"
printf '%s\n' 'integration-test-password' > "$CONFIG_DIR/repository-password"
printf '%s\n' "$SOURCE_DIR" > "$CONFIG_DIR/paths"
printf '%s\n' '*.tmp' > "$CONFIG_DIR/excludes"
cat > "$CONFIG_DIR/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY=$REPOSITORY_DIR
RESTIC_PASSWORD_FILE=$CONFIG_DIR/repository-password
RESTIC_CACHE_DIR=$CACHE_DIR
PW_BACKUP_TAG=integration-test
PW_BACKUP_HOST=debian-test
PW_BACKUP_SKIP_IF_UNCHANGED=false
EOF_CONFIG
chmod 0700 "$CONFIG_DIR"
chmod 0600 \
    "$CONFIG_DIR/config.env" \
    "$CONFIG_DIR/repository-password" \
    "$CONFIG_DIR/paths" \
    "$CONFIG_DIR/excludes"

PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup check-config
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic init
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup run

snapshot_count=$(PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    pw-backup restic snapshots --json | jq 'length')
assert_eq '1' "$snapshot_count" 'snapshot count after first backup'

printf '%s\n' 'second version' > "$SOURCE_DIR/subdir/document.txt"
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup run
snapshot_count=$(PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    pw-backup restic snapshots --json | jq 'length')
assert_eq '2' "$snapshot_count" 'snapshot count after changed backup'

PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup restic check
PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" \
    pw-backup restic restore latest --target "$RESTORE_DIR"

RESTORED_SOURCE="$RESTORE_DIR$SOURCE_DIR"
cmp "$SOURCE_DIR/subdir/document.txt" "$RESTORED_SOURCE/subdir/document.txt" || \
    fail 'restored file does not match the latest source content'
[ ! -e "$RESTORED_SOURCE/ignored.tmp" ] || fail 'excluded file was restored'

printf '%s\n' 'Testing Restic skip-if-unchanged with a relative source...'
SKIP_CONFIG_DIR="$TEST_ROOT/skip-config"
SKIP_SOURCE_DIR="$TEST_ROOT/skip-source"
SKIP_REPOSITORY_DIR="$TEST_ROOT/skip-repository"
SKIP_CACHE_DIR="$TEST_ROOT/skip-cache"
mkdir -p "$SKIP_CONFIG_DIR" "$SKIP_SOURCE_DIR"
printf '%s\n' 'stable content' > "$SKIP_SOURCE_DIR/document.txt"
printf '%s\n' 'skip-test-password' > "$SKIP_CONFIG_DIR/repository-password"
printf '%s\n' '.' > "$SKIP_CONFIG_DIR/paths"
: > "$SKIP_CONFIG_DIR/excludes"
cat > "$SKIP_CONFIG_DIR/config.env" <<EOF_SKIP_CONFIG
RESTIC_REPOSITORY=$SKIP_REPOSITORY_DIR
RESTIC_PASSWORD_FILE=$SKIP_CONFIG_DIR/repository-password
RESTIC_CACHE_DIR=$SKIP_CACHE_DIR
PW_BACKUP_TAG=skip-test
PW_BACKUP_HOST=debian-skip-test
PW_BACKUP_SKIP_IF_UNCHANGED=true
EOF_SKIP_CONFIG
chmod 0700 "$SKIP_CONFIG_DIR"
chmod 0600 \
    "$SKIP_CONFIG_DIR/config.env" \
    "$SKIP_CONFIG_DIR/repository-password" \
    "$SKIP_CONFIG_DIR/paths" \
    "$SKIP_CONFIG_DIR/excludes"

(
    cd "$SKIP_SOURCE_DIR"
    PW_BACKUP_CONFIG_DIR="$SKIP_CONFIG_DIR" pw-backup restic init
    PW_BACKUP_CONFIG_DIR="$SKIP_CONFIG_DIR" pw-backup run
    PW_BACKUP_CONFIG_DIR="$SKIP_CONFIG_DIR" pw-backup run
)

snapshot_count=$(PW_BACKUP_CONFIG_DIR="$SKIP_CONFIG_DIR" \
    pw-backup restic snapshots --json | jq 'length')
assert_eq '1' "$snapshot_count" 'snapshot count after unchanged relative-path backup'

printf '%s\n' 'Testing configuration failures...'
chmod 0660 "$CONFIG_DIR/config.env"
assert_fails "$TEST_ROOT/group-writable.log" \
    env PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup check-config
grep -Fq 'must not be writable by group or others' "$TEST_ROOT/group-writable.log" || \
    fail 'group-writable configuration error was not reported clearly'
chmod 0600 "$CONFIG_DIR/config.env"

: > "$CONFIG_DIR/paths"
assert_fails "$TEST_ROOT/empty-paths.log" \
    env PW_BACKUP_CONFIG_DIR="$CONFIG_DIR" pw-backup check-config
grep -Fq 'does not contain any active source' "$TEST_ROOT/empty-paths.log" || \
    fail 'empty paths error was not reported clearly'

printf '%s\n' 'All PW Backup tests passed.'
