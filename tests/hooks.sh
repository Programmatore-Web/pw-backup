#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'hook tests require root in a disposable Debian environment' >&2; exit 1; }
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RUNNER="$PROJECT_ROOT/files/pw-backup"
TEST_ROOT=$(mktemp -d)
CONFIG_ROOT="$TEST_ROOT/config"
EVENTS="$TEST_ROOT/events"
TEST_REAL_RESTIC=$(command -v restic)
TEST_REAL_TIMEOUT=$(command -v timeout)
TEST_HOOK_ROOT=$TEST_ROOT
export TEST_REAL_RESTIC TEST_REAL_TIMEOUT TEST_HOOK_ROOT
root_hash=$(printf '%s\n' "$CONFIG_ROOT" | sha256sum)
STATE_PATH="/var/lib/pw-backup/pending/${root_hash%% *}-documents"
runner_pid=''
waiter_pid=''

cleanup() {
    : > "$TEST_ROOT/pre-release"
    : > "$TEST_ROOT/restic-release"
    : > "$TEST_ROOT/post-release"
    for pid in "$runner_pid" "$waiter_pid"; do
        [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$STATE_PATH" "$TEST_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf 'hook test failure: %s\n' "$*" >&2; cat "$TEST_ROOT/result.log" 2>/dev/null >&2 || true; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }
pw() { PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" "$@"; }
expect_status() {
    expected_status=$1
    shift
    actual_status=0
    pw "$@" >"$TEST_ROOT/result.log" 2>&1 || actual_status=$?
    assert_eq "$expected_status" "$actual_status" "exit status for $*"
}
expect_error() {
    expected_error=$1
    shift
    if pw "$@" >"$TEST_ROOT/result.log" 2>&1; then fail "unexpected success: $*"; fi
    grep -Fq "$expected_error" "$TEST_ROOT/result.log" || fail "missing error: $expected_error"
}
wait_for() {
    attempts=0
    until [ -e "$1" ]; do
        attempts=$((attempts + 1))
        [ "$attempts" -lt 400 ] || fail "timeout waiting for $1"
        sleep 0.05
    done
}
reset_case() {
    : > "$EVENTS"
    printf '%s\n' success > "$TEST_ROOT/pre-mode"
    printf '%s\n' success > "$TEST_ROOT/post-mode"
    printf '%s\n' success > "$TEST_ROOT/restic-mode"
    printf '%s\n' normal > "$TEST_ROOT/timeout-mode"
    rm -f "$TEST_ROOT/"*-entered "$TEST_ROOT/"*-release "$TEST_ROOT/restic-stopped"
}
write_config() {
    cat > "$CONFIG_ROOT/groups/documents/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY='$TEST_ROOT/repository'
RESTIC_PASSWORD_FILE='$TEST_ROOT/password'
RESTIC_CACHE_DIR='$TEST_ROOT/cache'
PW_BACKUP_HOST=machine-a
PW_BACKUP_SKIP_IF_UNCHANGED=false
PW_BACKUP_PRE_HOOK='$1'
PW_BACKUP_POST_HOOK='$2'
EOF_CONFIG
    chmod 0600 "$CONFIG_ROOT/groups/documents/config.env"
}
start_backup() {
    env --default-signal=HUP,INT,TERM PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" \
        "$RUNNER" run --group documents >"$TEST_ROOT/result.log" 2>&1 &
    runner_pid=$!
}
wait_backup() {
    backup_exit=0
    wait "$runner_pid" || backup_exit=$?
    runner_pid=''
    assert_eq "$1" "$backup_exit" 'background backup status'
}
assert_no_state() { [ ! -e "$STATE_PATH" ] || fail 'cleanup left pending state'; }

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/source" "$CONFIG_ROOT/groups/documents" "$CONFIG_ROOT/groups/other"
chmod 0700 "$TEST_ROOT"
cat > "$TEST_ROOT/bin/restic" <<'RESTIC'
#!/bin/sh
set -eu
if [ "$1" = backup ]; then
    printf '%s\n' restic >> "$TEST_HOOK_ROOT/events"
    case "$(cat "$TEST_HOOK_ROOT/restic-mode")" in
        failed) exit 42 ;;
        incomplete) exit 3 ;;
        hold)
            trap 'printf "%s\n" stopped > "$TEST_HOOK_ROOT/restic-stopped"' EXIT
            trap 'exit 143' TERM
            : > "$TEST_HOOK_ROOT/restic-entered"
            while [ ! -e "$TEST_HOOK_ROOT/restic-release" ]; do sleep 0.05; done
            "$TEST_REAL_RESTIC" "$@"
            exit
            ;;
    esac
fi
exec "$TEST_REAL_RESTIC" "$@"
RESTIC
cat > "$TEST_ROOT/bin/timeout" <<'TIMEOUT'
#!/bin/sh
set -eu
if [ "$(cat "$TEST_HOOK_ROOT/timeout-mode")" = fast ]; then
    [ "$1" = --kill-after=10s ] && [ "$2" = 300s ]
    shift 2
    exec "$TEST_REAL_TIMEOUT" --kill-after=0.2s 0.2s "$@"
fi
exec "$TEST_REAL_TIMEOUT" "$@"
TIMEOUT
{
    printf '#!/bin/sh\nset -eu\nfixture=%s\nstate=%s\n' "'$TEST_ROOT'" "'$STATE_PATH'"
    cat <<'PRE'
[ -f "$state/record" ] || exit 90
printf '%s|%s|%s|%s\n' "$PW_BACKUP_GROUP" "$PW_BACKUP_HOOK_PHASE" "$PW_BACKUP_BACKUP_STATUS" "$PW_BACKUP_HOOK_MODE" >> "$fixture/events"
case "$(cat "$fixture/pre-mode")" in
    failed) exit 21 ;;
    partial) : > "$fixture/application-changed"; exit 22 ;;
    hold)
        : > "$fixture/pre-entered"
        while [ ! -e "$fixture/pre-release" ]; do sleep 0.05; done
        ;;
esac
: > "$fixture/application-changed"
PRE
} > "$TEST_ROOT/pre.sh"
{
    printf '#!/bin/sh\nset -eu\nfixture=%s\n' "'$TEST_ROOT'"
    cat <<'POST'
printf '%s|%s|%s|%s\n' "$PW_BACKUP_GROUP" "$PW_BACKUP_HOOK_PHASE" "$PW_BACKUP_BACKUP_STATUS" "$PW_BACKUP_HOOK_MODE" >> "$fixture/events"
if [ -e "$fixture/restic-entered" ] && [ ! -e "$fixture/restic-stopped" ]; then exit 91; fi
case "$(cat "$fixture/post-mode")" in
    failed) exit 23 ;;
    hold)
        : > "$fixture/post-entered"
        while [ ! -e "$fixture/post-release" ]; do sleep 0.05; done
        ;;
esac
rm -f "$fixture/application-changed"
[ ! -e "$fixture/application-changed" ]
POST
} > "$TEST_ROOT/post.sh"
chmod 0700 "$TEST_ROOT/pre.sh" "$TEST_ROOT/post.sh"
chmod 0755 "$TEST_ROOT/bin/"*
PATH="$TEST_ROOT/bin:$PATH"
export PATH
printf '%s\n' 'fictitious-hook-test-password' > "$TEST_ROOT/password"
printf '%s\n' 'fictitious source content' > "$TEST_ROOT/source/document"
printf '%s\n' source > "$CONFIG_ROOT/groups/documents/paths"
reset_case
write_config '' ''
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/other/config.env"
cp "$CONFIG_ROOT/groups/documents/paths" "$CONFIG_ROOT/groups/other/paths"
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/config.env"
cp "$CONFIG_ROOT/groups/documents/paths" "$CONFIG_ROOT/paths"
cd "$TEST_ROOT"

pw restic --group documents init >"$TEST_ROOT/result.log" 2>&1
expect_status 0 run --group documents
assert_eq restic "$(cat "$EVENTS")" 'group without hooks'
assert_no_state

write_config "$TEST_ROOT/pre.sh" ''
expect_error 'PRE requires' check-config --group documents
write_config relative "$TEST_ROOT/post.sh"
expect_error 'path must be absolute' check-config --group documents
write_config "$TEST_ROOT/pre.sh" "$TEST_ROOT/post.sh"
chmod 0600 "$TEST_ROOT/pre.sh"
expect_error 'must be executable' check-config --group documents
chmod 0777 "$TEST_ROOT/pre.sh"
expect_error 'writable by group or others' check-config --group documents
chmod 0700 "$TEST_ROOT/pre.sh"
chown 65534 "$TEST_ROOT/pre.sh"
expect_error 'owned by root' check-config --group documents
chown 0 "$TEST_ROOT/pre.sh"
ln -s "$TEST_ROOT/pre.sh" "$TEST_ROOT/link.sh"
write_config "$TEST_ROOT/link.sh" "$TEST_ROOT/post.sh"
expect_error 'symlinks are not allowed' check-config --group documents
mkdir "$TEST_ROOT/unsafe"
cp "$TEST_ROOT/pre.sh" "$TEST_ROOT/unsafe/pre.sh"
chmod 0777 "$TEST_ROOT/unsafe"
write_config "$TEST_ROOT/unsafe/pre.sh" "$TEST_ROOT/post.sh"
expect_error 'writable by group or others' check-config --group documents
chmod 0700 "$TEST_ROOT/unsafe"
ln -s "$TEST_ROOT/unsafe" "$TEST_ROOT/alias"
write_config "$TEST_ROOT/alias/pre.sh" "$TEST_ROOT/post.sh"
expect_error 'symlinks are not allowed' check-config --group documents
write_config "$TEST_ROOT/./pre.sh" "$TEST_ROOT/post.sh"
expect_error 'unsafe path syntax' check-config --group documents
write_config "$TEST_ROOT/pre.sh" "$TEST_ROOT/post.sh"

reset_case
expect_status 0 check-config --group documents
expect_status 0 restic --group documents snapshots --json
expect_status 0 maintenance --dry-run
expect_status 0 maintenance
[ ! -s "$EVENTS" ] || fail 'non-backup command executed hooks'
expect_status 0 run --group documents
assert_eq "$(printf 'documents|pre|not-run|normal\nrestic\ndocuments|post|success|normal')" "$(cat "$EVENTS")" 'normal hook ordering and contract'
assert_no_state
[ ! -e "$TEST_ROOT/application-changed" ] || fail 'POST did not verify cleanup'

for pre_failure in failed partial; do
    reset_case
    printf '%s\n' "$pre_failure" > "$TEST_ROOT/pre-mode"
    if [ "$pre_failure" = failed ]; then expected_pre_exit=21; else expected_pre_exit=22; fi
    expect_status "$expected_pre_exit" run --group documents
    if grep -qx restic "$EVENTS"; then fail 'Restic ran after failed PRE'; fi
    grep -Fqx 'documents|post|not-run|normal' "$EVENTS" || fail 'POST missing after PRE failure'
    [ ! -e "$TEST_ROOT/application-changed" ] || fail 'partial PRE was not cleaned'
    assert_no_state
done
for restic_failure in failed incomplete; do
    reset_case
    printf '%s\n' "$restic_failure" > "$TEST_ROOT/restic-mode"
    if [ "$restic_failure" = failed ]; then expected_restic_exit=42; else expected_restic_exit=3; fi
    expect_status "$expected_restic_exit" run --group documents
    grep -Fqx 'documents|post|failed|normal' "$EVENTS" || fail 'POST missing after failed Restic'
    grep -Fq "Restic failed with exit code $expected_restic_exit" "$TEST_ROOT/result.log" || fail 'original Restic error was lost'
    assert_no_state
done

reset_case
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
printf '%s\n' failed > "$TEST_ROOT/post-mode"
expect_status 42 run --group documents
grep -Fq 'Restic failed with exit code 42' "$TEST_ROOT/result.log" || fail 'POST failure hid the original Restic error'
grep -Fq CRITICAL "$TEST_ROOT/result.log" || fail 'combined failure was not critical'
[ -f "$STATE_PATH/record" ] || fail 'combined failure lost pending state'
reset_case
expect_status 0 recover --group documents

reset_case
printf '%s\n' failed > "$TEST_ROOT/post-mode"
expect_status 1 run --group documents
grep -Fq CRITICAL "$TEST_ROOT/result.log" || fail 'POST failure was not critical'
[ -f "$STATE_PATH/record" ] || fail 'POST failure lost persistent state'
assert_eq "$CONFIG_ROOT" "$(sed -n '2p' "$STATE_PATH/record")" 'custom configuration root recorded'
assert_eq 600 "$(stat -c '%a' "$STATE_PATH/record")" 'state permissions'
expect_error CRITICAL recover --group documents
: > "$EVENTS"
expect_error CRITICAL run --group documents
if grep -Eq '(^restic$|\|pre\|)' "$EVENTS"; then fail 'unrecoverable group started a new backup'; fi
expect_status 0 run --group other
mkdir "$TEST_ROOT/other-config"
PW_BACKUP_CONFIG_DIR="$TEST_ROOT/other-config" "$RUNNER" recover --group documents

# Neither conservative uninstall nor purge may remove the recovery tools/state.
runner_sum=$(sha256sum /usr/local/sbin/pw-backup)
for uninstall_option in '' --purge; do
    if [ -n "$uninstall_option" ]; then
        if "$PROJECT_ROOT/uninstall.sh" "$uninstall_option" >"$TEST_ROOT/result.log" 2>&1; then fail 'purge accepted pending recovery'; fi
    elif "$PROJECT_ROOT/uninstall.sh" >"$TEST_ROOT/result.log" 2>&1; then fail 'uninstall accepted pending recovery'; fi
    grep -Fq CRITICAL "$TEST_ROOT/result.log" || fail 'uninstall did not explain pending cleanup'
    assert_eq "$runner_sum" "$(sha256sum /usr/local/sbin/pw-backup)" 'uninstall retained runner'
    [ -f /etc/systemd/system/pw-backup-recover.service ] || fail 'uninstall removed recovery unit'
    [ -f "$STATE_PATH/record" ] || fail 'uninstall removed pending state'
done

cp "$CONFIG_ROOT/groups/documents/config.env" "$TEST_ROOT/saved-config"
cp "$TEST_ROOT/post.sh" "$TEST_ROOT/saved-post"
: > "$EVENTS"
printf '%s\n' '# changed configuration' >> "$CONFIG_ROOT/groups/documents/config.env"
expect_error 'configuration changed' recover --group documents
[ ! -s "$EVENTS" ] || fail 'changed configuration executed POST'
cp "$TEST_ROOT/saved-config" "$CONFIG_ROOT/groups/documents/config.env"
printf '%s\n' '# changed script' >> "$TEST_ROOT/post.sh"
expect_error 'POST script changed' recover --group documents
cp "$TEST_ROOT/saved-post" "$TEST_ROOT/post.sh"
cp "$STATE_PATH/record" "$TEST_ROOT/saved-record"
printf '%s\n' damaged > "$STATE_PATH/record"
expect_error 'incomplete recovery record' recover --group documents
expect_error CRITICAL run --group documents
cp "$TEST_ROOT/saved-record" "$STATE_PATH/record"
# Deliberately literal data: a recovery record must never evaluate this text.
# shellcheck disable=SC2016
printf '%s' '$(touch should-not-exist)' >> "$STATE_PATH/record"
expect_error 'extra data' recover --group documents
[ ! -e should-not-exist ] || fail 'state was interpreted as code'
cp "$TEST_ROOT/saved-record" "$STATE_PATH/record"
mv "$STATE_PATH/record" "$STATE_PATH/record.tmp"
expect_error 'incomplete or ambiguous' recover --group documents
mv "$STATE_PATH/record.tmp" "$STATE_PATH/record"
reset_case
expect_status 0 recover --group documents
assert_eq 'documents|post|unknown|recovery' "$(cat "$EVENTS")" 'recovery contract'
assert_no_state
: > "$EVENTS"
expect_status 0 recover
expect_status 0 recover --group documents
[ ! -s "$EVENTS" ] || fail 'completed recovery ran POST again'

write_config '' "$TEST_ROOT/post.sh"
reset_case
expect_status 0 run --group documents
assert_eq "$(printf 'restic\ndocuments|post|success|normal')" "$(cat "$EVENTS")" 'POST-only hook'
assert_no_state
write_config "$TEST_ROOT/pre.sh" "$TEST_ROOT/post.sh"

for test_signal in TERM INT; do
    reset_case
    printf '%s\n' hold > "$TEST_ROOT/restic-mode"
    start_backup
    wait_for "$TEST_ROOT/restic-entered"
    kill -s "$test_signal" "$runner_pid"
    if [ "$test_signal" = TERM ]; then expected_signal_exit=143; else expected_signal_exit=130; fi
    wait_backup "$expected_signal_exit"
    grep -Fqx 'documents|post|interrupted|normal' "$EVENTS" || fail 'signal did not run orderly POST'
    [ -f "$TEST_ROOT/restic-stopped" ] || fail 'POST raced a live Restic process'
    assert_no_state
done
reset_case
printf '%s\n' hold > "$TEST_ROOT/pre-mode"
start_backup
wait_for "$TEST_ROOT/pre-entered"
kill -TERM "$runner_pid"
wait_backup 143
if grep -qx restic "$EVENTS"; then fail 'interrupted PRE started Restic'; fi
assert_no_state

# Accelerate only the timeout test at the existing tool boundary, checking the
# fixed production limits before using a short, real timeout on a held script.
reset_case
printf '%s\n' fast > "$TEST_ROOT/timeout-mode"
printf '%s\n' hold > "$TEST_ROOT/pre-mode"
expect_status 124 run --group documents
assert_no_state
reset_case
printf '%s\n' fast > "$TEST_ROOT/timeout-mode"
printf '%s\n' hold > "$TEST_ROOT/post-mode"
expect_status 1 run --group documents
[ -f "$STATE_PATH/record" ] || fail 'timed-out POST lost state'
reset_case
expect_status 0 recover --group documents

# SIGKILL is uncatchable. Release the orphaned stage, then start a fresh runner
# for recovery while the machine stays up; a second case simulates boot replay.
for recovery_scope in selected boot; do
    reset_case
    printf '%s\n' hold > "$TEST_ROOT/restic-mode"
    start_backup
    wait_for "$TEST_ROOT/restic-entered"
    kill -KILL "$runner_pid"
    wait_backup 137
    [ -f "$STATE_PATH/record" ] || fail 'SIGKILL lost persistent recovery'
    : > "$TEST_ROOT/restic-release"
    wait_for "$TEST_ROOT/restic-stopped"
    printf '%s\n' success > "$TEST_ROOT/restic-mode"
    if [ "$recovery_scope" = selected ]; then
        expect_status 0 recover --group documents
    else
        "$RUNNER" recover >"$TEST_ROOT/result.log" 2>&1
    fi
    grep -Fqx 'documents|post|unknown|recovery' "$EVENTS" || fail 'fresh runner did not recover crash state'
    assert_no_state
done

# One competing group must remain outside Restic throughout PRE, backup, POST.
reset_case
printf '%s\n' hold > "$TEST_ROOT/pre-mode"
printf '%s\n' hold > "$TEST_ROOT/restic-mode"
printf '%s\n' hold > "$TEST_ROOT/post-mode"
start_backup
wait_for "$TEST_ROOT/pre-entered"
PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" run --group other >"$TEST_ROOT/waiter.log" 2>&1 &
waiter_pid=$!
sleep 0.2
kill -0 "$waiter_pid" || fail 'competing group did not wait for PRE'
if grep -qx restic "$EVENTS"; then fail 'backup overlapped PRE'; fi
: > "$TEST_ROOT/pre-release"
wait_for "$TEST_ROOT/restic-entered"
assert_eq 1 "$(grep -cx restic "$EVENTS")" 'lock held during Restic'
: > "$TEST_ROOT/restic-release"
wait_for "$TEST_ROOT/post-entered"
kill -0 "$waiter_pid" || fail 'competing group did not wait for POST'
assert_eq 1 "$(grep -cx restic "$EVENTS")" 'lock held during POST'
: > "$TEST_ROOT/post-release"
wait_backup 0
wait "$waiter_pid"
waiter_pid=''
assert_eq 2 "$(grep -cx restic "$EVENTS")" 'competing group ran after POST'
assert_no_state

printf '%s\n' 'All PW Backup hook and recovery tests passed (runner processes; no systemd PID 1).'
