#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'lock tests require root in a disposable Debian environment' >&2; exit 1; }
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
RUNNER="$PROJECT_ROOT/files/pw-backup"
CONFIG_ROOT="$TEST_ROOT/config"
OTHER_CONFIG="$TEST_ROOT/other-config"
SOURCE_DIR="$TEST_ROOT/source"
TEST_RESTIC=$(command -v restic)
TEST_FLOCK=$(command -v flock)
TEST_LOCK_LOG="$TEST_ROOT/flock.log"
TEST_COORDINATION="$TEST_ROOT/coordination"
RESTIC_REPOSITORY="$TEST_ROOT/repository"
RESTIC_PASSWORD_FILE="$TEST_ROOT/password"
RESTIC_CACHE_DIR="$TEST_ROOT/cache"
first_pid=''
second_pid=''
termination_pid=''
export TEST_RESTIC TEST_FLOCK TEST_LOCK_LOG TEST_COORDINATION
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR

cleanup() {
    for pid in "$first_pid" "$second_pid"; do
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    done
    if [ -n "$termination_pid" ]; then kill -TERM "-$termination_pid" 2>/dev/null || true; fi
    # Let any held fixture finish before removing its temporary files.
    : > "$TEST_COORDINATION/release"
    wait 2>/dev/null || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'lock test failure: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }
pw() { PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" "$@"; }
wait_for() {
    attempts=0
    until [ -e "$1" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 200 ] || fail "timed out waiting for fixture: $1"
        sleep 0.05
    done
}
wait_for_waiter() {
    attempts=0
    until grep -Fq 'waiting for the shared local lock' "$1"; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 200 ] || fail 'second runner did not reach lock acquisition'
        sleep 0.05
    done
}

mkdir -p "$TEST_ROOT/bin" "$CONFIG_ROOT/groups/documents" "$OTHER_CONFIG" "$SOURCE_DIR" "$TEST_COORDINATION"
cat > "$TEST_ROOT/bin/restic" <<'RESTIC'
#!/bin/sh
set -eu
if [ "${TEST_FAIL_RESTIC:-false}" = true ]; then exit 42; fi
if [ "${TEST_CHECK_CONCURRENCY:-false}" = true ]; then
    if ! mkdir "$TEST_COORDINATION/active"; then
        : > "$TEST_COORDINATION/overlap"
        exit 43
    fi
    trap 'rmdir "$TEST_COORDINATION/active"' EXIT
    trap 'exit 143' TERM
    if [ "${TEST_HOLD_RESTIC:-false}" = true ]; then
        : > "$TEST_COORDINATION/entered"
        while [ ! -e "$TEST_COORDINATION/release" ]; do sleep 0.05; done
    fi
    "$TEST_RESTIC" "$@"
else
    exec "$TEST_RESTIC" "$@"
fi
RESTIC
cat > "$TEST_ROOT/bin/flock" <<'FLOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$TEST_LOCK_LOG"
if [ "${TEST_FAST_TIMEOUT:-false}" = true ]; then
    # Exercise a REAL contended kernel lock without waiting five minutes.
    # Assert the production timeout before shortening only this test's wait.
    [ "$#" -eq 3 ] && [ "$1" = -w ] && [ "$2" = 300 ]
    exec "$TEST_FLOCK" -w 0.2 "$3"
fi
exec "$TEST_FLOCK" "$@"
FLOCK
chmod 0755 "$TEST_ROOT/bin/restic" "$TEST_ROOT/bin/flock"
PATH="$TEST_ROOT/bin:$PATH"
export PATH
printf '%s\n' 'fictitious-test-password' > "$RESTIC_PASSWORD_FILE"
printf '%s\n' 'lock test content' > "$SOURCE_DIR/document.txt"
cat > "$CONFIG_ROOT/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY='$RESTIC_REPOSITORY'
RESTIC_PASSWORD_FILE='$RESTIC_PASSWORD_FILE'
RESTIC_CACHE_DIR='$RESTIC_CACHE_DIR'
PW_BACKUP_HOST=machine-a
PW_BACKUP_TAG=legacy-lock-test
PW_BACKUP_SKIP_IF_UNCHANGED=false
PW_BACKUP_RETENTION_ENABLED=false
PW_BACKUP_PRUNE=false
EOF_CONFIG
cat > "$CONFIG_ROOT/groups/documents/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY='$RESTIC_REPOSITORY'
RESTIC_PASSWORD_FILE='$RESTIC_PASSWORD_FILE'
RESTIC_CACHE_DIR='$RESTIC_CACHE_DIR'
PW_BACKUP_HOST=machine-a
PW_BACKUP_SKIP_IF_UNCHANGED=false
PW_BACKUP_RETENTION_ENABLED=true
PW_BACKUP_KEEP_LAST=5
PW_BACKUP_PRUNE=false
EOF_CONFIG
printf '%s\n' "$SOURCE_DIR" > "$CONFIG_ROOT/paths"
cp "$CONFIG_ROOT/paths" "$CONFIG_ROOT/groups/documents/paths"
cp "$CONFIG_ROOT/paths" "$OTHER_CONFIG/paths"
cp "$CONFIG_ROOT/config.env" "$OTHER_CONFIG/config.env"
chmod 0600 "$CONFIG_ROOT/config.env" "$CONFIG_ROOT/groups/documents/config.env" "$OTHER_CONFIG/config.env"
pw restic init

start_holder() {
    rm -f "$TEST_COORDINATION/entered" "$TEST_COORDINATION/release" "$TEST_COORDINATION/overlap"
    TEST_CHECK_CONCURRENCY=true TEST_HOLD_RESTIC=true \
        PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" run --group documents >"$TEST_ROOT/first.log" 2>&1 &
    first_pid=$!
    wait_for "$TEST_COORDINATION/entered"
}
finish_pair() {
    # The waiter has reached flock while the first process still owns it.
    wait_for_waiter "$TEST_ROOT/second.log"
    kill -0 "$second_pid" || fail 'second operation did not wait for the lock'
    [ ! -e "$TEST_COORDINATION/overlap" ] || fail 'concurrent unprotected Restic operations'
    : > "$TEST_COORDINATION/release"
    wait "$first_pid" || { cat "$TEST_ROOT/first.log" >&2; fail 'first backup failed'; }
    first_pid=''
    wait "$second_pid" || { cat "$TEST_ROOT/second.log" >&2; fail 'second operation failed'; }
    second_pid=''
    [ ! -e "$TEST_COORDINATION/overlap" ] || fail 'Restic operations overlapped'
}

# A group backup and a legacy backup using a DIFFERENT configuration root must
# serialize on the same machine-wide lock, then both create real snapshots.
start_holder
TEST_CHECK_CONCURRENCY=true PW_BACKUP_CONFIG_DIR="$OTHER_CONFIG" \
    "$RUNNER" run >"$TEST_ROOT/second.log" 2>&1 &
second_pid=$!
finish_pair
assert_eq 2 "$(restic snapshots --json | jq length)" 'concurrent backups completed'

start_holder
TEST_CHECK_CONCURRENCY=true PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" \
    "$RUNNER" maintenance >"$TEST_ROOT/second.log" 2>&1 &
second_pid=$!
finish_pair

start_holder
TEST_CHECK_CONCURRENCY=true PW_BACKUP_CONFIG_DIR="$OTHER_CONFIG" \
    "$RUNNER" restic snapshots --json >"$TEST_ROOT/second.log" 2>"$TEST_ROOT/waiter.log" &
second_pid=$!
# Keep JSON stdout separate while checking the lock message on stderr.
wait_for_waiter "$TEST_ROOT/waiter.log"
: > "$TEST_COORDINATION/release"
wait "$first_pid"
first_pid=''
wait "$second_pid"
second_pid=''
jq -e 'length >= 2' "$TEST_ROOT/second.log" >/dev/null
[ ! -e "$TEST_COORDINATION/overlap" ] || fail 'direct Restic bypassed the lock'

start_holder
if TEST_FAST_TIMEOUT=true pw run >"$TEST_ROOT/timeout.log" 2>&1; then fail 'contended lock did not time out'; fi
grep -Fq 'after 300s' "$TEST_ROOT/timeout.log" || fail 'timeout error did not state the fixed timeout'
kill -0 "$first_pid" || fail 'timeout disturbed the lock owner'
: > "$TEST_COORDINATION/release"
wait "$first_pid"
first_pid=''

error_status=0
TEST_FAIL_RESTIC=true pw run >"$TEST_ROOT/error.log" 2>&1 || error_status=$?
assert_eq 42 "$error_status" 'Restic failure status preserved'
pw run --group documents >"$TEST_ROOT/after-error.log" 2>&1

# Terminate the operation and its children, as systemd's default control-group
# termination does. Inherited descriptors must not leave a stale flock behind.
rm -f "$TEST_COORDINATION/entered" "$TEST_COORDINATION/release"
setsid env TEST_CHECK_CONCURRENCY=true TEST_HOLD_RESTIC=true \
    PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" run --group documents >"$TEST_ROOT/termination.log" 2>&1 &
termination_pid=$!
wait_for "$TEST_COORDINATION/entered"
kill -TERM "-$termination_pid"
if wait "$termination_pid"; then fail 'terminated operation unexpectedly succeeded'; fi
termination_pid=''
pw run --group documents >"$TEST_ROOT/after-termination.log" 2>&1

: > "$TEST_LOCK_LOG"
pw maintenance >"$TEST_ROOT/maintenance.log" 2>&1
assert_eq 1 "$(wc -l < "$TEST_LOCK_LOG" | tr -d ' ')" 'maintenance acquires the lock once'
assert_eq '-w 300 9' "$(cat "$TEST_LOCK_LOG")" 'fixed production timeout'
assert_eq 0 "$(stat -c '%u' /run/pw-backup)" 'protected runtime directory owner'
assert_eq 700 "$(stat -c '%a' /run/pw-backup)" 'protected runtime directory permissions'
restic check
printf '%s\n' 'All PW Backup lock tests passed.'
