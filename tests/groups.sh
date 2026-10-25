#!/bin/sh
set -eu

[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'group tests require root in a disposable Debian environment' >&2; exit 1; }
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
RUNNER="$PROJECT_ROOT/files/pw-backup"
CONFIG_ROOT="$TEST_ROOT/config"
SOURCE_DIR="$TEST_ROOT/source"
RESTIC_REPOSITORY="$TEST_ROOT/repository"
RESTIC_PASSWORD_FILE="$TEST_ROOT/password"
RESTIC_CACHE_DIR="$TEST_ROOT/cache"
TEST_RESTIC=$(command -v restic)
TEST_COMMAND_LOG="$TEST_ROOT/commands.log"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR TEST_RESTIC TEST_COMMAND_LOG

fail() { printf 'group test failure: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }
pw() { PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" "$RUNNER" "$@"; }
expect_failure() {
    expected_message=$1
    shift
    if pw "$@" >"$TEST_ROOT/failure.log" 2>&1; then fail "unexpected success: $*"; fi
    grep -Fq "$expected_message" "$TEST_ROOT/failure.log" || { cat "$TEST_ROOT/failure.log" >&2; fail "missing error: $expected_message"; }
}
snapshots() { restic snapshots --json; }
snapshot_ids() { snapshots | jq -c 'map(.id) | sort'; }
count_scope() { snapshots | jq --arg host "$1" --arg tag "$2" '[.[] | select(.hostname == $host and (.tags | index($tag)))] | length'; }
latest_id() { snapshots | jq -r --arg tag "$1" '[.[] | select(.hostname == "machine-a" and (.tags | index($tag)))] | sort_by(.time) | last.id'; }
parent_id() { restic cat snapshot "$1" | jq -r '.parent // empty'; }

mkdir -p "$TEST_ROOT/bin" "$CONFIG_ROOT/groups/documents" "$CONFIG_ROOT/groups/media" "$SOURCE_DIR"
cat > "$TEST_ROOT/bin/restic" <<'RESTIC'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_COMMAND_LOG"
exec "$TEST_RESTIC" "$@"
RESTIC
chmod 0755 "$TEST_ROOT/bin/restic"
PATH="$TEST_ROOT/bin:$PATH"
export PATH
printf '%s\n' 'fictitious-test-password' > "$RESTIC_PASSWORD_FILE"
# Relative sources omit /tmp ancestor metadata, which Restic itself changes
# while creating temporary packs. Both groups still have identical .paths.
printf '%s\n' source > "$CONFIG_ROOT/paths"
cat > "$CONFIG_ROOT/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY='$RESTIC_REPOSITORY'
RESTIC_PASSWORD_FILE='$RESTIC_PASSWORD_FILE'
RESTIC_CACHE_DIR='$RESTIC_CACHE_DIR'
PW_BACKUP_HOST=machine-a
PW_BACKUP_TAG=legacy-test
PW_BACKUP_SKIP_IF_UNCHANGED=false
PW_BACKUP_RETENTION_ENABLED=false
PW_BACKUP_KEEP_LAST=1
PW_BACKUP_PRUNE=false
EOF_CONFIG
for group in documents media; do
    cat > "$CONFIG_ROOT/groups/$group/config.env" <<EOF_CONFIG
RESTIC_REPOSITORY='$RESTIC_REPOSITORY'
RESTIC_PASSWORD_FILE='$RESTIC_PASSWORD_FILE'
RESTIC_CACHE_DIR='$TEST_ROOT/cache-$group'
PW_BACKUP_HOST=machine-a
PW_BACKUP_RETENTION_ENABLED=true
PW_BACKUP_KEEP_LAST=1
PW_BACKUP_PRUNE=false
EOF_CONFIG
    printf '%s\n' source > "$CONFIG_ROOT/groups/$group/paths"
done
sed -i 's/PW_BACKUP_KEEP_LAST=1/PW_BACKUP_KEEP_LAST=2/; s/PW_BACKUP_PRUNE=false/PW_BACKUP_PRUNE=true/' "$CONFIG_ROOT/groups/documents/config.env"
chmod 0600 "$CONFIG_ROOT/config.env" "$CONFIG_ROOT/groups/"*/config.env "$RESTIC_PASSWORD_FILE"
cd "$TEST_ROOT"

pw check-config
pw check-config --group documents
pw restic --group documents init
assert_eq '[]' "$(pw restic snapshots --json | jq -c 'map(.id)')" 'passthrough JSON output'
assert_eq 'pw-backup 0.2.0' "$(pw --version)" 'runner version unchanged'
pw --help | grep -Fq 'run [--group <name>]' || fail 'missing group help'

# The shell expression is deliberately literal input, never evaluated.
# shellcheck disable=SC2016
for group in '' . .. ../documents /documents 'a/b' '-bad' 'UPPER' 'bad name' 'bad;name' 'bad@name' 'bad.name' '$(id)' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    expect_failure 'group name' check-config --group "$group"
done
expect_failure 'usage:' run --group
expect_failure 'usage:' check-config --group documents extra
expect_failure 'missing Restic arguments' restic --group documents
expect_failure 'configuration file is not readable' check-config --group missing
: > "$TEST_COMMAND_LOG"
RUNNER=/usr/local/sbin/pw-backup expect_failure 'configuration file is not readable' run --group missing
[ ! -s "$TEST_COMMAND_LOG" ] || fail 'missing service group configuration reached Restic'

# Ambient legacy values and file overrides must not alter group settings.
PW_BACKUP_TAG=ambient-tag PW_BACKUP_HOST=ambient-host \
PW_BACKUP_KEEP_LAST=99 PW_BACKUP_CONFIG_FILE=/nonexistent \
PW_BACKUP_PATHS_FILE=/nonexistent PW_BACKUP_EXCLUDES_FILE=/nonexistent \
    pw check-config --group documents

mkdir "$CONFIG_ROOT/groups/incomplete"
printf '%s\n' 'PW_BACKUP_HOST=machine-a' > "$CONFIG_ROOT/groups/incomplete/config.env"
expect_failure 'RESTIC_REPOSITORY is empty' check-config --group incomplete
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/incomplete/config.env"
expect_failure 'paths file is not readable' check-config --group incomplete
cp "$CONFIG_ROOT/groups/documents/paths" "$CONFIG_ROOT/groups/incomplete/paths"
sed -i 's/PW_BACKUP_HOST=machine-a/PW_BACKUP_HOST=/' "$CONFIG_ROOT/groups/incomplete/config.env"
PW_BACKUP_HOST=ambient-host expect_failure 'PW_BACKUP_HOST must be explicit' check-config --group incomplete
: > "$TEST_COMMAND_LOG"
RUNNER=/usr/local/sbin/pw-backup expect_failure 'PW_BACKUP_HOST must be explicit' run --group incomplete
[ ! -s "$TEST_COMMAND_LOG" ] || fail 'invalid service group configuration reached Restic'
sed -i "s/PW_BACKUP_HOST=/PW_BACKUP_HOST='   '/" "$CONFIG_ROOT/groups/incomplete/config.env"
expect_failure 'PW_BACKUP_HOST must be explicit' check-config --group incomplete
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/incomplete/config.env"
printf '%s\n' 'PW_BACKUP_TAG=accidental-override' >> "$CONFIG_ROOT/groups/incomplete/config.env"
expect_failure 'PW_BACKUP_TAG is generated' check-config --group incomplete
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/incomplete/config.env"
sed -i '/^PW_BACKUP_KEEP_LAST=/d' "$CONFIG_ROOT/groups/incomplete/config.env"
PW_BACKUP_KEEP_LAST=99 expect_failure 'no keep policy is configured' check-config --group incomplete
cp "$CONFIG_ROOT/groups/documents/config.env" "$CONFIG_ROOT/groups/incomplete/config.env"
chmod 0666 "$CONFIG_ROOT/groups/incomplete/config.env"
expect_failure 'must not be writable by group or others' check-config --group incomplete
rm -rf "$CONFIG_ROOT/groups/incomplete"

# Identical host AND paths: the second group must create its own first snapshot
# even though skip-if-unchanged is enabled and the source has not changed.
printf '%s\n' 'version 1' > "$SOURCE_DIR/document.txt"
# Execute the installed template's asserted ExecStart with an alternate root.
PW_BACKUP_CONFIG_DIR="$CONFIG_ROOT" /usr/local/sbin/pw-backup run --group documents
documents_first=$(latest_id pw-backup-group-documents)
pw run --group media
media_first=$(latest_id pw-backup-group-media)
assert_eq 1 "$(count_scope machine-a pw-backup-group-documents)" 'documents first snapshot'
assert_eq 1 "$(count_scope machine-a pw-backup-group-media)" 'media first snapshot'
assert_eq '' "$(parent_id "$documents_first")" 'documents first parent'
assert_eq '' "$(parent_id "$media_first")" 'media must not select documents as parent'
restic cat snapshot "$documents_first" | jq -e '.tags == ["pw-backup-group-documents"] and .hostname == "machine-a"' >/dev/null
pw run --group documents
pw run --group media
assert_eq 2 "$(snapshots | jq length)" 'unchanged groups must skip independently'

documents_previous=$documents_first
media_previous=$media_first
for version in 2 3; do
    printf 'version %s\n' "$version" > "$SOURCE_DIR/document.txt"
    pw run --group documents
    documents_latest=$(latest_id pw-backup-group-documents)
    assert_eq "$documents_previous" "$(parent_id "$documents_latest")" 'documents parent isolation'
    pw run --group media
    media_latest=$(latest_id pw-backup-group-media)
    assert_eq "$media_previous" "$(parent_id "$media_latest")" 'media parent isolation'
    documents_previous=$documents_latest
    media_previous=$media_latest
done
cp "$SOURCE_DIR/document.txt" "$TEST_ROOT/expected-document"
assert_eq 3 "$(count_scope machine-a pw-backup-group-documents)" 'documents before retention'
assert_eq 3 "$(count_scope machine-a pw-backup-group-media)" 'media before retention'

# Real snapshots with a matching tag on another host, and other tags on the
# matching host, must survive every group policy and the shared prune.
for version in 1 2; do
    printf 'foreign version %s\n' "$version" > "$SOURCE_DIR/document.txt"
    restic backup --quiet --group-by host,paths,tags --host machine-b --tag pw-backup-group-documents "$SOURCE_DIR"
    restic backup --quiet --group-by host,paths,tags --host machine-a --tag unrelated "$SOURCE_DIR"
    restic backup --quiet --group-by host,paths,tags --host machine-a --tag pw-backup-group-unconfigured "$SOURCE_DIR"
done
foreign_ids=$(snapshots | jq -c '[.[] | select(.hostname == "machine-b" or (.tags | index("unrelated")) or (.tags | index("pw-backup-group-unconfigured")))] | map(.id) | sort')
before_ids=$(snapshot_ids)

# Disabled legacy retention must not allow a backup to join a group's history.
for tag in pw-backup-group-documents ordinary,pw-backup-group-documents pw-backup-group-documents,ordinary; do
    sed -i "s/^PW_BACKUP_TAG=.*/PW_BACKUP_TAG=$tag/" "$CONFIG_ROOT/config.env"
    : > "$TEST_COMMAND_LOG"
    expect_failure 'legacy backups cannot use reserved group tags' run
    [ ! -s "$TEST_COMMAND_LOG" ] || fail 'reserved legacy tag reached Restic'
    assert_eq "$before_ids" "$(snapshot_ids)" 'rejected backup changed existing snapshots'
done
assert_eq "$before_ids" "$(pw restic snapshots --json | jq -c 'map(.id) | sort')" 'explicit Restic passthrough remains available'
sed -i 's/^PW_BACKUP_TAG=.*/PW_BACKUP_TAG=legacy-test/' "$CONFIG_ROOT/config.env"

# A later invalid group must stop maintenance BEFORE earlier valid policies.
mkdir "$CONFIG_ROOT/groups/zz-invalid"
printf '%s\n' 'PW_BACKUP_HOST=machine-a' > "$CONFIG_ROOT/groups/zz-invalid/config.env"
: > "$TEST_COMMAND_LOG"
expect_failure 'RESTIC_REPOSITORY is empty' maintenance
if grep -Eq '^(forget|prune) ' "$TEST_COMMAND_LOG"; then fail 'maintenance ran before all groups were validated'; fi
assert_eq "$before_ids" "$(snapshot_ids)" 'invalid group must not change snapshots'
rm -rf "$CONFIG_ROOT/groups/zz-invalid"
mkdir "$CONFIG_ROOT/groups/.invalid"
expect_failure 'invalid group name' maintenance
rm -rf "$CONFIG_ROOT/groups/.invalid"

sed -i 's/PW_BACKUP_PRUNE=false/PW_BACKUP_PRUNE=true/' "$CONFIG_ROOT/groups/media/config.env"
: > "$TEST_COMMAND_LOG"
expect_failure 'multiple prune owners' maintenance
if grep -Eq '^(forget|prune) ' "$TEST_COMMAND_LOG"; then fail 'conflicting prune owners performed maintenance'; fi
assert_eq "$before_ids" "$(snapshot_ids)" 'prune conflict must not change snapshots'
sed -i 's/PW_BACKUP_RETENTION_ENABLED=true/PW_BACKUP_RETENTION_ENABLED=false/' "$CONFIG_ROOT/groups/media/config.env"
expect_failure 'multiple prune owners' maintenance
sed -i 's/PW_BACKUP_RETENTION_ENABLED=false/PW_BACKUP_RETENTION_ENABLED=true/' "$CONFIG_ROOT/groups/media/config.env"
sed -i 's/PW_BACKUP_PRUNE=true/PW_BACKUP_PRUNE=false/' "$CONFIG_ROOT/groups/media/config.env"

sed -i 's/PW_BACKUP_RETENTION_ENABLED=false/PW_BACKUP_RETENTION_ENABLED=true/; s/PW_BACKUP_HOST=machine-a/PW_BACKUP_HOST=/' "$CONFIG_ROOT/config.env"
expect_failure 'legacy retention requires an explicit PW_BACKUP_HOST' maintenance
sed -i 's/PW_BACKUP_HOST=/PW_BACKUP_HOST=machine-a/; s/PW_BACKUP_TAG=legacy-test/PW_BACKUP_TAG=pw-backup-group-documents/' "$CONFIG_ROOT/config.env"
expect_failure 'single, non-group PW_BACKUP_TAG' maintenance
assert_eq "$before_ids" "$(snapshot_ids)" 'unsafe legacy retention must not change snapshots'

# A disabled, unconfigured legacy repository must not block valid groups.
sed -i "s|RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY=|; s/PW_BACKUP_RETENTION_ENABLED=true/PW_BACKUP_RETENTION_ENABLED=false/; s/PW_BACKUP_TAG=pw-backup-group-documents/PW_BACKUP_TAG=legacy-test/" "$CONFIG_ROOT/config.env"
: > "$TEST_COMMAND_LOG"
pw maintenance --dry-run
assert_eq "$before_ids" "$(snapshot_ids)" 'dry-run must preserve exact snapshot IDs'
assert_eq 1 "$(grep -c '^prune --dry-run$' "$TEST_COMMAND_LOG")" 'dry-run has one prune owner'
: > "$TEST_COMMAND_LOG"
pw maintenance
assert_eq 2 "$(grep -c '^forget ' "$TEST_COMMAND_LOG")" 'only enabled group policies run'
assert_eq 1 "$(grep -c '^prune$' "$TEST_COMMAND_LOG")" 'one shared prune'
last_forget=$(awk '/^forget / {line=NR} END {print line}' "$TEST_COMMAND_LOG")
prune_line=$(awk '/^prune$/ {print NR}' "$TEST_COMMAND_LOG")
[ "$prune_line" -gt "$last_forget" ] || fail 'prune ran before all forget policies'
assert_eq 2 "$(count_scope machine-a pw-backup-group-documents)" 'documents retention'
assert_eq 1 "$(count_scope machine-a pw-backup-group-media)" 'media retention independent of documents'
assert_eq "$foreign_ids" "$(snapshots | jq -c '[.[] | select(.hostname == "machine-b" or (.tags | index("unrelated")) or (.tags | index("pw-backup-group-unconfigured")))] | map(.id) | sort')" 'foreign snapshot IDs survived retention and prune'
pw restic --group documents check
pw restic --group documents restore "$documents_latest" --target "$TEST_ROOT/restore"
cmp "$TEST_ROOT/expected-document" "$TEST_ROOT/restore/source/document.txt" || fail 'restore after retention and prune differs'

# Explicitly filtered legacy retention can coexist with group policies.
sed -i "s|RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY='$RESTIC_REPOSITORY'|; s/PW_BACKUP_RETENTION_ENABLED=false/PW_BACKUP_RETENTION_ENABLED=true/" "$CONFIG_ROOT/config.env"
pw run
printf '%s\n' 'legacy version 2' > "$SOURCE_DIR/document.txt"
pw run
pw retention --dry-run
pw maintenance
assert_eq 1 "$(count_scope machine-a legacy-test)" 'safe legacy retention with groups'
assert_eq 2 "$(count_scope machine-a pw-backup-group-documents)" 'legacy retention preserved documents'
assert_eq 1 "$(count_scope machine-a pw-backup-group-media)" 'legacy retention preserved media'
assert_eq "$foreign_ids" "$(snapshots | jq -c '[.[] | select(.hostname == "machine-b" or (.tags | index("unrelated")) or (.tags | index("pw-backup-group-unconfigured")))] | map(.id) | sort')" 'safe legacy retention preserved foreign snapshots'

# The legacy scope participates in the same prune-owner conflict check.
before_ids=$(snapshot_ids)
sed -i 's/PW_BACKUP_PRUNE=false/PW_BACKUP_PRUNE=true/' "$CONFIG_ROOT/config.env"
expect_failure 'multiple prune owners' maintenance
assert_eq "$before_ids" "$(snapshot_ids)" 'legacy/group prune conflict must preserve snapshots'
sed -i 's/PW_BACKUP_PRUNE=true/PW_BACKUP_PRUNE=false/' "$CONFIG_ROOT/config.env"

# Different repositories may each have an owner. This also exercises changing
# repository environments between policies without leaking the previous scope.
mkdir "$CONFIG_ROOT/groups/archives"
sed "s|RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY='$TEST_ROOT/other-repository'|" \
    "$CONFIG_ROOT/groups/documents/config.env" > "$CONFIG_ROOT/groups/archives/config.env"
cp "$CONFIG_ROOT/groups/documents/paths" "$CONFIG_ROOT/groups/archives/paths"
pw restic --group archives init
pw run --group archives
: > "$TEST_COMMAND_LOG"
pw maintenance
assert_eq 2 "$(grep -c '^prune$' "$TEST_COMMAND_LOG")" 'one prune owner per distinct repository'
assert_eq 1 "$(pw restic --group archives snapshots --json | jq length)" 'independent repository snapshot'
pw restic --group archives check
assert_eq "$foreign_ids" "$(snapshots | jq -c '[.[] | select(.hostname == "machine-b" or (.tags | index("unrelated")) or (.tags | index("pw-backup-group-unconfigured")))] | map(.id) | sort')" 'multiple repository maintenance preserved foreign snapshots'

printf '%s\n' 'All PW Backup group tests passed.'
