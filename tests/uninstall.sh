#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(id -u)" -eq 0 ] || { printf '%s\n' 'uninstall tests require root in a disposable Debian environment' >&2; exit 1; }
TEST_ROOT=$(mktemp -d)
ORIGINAL_PATH=$PATH

cleanup() {
    rm -rf "$TEST_ROOT" /etc/pw-backup /var/cache/pw-backup /var/lib/pw-backup
    rm -rf /etc/systemd/system/pw-backup*.d
    rm -f /usr/local/sbin/pw-backup /usr/local/sbin/pw-backup-uninstall
    rm -f /etc/systemd/system/pw-backup.service /etc/systemd/system/pw-backup.timer
    rm -f /etc/systemd/system/pw-backup-maintenance.service /etc/systemd/system/pw-backup-maintenance.timer
    rm -f /etc/systemd/system/pw-backup-recover.service
    rm -f /etc/systemd/system/pw-backup@*.service /etc/systemd/system/pw-backup@*.timer
    find /etc/systemd/system -type l \
        \( -name 'pw-backup.service' -o -name 'pw-backup.timer' \
           -o -name 'pw-backup-maintenance.service' -o -name 'pw-backup-maintenance.timer' \
           -o -name 'pw-backup@*.service' -o -name 'pw-backup@*.timer' \
           -o -name 'pw-backup-recover.service' \) -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'uninstall test failure: %s\n' "$*" >&2; exit 1; }
assert_absent() {
    if [ -e "$1" ] || [ -L "$1" ]; then fail "path still exists: $1"; fi
}

[ "$(id -u)" -eq 0 ] || fail 'tests require root'
cd "$PROJECT_ROOT"
sh -n uninstall.sh

mkdir -p "$TEST_ROOT/bin" /run/systemd/system
cat > "$TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    list-units)
        [ "$SYSTEMCTL_FAILURE" != list-units ] || exit 1
        [ "$SYSTEMCTL_FAILURE" != absent ] || exit 0
        printf '%s\n' 'pw-backup@active.service loaded active running' 'pw-backup@active.timer loaded active waiting'
        ;;
    list-unit-files)
        [ "$SYSTEMCTL_FAILURE" != list-unit-files ] || exit 1
        [ "$SYSTEMCTL_FAILURE" != absent ] || exit 0
        printf '%s\n' 'pw-backup@disabled.timer disabled' 'pw-backup@.timer disabled'
        ;;
    show)
        if [ "$SYSTEMCTL_FAILURE" = absent ]; then
            printf '%s\n' 'LoadState=not-found' 'ActiveState=inactive'
        elif [ "$2" = "$SYSTEMCTL_FAILURE_UNIT" ] && [ "$SYSTEMCTL_FAILURE" = query-error ]; then
            # Even apparent not-found output is untrusted when the query fails.
            printf '%s\n' 'LoadState=not-found' 'ActiveState=inactive'
            exit 1
        elif [ "$2" = "$SYSTEMCTL_FAILURE_UNIT" ] && [ "$SYSTEMCTL_FAILURE" = missing-state ]; then
            printf '%s\n' 'LoadState=loaded'
        elif [ "$2" = "$SYSTEMCTL_FAILURE_UNIT" ] && [ "$SYSTEMCTL_FAILURE" = verification-error ] && \
                [ -f "$SYSTEMCTL_STATE_DIR/$2" ]; then
            exit 1
        else
            active_state=active
            if [ -f "$SYSTEMCTL_STATE_DIR/$2" ]; then
                active_state=inactive
                if [ "$2" = "$SYSTEMCTL_FAILURE_UNIT" ]; then
                    case "$SYSTEMCTL_FAILURE" in
                        active|activating|deactivating) active_state=$SYSTEMCTL_FAILURE ;;
                    esac
                fi
            fi
            printf '%s\n' 'LoadState=loaded' "ActiveState=$active_state"
        fi
        ;;
    stop|disable)
        if [ "$SYSTEMCTL_FAILURE" = "$1" ] && [ "$2" = "$SYSTEMCTL_FAILURE_UNIT" ]; then
            printf 'simulated systemctl %s failure: %s\n' "$1" "$2" >&2
            exit 1
        fi
        if [ "$1" = stop ]; then : > "$SYSTEMCTL_STATE_DIR/$2"; fi
        ;;
esac
exit 0
SYSTEMCTL
chmod 0755 "$TEST_ROOT/bin/systemctl"
export SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
export SYSTEMCTL_STATE_DIR="$TEST_ROOT/systemctl-state"
export SYSTEMCTL_FAILURE=none SYSTEMCTL_FAILURE_UNIT=
mkdir -p "$SYSTEMCTL_STATE_DIR"
PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
export PATH

./install.sh > "$TEST_ROOT/install.log"
[ -x /usr/local/sbin/pw-backup-uninstall ] || fail 'uninstaller was not installed'
[ -f /etc/systemd/system/pw-backup@.service ] || fail 'group service template was not installed'
[ -f /etc/systemd/system/pw-backup@.timer ] || fail 'group timer template was not installed'
[ -f /etc/systemd/system/pw-backup-recover.service ] || fail 'recovery service was not installed'
if grep -Eq '(^| )(enable|start|restart)( |$)' "$SYSTEMCTL_LOG"; then
    fail 'installer enabled or started a unit automatically'
fi
printf '%s\n' '# preserve me' >> /etc/pw-backup/config.env
config_sum=$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')
mkdir -p /etc/pw-backup/groups/documents
printf '%s\n' '# fictitious group configuration to preserve' > /etc/pw-backup/groups/documents/config.env
printf '%s\n' '/srv/example/documents' > /etc/pw-backup/groups/documents/paths
group_config_sum=$(sha256sum /etc/pw-backup/groups/documents/config.env | awk '{print $1}')
group_paths_sum=$(sha256sum /etc/pw-backup/groups/documents/paths | awk '{print $1}')

mkdir -p /etc/systemd/system/pw-backup.service.d \
    /etc/systemd/system/pw-backup.timer.d \
    /etc/systemd/system/pw-backup@.service.d \
    /etc/systemd/system/pw-backup@.timer.d \
    /etc/systemd/system/pw-backup@documents.service.d \
    /etc/systemd/system/pw-backup@documents.timer.d \
    /etc/systemd/system/timers.target.wants \
    /etc/systemd/system/multi-user.target.wants
: > /etc/systemd/system/pw-backup.service.d/override.conf
: > /etc/systemd/system/pw-backup.timer.d/override.conf
: > /etc/systemd/system/pw-backup@.service.d/override.conf
: > /etc/systemd/system/pw-backup@.timer.d/override.conf
: > /etc/systemd/system/pw-backup@documents.service.d/override.conf
: > /etc/systemd/system/pw-backup@documents.timer.d/override.conf
ln -s /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/timers.target.wants/pw-backup.timer
ln -s /etc/systemd/system/pw-backup@.timer \
    /etc/systemd/system/timers.target.wants/pw-backup@documents.timer
ln -s /etc/systemd/system/pw-backup@.service \
    /etc/systemd/system/pw-backup@documents.service
ln -s /etc/systemd/system/pw-backup@.service \
    /etc/systemd/system/multi-user.target.wants/pw-backup@documents.service

# Snapshot files, directories, permissions and enablement links before failures.
installation_snapshot() {
    set -- /etc/pw-backup /var/cache/pw-backup /var/lib/pw-backup \
        /usr/local/sbin/pw-backup /usr/local/sbin/pw-backup-uninstall \
        /etc/systemd/system/pw-backup* \
        /etc/systemd/system/timers.target.wants/pw-backup* \
        /etc/systemd/system/multi-user.target.wants/pw-backup*
    find "$@" -printf '%y %m %u %g %p %l\n' > "$TEST_ROOT/snapshot"
    find "$@" -type f -exec sha256sum {} + >> "$TEST_ROOT/snapshot"
    LC_ALL=C sort "$TEST_ROOT/snapshot"
}
printf '%s\n' 'fictitious cache data' > /var/cache/pw-backup/preserve-test
printf '%s\n' 'fictitious state data' > /var/lib/pw-backup/preserve-test
mkdir -p /var/lib/pw-backup/pending
installation_snapshot > "$TEST_ROOT/installed.snapshot"
for fault in group-stop timer-stop timer-disable list-units list-unit-files \
    query-error missing-state verification-error active activating deactivating
do
    SYSTEMCTL_FAILURE_UNIT=pw-backup@active.service
    SYSTEMCTL_FAILURE=$fault
    case "$fault" in
        group-stop) SYSTEMCTL_FAILURE=stop; diagnostic='could not stop pw-backup@active.service' ;;
        timer-stop) SYSTEMCTL_FAILURE=stop; SYSTEMCTL_FAILURE_UNIT=pw-backup@active.timer
            diagnostic='could not stop pw-backup@active.timer' ;;
        timer-disable) SYSTEMCTL_FAILURE=disable; SYSTEMCTL_FAILURE_UNIT=pw-backup@active.timer
            diagnostic='could not disable pw-backup@active.timer' ;;
        list-units) diagnostic='cannot list group units' ;;
        list-unit-files) diagnostic='cannot list group unit files' ;;
        query-error|verification-error) diagnostic='cannot verify systemd state for pw-backup@active.service' ;;
        missing-state) diagnostic='missing active state for pw-backup@active.service' ;;
        *) diagnostic="pw-backup@active.service is not stopped (state: $fault)" ;;
    esac
    for option in conservative purge; do
        rm -rf "$SYSTEMCTL_STATE_DIR"
        mkdir -p "$SYSTEMCTL_STATE_DIR"
        set --
        if [ "$option" = purge ]; then set -- --purge; fi
        if /usr/local/sbin/pw-backup-uninstall "$@" > "$TEST_ROOT/failure.log" 2>&1; then
            fail "$option uninstall accepted systemctl failure: $fault"
        fi
        grep -Fq "$diagnostic" "$TEST_ROOT/failure.log" || fail "missing diagnostic for $fault"
        installation_snapshot > "$TEST_ROOT/after-failure.snapshot"
        cmp -s "$TEST_ROOT/installed.snapshot" "$TEST_ROOT/after-failure.snapshot" || \
            fail "$option uninstall changed installed files after $fault"
    done
done
printf '%s\n' 'Fail-closed uninstall tests passed (conservative and purge).'
SYSTEMCTL_FAILURE=none
rm -rf "$SYSTEMCTL_STATE_DIR"
mkdir -p "$SYSTEMCTL_STATE_DIR"
: > "$SYSTEMCTL_LOG"
/usr/local/sbin/pw-backup-uninstall > "$TEST_ROOT/uninstall.log"
[ -d /etc/pw-backup ] || fail 'configuration was removed without --purge'
[ "$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')" = "$config_sum" ] || \
    fail 'configuration changed during conservative uninstall'
[ "$(sha256sum /etc/pw-backup/groups/documents/config.env | awk '{print $1}')" = "$group_config_sum" ] || fail 'group configuration changed during conservative uninstall'
[ "$(sha256sum /etc/pw-backup/groups/documents/paths | awk '{print $1}')" = "$group_paths_sum" ] || fail 'group paths changed during conservative uninstall'

for path in \
    /usr/local/sbin/pw-backup \
    /usr/local/sbin/pw-backup-uninstall \
    /etc/systemd/system/pw-backup.service \
    /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/pw-backup-maintenance.service \
    /etc/systemd/system/pw-backup-maintenance.timer \
    /etc/systemd/system/pw-backup-recover.service \
    /etc/systemd/system/pw-backup@.service \
    /etc/systemd/system/pw-backup@.timer \
    /etc/systemd/system/pw-backup@documents.service \
    /etc/systemd/system/pw-backup@.service.d \
    /etc/systemd/system/pw-backup@.timer.d \
    /etc/systemd/system/pw-backup@documents.service.d \
    /etc/systemd/system/pw-backup@documents.timer.d \
    /etc/systemd/system/timers.target.wants/pw-backup@documents.timer \
    /etc/systemd/system/multi-user.target.wants/pw-backup@documents.service \
    /etc/systemd/system/pw-backup.service.d \
    /etc/systemd/system/pw-backup.timer.d \
    /etc/systemd/system/timers.target.wants/pw-backup.timer \
    /var/cache/pw-backup \
    /var/lib/pw-backup
do
    assert_absent "$path"
done

grep -Fqx 'stop pw-backup.timer' "$SYSTEMCTL_LOG" || fail 'timer was not stopped'
grep -Fqx 'disable pw-backup.timer' "$SYSTEMCTL_LOG" || fail 'timer was not disabled'
grep -Fqx 'stop pw-backup.service' "$SYSTEMCTL_LOG" || fail 'service was not stopped'
grep -Fqx 'stop pw-backup-recover.service' "$SYSTEMCTL_LOG" || fail 'recovery service was not stopped'
grep -Fqx 'daemon-reload' "$SYSTEMCTL_LOG" || fail 'systemd was not reloaded'
grep -Fqx 'disable pw-backup@documents.timer' "$SYSTEMCTL_LOG" || fail 'enabled group timer was not disabled'
grep -Fqx 'stop pw-backup@documents.service' "$SYSTEMCTL_LOG" || fail 'on-disk group service was not stopped'
grep -Fqx 'stop pw-backup@active.service' "$SYSTEMCTL_LOG" || fail 'active group instance was not stopped'
grep -Fqx 'disable pw-backup@active.timer' "$SYSTEMCTL_LOG" || fail 'active group timer was not disabled'
grep -Fqx 'disable pw-backup@disabled.timer' "$SYSTEMCTL_LOG" || fail 'disabled group instance was not handled'
last_timer_stop=$(awk '/^stop .*\.timer$/ {line=NR} END {print line}' "$SYSTEMCTL_LOG")
first_service_stop=$(awk '/^stop .*\.service$/ {print NR; exit}' "$SYSTEMCTL_LOG")
[ "$last_timer_stop" -lt "$first_service_stop" ] || fail 'services stopped before all timers were stopped'
last_stop=$(awk '/^stop / {line=NR} END {print line}' "$SYSTEMCTL_LOG")
first_disable=$(awk '/^disable / {print NR; exit}' "$SYSTEMCTL_LOG")
[ "$last_stop" -lt "$first_disable" ] || fail 'enablement links removed before all units were stopped'
command -v restic >/dev/null 2>&1 || fail 'restic package was unexpectedly removed'

./install.sh > "$TEST_ROOT/reinstall.log"
[ "$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')" = "$config_sum" ] || \
    fail 'configuration was not preserved across reinstall'
[ "$(sha256sum /etc/pw-backup/groups/documents/config.env | awk '{print $1}')" = "$group_config_sum" ] || fail 'group configuration was not preserved across reinstall'
[ "$(sha256sum /etc/pw-backup/groups/documents/paths | awk '{print $1}')" = "$group_paths_sum" ] || fail 'group paths were not preserved across reinstall'
[ ! -e /etc/pw-backup/groups/documents/repository-password ] || fail 'installer copied group credentials'
/usr/local/sbin/pw-backup-uninstall --purge > "$TEST_ROOT/purge.log"
assert_absent /etc/pw-backup
assert_absent /usr/local/sbin/pw-backup
assert_absent /usr/local/sbin/pw-backup-uninstall
assert_absent /etc/systemd/system/pw-backup.service
assert_absent /etc/systemd/system/pw-backup.timer
assert_absent /etc/systemd/system/pw-backup-maintenance.service
assert_absent /etc/systemd/system/pw-backup-maintenance.timer
assert_absent /etc/systemd/system/pw-backup-recover.service
assert_absent /etc/systemd/system/pw-backup@.service
assert_absent /etc/systemd/system/pw-backup@.timer
assert_absent /var/cache/pw-backup
assert_absent /var/lib/pw-backup
command -v restic >/dev/null 2>&1 || fail 'restic package was removed by purge'

SYSTEMCTL_FAILURE=absent
: > "$SYSTEMCTL_LOG"
./uninstall.sh > "$TEST_ROOT/uninstall-second.log"
./uninstall.sh --purge > "$TEST_ROOT/purge-second.log"
grep -Fq 'show pw-backup.service ' "$SYSTEMCTL_LOG" || fail 'absent unit state was not checked'
if grep -Eq '^(stop|disable) ' "$SYSTEMCTL_LOG"; then fail 'uninstaller tried to stop or disable absent units'; fi
printf '%s\n' 'All PW Backup uninstall tests passed.'
