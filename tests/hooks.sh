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
    if [ "$#" -ge 3 ]; then printf "PW_BACKUP_EMAIL_TO='%s'\n" "$3" >> "$CONFIG_ROOT/groups/documents/config.env"; fi
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
        failed) printf '%s\n' 'fictitious-private-restic-output' >&2; exit 42 ;;
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
case "$1:$(cat "$TEST_HOOK_ROOT/restic-mode")" in
    forget:forget-failed) exit 43 ;;
    prune:prune-failed) exit 44 ;;
esac
exec "$TEST_REAL_RESTIC" "$@"
RESTIC
cat > "$TEST_ROOT/bin/timeout" <<'TIMEOUT'
#!/bin/sh
set -eu
if [ "$1" = --kill-after=5s ]; then
    [ "$2" = 30s ]
    if [ "$(cat "$TEST_HOOK_ROOT/mail-mode")" = hold ]; then
        shift 2
        exec "$TEST_REAL_TIMEOUT" --kill-after=0.2s 0.2s "$@"
    fi
    exec "$TEST_REAL_TIMEOUT" "$@"
fi
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
    failed) printf '%s\n' 'fictitious-private-pre-output' >&2; exit 21 ;;
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
    failed) printf '%s\n' 'fictitious-private-post-output' >&2; exit 23 ;;
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

# An inspection error must not be mistaken for an empty directory at uninstall.
TEST_REAL_FIND=$(command -v find)
export TEST_REAL_FIND
cat > "$TEST_ROOT/bin/find" <<'FIND'
#!/bin/sh
if [ "$1" = /var/lib/pw-backup/pending ] && [ "$2" = -mindepth ]; then exit 1; fi
exec "$TEST_REAL_FIND" "$@"
FIND
chmod 0755 "$TEST_ROOT/bin/find"
if "$PROJECT_ROOT/uninstall.sh" --purge >"$TEST_ROOT/result.log" 2>&1; then fail 'uninstall accepted unreadable recovery state'; fi
grep -Fq 'cannot inspect recovery state' "$TEST_ROOT/result.log" || fail 'uninstall ignored inspection failure'
expect_error 'cannot inspect pending recovery' recover
[ -f "$STATE_PATH/record" ] || fail 'inspection failure lost pending state'
rm "$TEST_ROOT/bin/find"

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

# Email tests use only this fixture, never a system MTA or an external address.
{
    printf '#!/bin/sh\nset -eu\nfixture=%s\n' "'$TEST_ROOT'"
    cat <<'SENDMAIL'
[ "${RESTIC_REPOSITORY+x}" != x ] || exit 92
[ "$*" = '-t -i' ] || exit 93
count=$(cat "$fixture/mail-count")
count=$((count + 1))
printf '%s\n' "$count" > "$fixture/mail-count"
cat > "$fixture/message-$count"
printf '%s\n' mail >> "$fixture/events"
case "$(cat "$fixture/mail-mode")" in
    failed) exit 67 ;;
    hold) sleep 60 ;;
esac
SENDMAIL
} > "$TEST_ROOT/bin/sendmail"
chmod 0755 "$TEST_ROOT/bin/sendmail"
reset_mail() {
    reset_case
    rm -f "$TEST_ROOT"/message-*
    printf '%s\n' 0 > "$TEST_ROOT/mail-count"
    printf '%s\n' success > "$TEST_ROOT/mail-mode"
}
assert_mail() {
    assert_eq "$1" "$(cat "$TEST_ROOT/mail-count")" 'number of email submissions'
    mail_message="$TEST_ROOT/message-$1"
    grep -Fxq "Severity: $2" "$mail_message" || fail 'wrong email severity'
    grep -Fxq "Operation: $3" "$mail_message" || fail 'wrong email operation'
    grep -Fxq "Group: $4" "$mail_message" || fail 'wrong email group'
    grep -Fxq "To: $5" "$mail_message" || fail 'wrong email recipient'
    grep -Fxq "Exit code: $6" "$mail_message" || fail 'wrong email exit code'
    if grep -Eq 'fictitious-private|fictitious-hook-test-password|RESTIC_|repository|/tmp/|Bcc:' "$mail_message"; then
        fail 'email leaked private values or injected content'
    fi
}

reset_mail
write_config '' ''
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
expect_status 42 run --group documents
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'absent email setting'
write_config '' '' ''
expect_status 42 run --group documents
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'empty email setting'
PW_BACKUP_EMAIL_TO=ambient@example.invalid expect_status 42 run --group documents
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'groups must not inherit recipients'

for recipient in 'alerts@example.invalid' 'backup+alerts@example.invalid'; do
    write_config '' '' "$recipient"
    expect_status 0 check-config --group documents
done
for recipient in 'bad' 'a@@example.invalid' 'a b@example.invalid' 'a@example.invalid,b@example.invalid' \
    '-option@example.invalid' 'a@example.invalid/secret' "$(printf 'a@example.invalid\nBcc: injected@example.invalid')" \
    "$(printf 'a@example.invalid\rBcc: injected@example.invalid')" "$(printf 'a@example.invalid\t')" \
    "$(printf 'a@example.invalid\001')"; do
    write_config '' '' "$recipient"
    expect_error 'PW_BACKUP_EMAIL_TO must be a single plain email address' check-config --group documents
done
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'validation must not send email'

write_config '' '' alerts@example.invalid
reset_mail
expect_status 0 run --group documents
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'INFO must not send email'
grep -Fq 'INFO: backup completed' "$TEST_ROOT/result.log" || fail 'missing ordinary success log'
expect_status 0 check-config --group documents
expect_status 0 restic --group documents snapshots --json
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'administrative commands sent email'
for restic_failure in failed incomplete; do
    reset_mail
    printf '%s\n' "$restic_failure" > "$TEST_ROOT/restic-mode"
    if [ "$restic_failure" = failed ]; then expected_restic_exit=42; else expected_restic_exit=3; fi
    expect_status "$expected_restic_exit" run --group documents
    assert_mail 1 CRITICAL backup documents alerts@example.invalid "$expected_restic_exit"
    assert_no_state
done
reset_mail
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
expect_status 42 restic --group documents backup source
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'explicit Restic passthrough sent email'

# Legacy supports its own recipient; independent groups retain their settings.
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/config.env"
reset_mail
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
expect_status 42 run
assert_mail 1 CRITICAL backup legacy alerts@example.invalid 42
write_config '' '' alerts@example.invalid
printf "PW_BACKUP_HOST='machine-a\nBcc: injected@example.invalid'\n" >> "$CONFIG_ROOT/groups/documents/config.env"
reset_mail
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
expect_status 42 run --group documents
assert_mail 1 CRITICAL backup documents alerts@example.invalid 42
grep -Fxq 'Host: unavailable' "$TEST_ROOT/message-1" || fail 'unsafe host was not normalized'

write_config "$TEST_ROOT/pre.sh" "$TEST_ROOT/post.sh" alerts@example.invalid
for failed_stage in pre restic; do
    reset_mail
    printf '%s\n' failed > "$TEST_ROOT/$failed_stage-mode"
    if [ "$failed_stage" = pre ]; then stage_exit=21; else stage_exit=42; fi
    expect_status "$stage_exit" run --group documents
    assert_mail 1 CRITICAL backup documents alerts@example.invalid "$stage_exit"
    assert_eq mail "$(tail -n 1 "$EVENTS")" 'notification must follow POST'
    assert_no_state
done

reset_mail
printf '%s\n' failed > "$TEST_ROOT/restic-mode"
printf '%s\n' failed > "$TEST_ROOT/post-mode"
expect_status 42 run --group documents
assert_mail 1 CRITICAL backup documents alerts@example.invalid 42
grep -Fq 'Restic and POST cleanup failed' "$TEST_ROOT/message-1" || fail 'combined failure was lost'
[ -f "$STATE_PATH/record" ] || fail 'pending cleanup record missing'
[ -f "$STATE_PATH/notified" ] || fail 'pending notification flag missing'
record_sum=$(sha256sum "$STATE_PATH/record")
expect_status 1 recover --group documents
SERVICE_RESULT=exit-code expect_status 1 recover --group documents
assert_eq 1 "$(cat "$TEST_ROOT/mail-count")" 'ExecStopPost/repeated recovery duplicated the alert'
assert_eq "$record_sum" "$(sha256sum "$STATE_PATH/record")" 'notification changed the cleanup record'
printf '%s\n' success > "$TEST_ROOT/post-mode"
expect_status 0 recover --group documents
expect_status 0 recover --group documents
assert_eq 1 "$(cat "$TEST_ROOT/mail-count")" 'successful recovery sent email'
assert_no_state

# Failed submission leaves the pending record untouched and writes no flag.
reset_mail
printf '%s\n' failed > "$TEST_ROOT/post-mode"
printf '%s\n' failed > "$TEST_ROOT/mail-mode"
expect_status 1 run --group documents
[ -f "$STATE_PATH/record" ] || fail 'failed email lost recovery state'
[ ! -e "$STATE_PATH/notified" ] || fail 'failed email created a notification flag'
record_sum=$(sha256sum "$STATE_PATH/record")
assert_mail 1 CRITICAL backup documents alerts@example.invalid 1
grep -Fq 'POST cleanup failed' "$TEST_ROOT/message-1" || fail 'wrong POST-only failure description'
grep -Fq 'sendmail submission failed (exit code 67)' "$TEST_ROOT/result.log" || fail 'missing sendmail error log'
printf '%s\n' success > "$TEST_ROOT/mail-mode"
expect_status 1 recover --group documents
assert_mail 2 CRITICAL recovery documents alerts@example.invalid 1
assert_eq "$record_sum" "$(sha256sum "$STATE_PATH/record")" 'recovery email changed the record'
expect_status 1 run --group documents
assert_eq 2 "$(cat "$TEST_ROOT/mail-count")" 'blocked backup duplicated recovery email'
cp "$CONFIG_ROOT/groups/documents/config.env" "$TEST_ROOT/email-config-saved"
printf '%s\n' '# changed while pending' >> "$CONFIG_ROOT/groups/documents/config.env"
expect_error 'configuration changed' recover --group documents
assert_eq 2 "$(cat "$TEST_ROOT/mail-count")" 'changed configuration invented a recipient'
cp "$TEST_ROOT/email-config-saved" "$CONFIG_ROOT/groups/documents/config.env"
printf '%s\n' success > "$TEST_ROOT/post-mode"
expect_status 0 recover
assert_no_state

write_config '' '' alerts@example.invalid
for mail_failure in failed hold missing; do
    reset_mail
    printf '%s\n' failed > "$TEST_ROOT/restic-mode"
    printf '%s\n' "$mail_failure" > "$TEST_ROOT/mail-mode"
    if [ "$mail_failure" = missing ]; then
        mv "$TEST_ROOT/bin/sendmail" "$TEST_ROOT/sendmail.saved"
        if command -v sendmail >/dev/null 2>&1; then fail 'missing-MTA test refuses to use a real sendmail'; fi
    fi
    expect_status 42 run --group documents
    if [ "$mail_failure" = missing ]; then
        mv "$TEST_ROOT/sendmail.saved" "$TEST_ROOT/bin/sendmail"
        assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'missing MTA was invoked'
        grep -Fq 'sendmail is unavailable' "$TEST_ROOT/result.log" || fail 'missing absent-MTA log'
    else
        assert_eq 1 "$(cat "$TEST_ROOT/mail-count")" 'email failure caused retries'
        grep -Fq 'sendmail submission failed' "$TEST_ROOT/result.log" || fail 'missing failed-MTA log'
        if [ "$mail_failure" = hold ]; then
            grep -Fq 'exit code 124' "$TEST_ROOT/result.log" || fail 'mail timeout was not bounded'
        fi
    fi
    assert_no_state
done

# Notification-enabled supervision retains the signal exit code too.
reset_mail
printf '%s\n' hold > "$TEST_ROOT/restic-mode"
start_backup
wait_for "$TEST_ROOT/restic-entered"
kill -TERM "$runner_pid"
wait_backup 143
assert_mail 1 CRITICAL backup documents alerts@example.invalid 143
assert_no_state

# Scope-specific maintenance and the single prune owner use their recipients.
mv "$CONFIG_ROOT/groups" "$TEST_ROOT/groups-saved"
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=true' 'PW_BACKUP_KEEP_LAST=1' >> "$CONFIG_ROOT/config.env"
reset_mail
printf '%s\n' forget-failed > "$TEST_ROOT/restic-mode"
expect_status 43 maintenance
assert_mail 1 CRITICAL maintenance legacy alerts@example.invalid 43
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=false' >> "$CONFIG_ROOT/config.env"
mv "$TEST_ROOT/groups-saved" "$CONFIG_ROOT/groups"
write_config '' '' alerts@example.invalid
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=true' 'PW_BACKUP_KEEP_LAST=1' >> "$CONFIG_ROOT/groups/documents/config.env"
reset_mail
printf '%s\n' forget-failed > "$TEST_ROOT/restic-mode"
expect_status 43 maintenance
assert_mail 1 CRITICAL maintenance documents alerts@example.invalid 43
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/other/config.env"
sed -i 's/alerts@example.invalid/other@example.invalid/' "$CONFIG_ROOT/groups/other/config.env"
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=false' >> "$CONFIG_ROOT/groups/documents/config.env"
reset_mail
printf '%s\n' forget-failed > "$TEST_ROOT/restic-mode"
expect_status 43 maintenance --dry-run
assert_mail 1 CRITICAL maintenance other other@example.invalid 43
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=false' >> "$CONFIG_ROOT/groups/other/config.env"
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=true' 'PW_BACKUP_PRUNE=true' >> "$CONFIG_ROOT/groups/documents/config.env"
reset_mail
printf '%s\n' prune-failed > "$TEST_ROOT/restic-mode"
expect_status 44 maintenance
assert_mail 1 CRITICAL prune documents alerts@example.invalid 44
reset_mail
expect_status 0 maintenance --dry-run
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'successful maintenance sent email'

TEST_REAL_FLOCK=$(command -v flock)
export TEST_REAL_FLOCK
cat > "$TEST_ROOT/bin/flock" <<'FLOCK'
#!/bin/sh
[ "$1" = -w ] && [ "$2" = 300 ] && [ "$3" = 9 ] || exit 94
exec "$TEST_REAL_FLOCK" -w 0.2 9
FLOCK
chmod 0755 "$TEST_ROOT/bin/flock"
exec 8>/run/pw-backup/operation.lock
"$TEST_REAL_FLOCK" 8
reset_mail
expect_status 1 run --group documents
assert_mail 1 WARNING backup documents alerts@example.invalid 1
printf '%s\n' 'PW_BACKUP_PRUNE=false' >> "$CONFIG_ROOT/groups/documents/config.env"
printf '%s\n' 'PW_BACKUP_RETENTION_ENABLED=true' >> "$CONFIG_ROOT/groups/other/config.env"
reset_mail
expect_status 1 maintenance
assert_eq 2 "$(cat "$TEST_ROOT/mail-count")" 'lock timeout did not notify each enabled group'
grep -Fxq 'To: alerts@example.invalid' "$TEST_ROOT/message-1" || fail 'wrong first maintenance recipient'
assert_mail 2 WARNING maintenance other other@example.invalid 1
chmod 0777 "$CONFIG_ROOT/groups"
reset_mail
expect_status 1 run --group documents
assert_eq 0 "$(cat "$TEST_ROOT/mail-count")" 'unsafe lock lookup executed configuration'
chmod 0755 "$CONFIG_ROOT/groups"
"$TEST_REAL_FLOCK" -u 8
exec 8>&-
rm "$TEST_ROOT/bin/flock"

printf '%s\n' 'All PW Backup email tests passed (fixture sendmail only).'
printf '%s\n' 'All PW Backup hook and recovery tests passed (runner processes; no systemd PID 1).'
