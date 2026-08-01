#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
ORIGINAL_PATH=$PATH

cleanup() {
    rm -rf "$TEST_ROOT" /etc/pw-backup /var/cache/pw-backup /var/lib/pw-backup
    rm -rf /etc/systemd/system/pw-backup.service.d /etc/systemd/system/pw-backup.timer.d
    rm -f /usr/local/sbin/pw-backup /usr/local/sbin/pw-backup-uninstall
    rm -f /etc/systemd/system/pw-backup.service /etc/systemd/system/pw-backup.timer
    find /etc/systemd/system -type l \
        \( -name 'pw-backup.service' -o -name 'pw-backup.timer' \) -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'uninstall test failure: %s\n' "$*" >&2; exit 1; }
assert_absent() { [ ! -e "$1" ] || fail "path still exists: $1"; }

[ "$(id -u)" -eq 0 ] || fail 'tests require root'
cd "$PROJECT_ROOT"
sh -n uninstall.sh

mkdir -p "$TEST_ROOT/bin" /run/systemd/system
cat > "$TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod 0755 "$TEST_ROOT/bin/systemctl"
export SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"
PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
export PATH

./install.sh > "$TEST_ROOT/install.log"
[ -x /usr/local/sbin/pw-backup-uninstall ] || fail 'uninstaller was not installed'
printf '%s\n' '# preserve me' >> /etc/pw-backup/config.env
config_sum=$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')

mkdir -p /etc/systemd/system/pw-backup.service.d \
    /etc/systemd/system/pw-backup.timer.d \
    /etc/systemd/system/timers.target.wants
: > /etc/systemd/system/pw-backup.service.d/override.conf
: > /etc/systemd/system/pw-backup.timer.d/override.conf
ln -s /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/timers.target.wants/pw-backup.timer

/usr/local/sbin/pw-backup-uninstall > "$TEST_ROOT/uninstall.log"
[ -d /etc/pw-backup ] || fail 'configuration was removed without --purge'
[ "$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')" = "$config_sum" ] || \
    fail 'configuration changed during conservative uninstall'

for path in \
    /usr/local/sbin/pw-backup \
    /usr/local/sbin/pw-backup-uninstall \
    /etc/systemd/system/pw-backup.service \
    /etc/systemd/system/pw-backup.timer \
    /etc/systemd/system/pw-backup.service.d \
    /etc/systemd/system/pw-backup.timer.d \
    /etc/systemd/system/timers.target.wants/pw-backup.timer \
    /var/cache/pw-backup \
    /var/lib/pw-backup
do
    assert_absent "$path"
done

grep -Fqx 'disable --now pw-backup.timer' "$SYSTEMCTL_LOG" || fail 'timer was not disabled'
grep -Fqx 'stop pw-backup.service' "$SYSTEMCTL_LOG" || fail 'service was not stopped'
grep -Fqx 'daemon-reload' "$SYSTEMCTL_LOG" || fail 'systemd was not reloaded'
command -v restic >/dev/null 2>&1 || fail 'restic package was unexpectedly removed'

./install.sh > "$TEST_ROOT/reinstall.log"
[ "$(sha256sum /etc/pw-backup/config.env | awk '{print $1}')" = "$config_sum" ] || \
    fail 'configuration was not preserved across reinstall'
/usr/local/sbin/pw-backup-uninstall --purge > "$TEST_ROOT/purge.log"
assert_absent /etc/pw-backup
assert_absent /usr/local/sbin/pw-backup
assert_absent /usr/local/sbin/pw-backup-uninstall
assert_absent /etc/systemd/system/pw-backup.service
assert_absent /etc/systemd/system/pw-backup.timer
assert_absent /var/cache/pw-backup
assert_absent /var/lib/pw-backup
command -v restic >/dev/null 2>&1 || fail 'restic package was removed by purge'

./uninstall.sh --purge > "$TEST_ROOT/purge-second.log"
printf '%s\n' 'All PW Backup uninstall tests passed.'
