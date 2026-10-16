#!/usr/bin/env bash
#
# Regression tests for local-backup.sh
#
# Break caught (see rsync-backup.log / cron mail, Oct 3/5/12/15 2026):
#   The system disk and the backup disk get sda/sdb names in nondeterministic
#   probe order across boots.  When the backup disk lands on sda, `findmnt
#   /dev/sdb1` answers for the SYSTEM disk's ESP ("/boot/efi", vfat,
#   root-only), the script treats it as the mounted backup drive, the mkdir
#   failure is ignored, and rsync dies with:
#     ERROR: cannot stat destination "/boot/efi/backup/private/": Permission denied (13)
#
# The fix keys the script off a stable /dev/disk/by-uuid path, refuses any
# detected mount that is not an NTFS filesystem, checks device presence, and
# fails fast when the destination cannot be created or written.
#
# Run: tests/local-backup.test.sh

set -u

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/local-backup.sh"

PASS=0
FAIL=0
CURRENT=""

pass() { echo "  ok   - $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }

# --- command stubs --------------------------------------------------------
# findmnt/mount/umount/sudo/rsync are stubbed; mkdir and everything else run
# for real so destination handling is exercised against the real filesystem.
write_stubs() {
    local bin="$1"

    cat > "$bin/findmnt" <<'EOF'
#!/bin/bash
echo "findmnt $*" >> "$STUB_LOG"
case " $* " in
    *" -o TARGET "*)
        [ -n "${FINDMNT_TARGET-}" ] || exit 1
        printf '%s\n' "$FINDMNT_TARGET"
        exit 0
        ;;
    *" -o FSTYPE "*)
        printf '%s\n' "${FINDMNT_FSTYPE-}"
        exit 0
        ;;
esac
exit 0
EOF

    cat > "$bin/mount" <<'EOF'
#!/bin/bash
echo "mount $*" >> "$STUB_LOG"
exit 0
EOF

    cat > "$bin/umount" <<'EOF'
#!/bin/bash
echo "umount $*" >> "$STUB_LOG"
exit 0
EOF

    cat > "$bin/sudo" <<'EOF'
#!/bin/bash
# Mimic `sudo -S -p '' CMD ...`: drop the leading options, swallow the
# password on stdin, then run the command (resolved through PATH, so the
# mount/umount stubs above are what actually execute).
[ "${1-}" = "-S" ] && shift
[ "${1-}" = "-p" ] && shift 2
cat >/dev/null 2>&1 || true
echo "sudo $*" >> "$STUB_LOG"
exec "$@"
EOF

    cat > "$bin/rsync" <<'EOF'
#!/bin/bash
echo "rsync $*" >> "$STUB_LOG"
exit "${RSYNC_STUB_EXIT:-0}"
EOF

    chmod +x "$bin"/*
}

CREATED_PWD_FILE=0

setup() {
    SANDBOX="$(mktemp -d /tmp/opencode/local-backup-test.XXXXXX)"
    T_HOME="$SANDBOX/home"
    mkdir -p "$T_HOME/Documents/private"
    printf 'fixture\n' > "$T_HOME/Documents/private/fixture.txt"

    STUB_BIN="$SANDBOX/bin"
    mkdir -p "$STUB_BIN"
    write_stubs "$STUB_BIN"
    STUB_LOG="$SANDBOX/stub.log"
    : > "$STUB_LOG"

    BACKUP_DEVICE="$SANDBOX/disk.img"
    : > "$BACKUP_DEVICE"
    BACKUP_MOUNTPOINT="$SANDBOX/mnt/sdb1"

    OUT="$SANDBOX/out.txt"

    # The mount branch needs a 600 password file next to the script.
    if [ ! -e "$REPO_DIR/.mnt-pwd" ]; then
        printf 'dummy\n' > "$REPO_DIR/.mnt-pwd"
        chmod 600 "$REPO_DIR/.mnt-pwd"
        CREATED_PWD_FILE=1
    fi
}

teardown() {
    chmod -R u+w "$SANDBOX" 2>/dev/null || true
    rm -rf "$SANDBOX"
    if [ "$CREATED_PWD_FILE" -eq 1 ]; then
        rm -f "$REPO_DIR/.mnt-pwd"
        CREATED_PWD_FILE=0
    fi
}

# Run the script the way cron would: clean environment, everything captured.
# Extra NAME=VAL pairs are appended (later values win), so they override the
# defaults above.
run_backup() {
    RUN_RC=0
    env -i \
        HOME="$T_HOME" \
        PATH="$STUB_BIN:/usr/bin:/bin" \
        STUB_LOG="$STUB_LOG" \
        BACKUP_DEVICE="$BACKUP_DEVICE" \
        BACKUP_MOUNTPOINT="$BACKUP_MOUNTPOINT" \
        "$@" \
        bash "$SCRIPT" >"$OUT" 2>&1 || RUN_RC=$?
}

stub_called() { grep -qE "^$1 " "$STUB_LOG"; }
rsync_called() { grep -q '^rsync ' "$STUB_LOG"; }
rsync_dest_is() { grep -qE "^rsync .*$1/$" "$STUB_LOG"; }

# --- tests ----------------------------------------------------------------

# T1: the original bug. findmnt resolves the device to a foreign, non-NTFS
# mount (the ESP). The script must refuse before rsync ever runs.
test_foreign_mount_refused() {
    CURRENT="T1 foreign (non-NTFS) mount refused"
    echo "T1: refuses a detected mount that is not the NTFS backup disk"
    setup

    run_backup FINDMNT_TARGET="$SANDBOX/boot/efi" FINDMNT_FSTYPE=vfat

    if [ "$RUN_RC" -ne 0 ]; then pass "exits non-zero"; else fail "expected non-zero exit, got $RUN_RC"; fi
    if ! rsync_called; then pass "rsync never invoked"; else fail "rsync was invoked: $(grep '^rsync' "$STUB_LOG")"; fi
    if grep -q 'not the NTFS backup disk' "$OUT"; then pass "explains the refusal"; else fail "refusal message missing from output"; fi

    teardown
}

# T2: happy path when the disk is connected but not mounted: the script
# mounts it at the configured mountpoint and syncs into it.
test_unmounted_gets_mounted_and_synced() {
    CURRENT="T2 unmounted -> mount -> sync"
    echo "T2: mounts an unconnected-at-boot disk and syncs to the configured mountpoint"
    setup

    run_backup FINDMNT_FSTYPE=ntfs3   # no FINDMNT_TARGET: findmnt says "not mounted"

    if [ "$RUN_RC" -eq 0 ]; then pass "exits 0"; else fail "expected exit 0, got $RUN_RC: $(tail -3 "$OUT")"; fi
    if grep -qE "^mount -t ntfs-3g .*${BACKUP_DEVICE} ${BACKUP_MOUNTPOINT}\$" "$STUB_LOG"; then
        pass "mounted the backup device at the configured mountpoint"
    else
        fail "mount call wrong: $(grep '^mount ' "$STUB_LOG" || echo none)"
    fi
    if rsync_dest_is "${BACKUP_MOUNTPOINT}/backup/private"; then pass "rsync dest correct"; else fail "rsync dest wrong: $(grep '^rsync' "$STUB_LOG" || echo none)"; fi
    if stub_called umount; then pass "unmounted what it mounted"; else fail "umount never called"; fi

    teardown
}

# T3: guard for the happy path the fix must not break: disk already mounted
# at the right place (udisks automount) -> plain sync, no mount/umount.
test_already_mounted_syncs_in_place() {
    CURRENT="T3 already-mounted NTFS syncs in place"
    echo "T3: syncs into an already-mounted NTFS mountpoint without mounting"
    setup
    local data_mnt="$SANDBOX/data"
    mkdir -p "$data_mnt"

    run_backup FINDMNT_TARGET="$data_mnt" FINDMNT_FSTYPE=ntfs3

    if [ "$RUN_RC" -eq 0 ]; then pass "exits 0"; else fail "expected exit 0, got $RUN_RC: $(tail -3 "$OUT")"; fi
    if rsync_dest_is "$data_mnt/backup/private"; then pass "rsync dest correct"; else fail "rsync dest wrong: $(grep '^rsync' "$STUB_LOG" || echo none)"; fi
    if ! stub_called mount && ! stub_called umount; then pass "no mount/umount performed"; else fail "unexpected mount/umount"; fi

    teardown
}

# T4: the destination directory cannot be created (this is how the bug
# surfaced: mkdir /boot/efi -> Permission denied, ignored by the script).
test_uncreatable_destination_aborts() {
    CURRENT="T4 uncreatable destination aborts"
    echo "T4: aborts before rsync when the destination cannot be created"
    setup
    local ro_dir="$SANDBOX/ro"
    mkdir -p "$ro_dir"
    chmod 555 "$ro_dir"

    run_backup FINDMNT_TARGET="$ro_dir" FINDMNT_FSTYPE=ntfs3

    if [ "$RUN_RC" -ne 0 ]; then pass "exits non-zero"; else fail "expected non-zero exit, got $RUN_RC"; fi
    if ! rsync_called; then pass "rsync never invoked"; else fail "rsync was invoked despite mkdir failure"; fi
    if grep -q 'Cannot create destination' "$OUT"; then pass "reports the failure"; else fail "failure message missing"; fi

    teardown
}

# T5: backup disk absent entirely (by-uuid path missing) -> clear error,
# not a blind mount attempt / sync.
test_missing_device_aborts() {
    CURRENT="T5 missing device aborts"
    echo "T5: aborts with a clear error when the backup disk is not connected"
    setup

    run_backup BACKUP_DEVICE="$SANDBOX/no-such-disk.img" FINDMNT_FSTYPE=ntfs3

    if [ "$RUN_RC" -ne 0 ]; then pass "exits non-zero"; else fail "expected non-zero exit, got $RUN_RC"; fi
    if ! rsync_called; then pass "rsync never invoked"; else fail "rsync was invoked without a disk"; fi
    if grep -q 'Backup disk not found' "$OUT"; then pass "reports missing disk"; else fail "missing-disk message absent"; fi

    teardown
}

# T6: destination directory exists but is not writable (e.g. left behind by
# an old root run) -> abort instead of running rsync into EACCES.
test_unwritable_destination_aborts() {
    CURRENT="T6 unwritable destination aborts"
    echo "T6: aborts before rsync when the destination exists but is not writable"
    setup
    local mnt="$SANDBOX/existing"
    mkdir -p "$mnt/backup/private"
    chmod 555 "$mnt/backup/private"

    run_backup FINDMNT_TARGET="$mnt" FINDMNT_FSTYPE=ntfs3

    if [ "$RUN_RC" -ne 0 ]; then pass "exits non-zero"; else fail "expected non-zero exit, got $RUN_RC"; fi
    if ! rsync_called; then pass "rsync never invoked"; else fail "rsync was invoked on unwritable dest"; fi
    if grep -q 'not writable' "$OUT"; then pass "reports the failure"; else fail "failure message missing"; fi

    teardown
}

# T7: the heart of the fix. Without an override the script must identify the
# disk by filesystem UUID, never by an sdX name (sdX names swap between the
# two disks across boots -- that is what sent rsync at /boot/efi).
test_default_device_is_uuid_based() {
    CURRENT="T7 default device is the stable by-uuid path"
    echo "T7: without overrides, the script identifies the disk by filesystem UUID (not sdX)"
    setup

    if [ ! -e /dev/disk/by-uuid/A41EBEB31EBE7E3C ]; then
        echo "  skip - backup disk not connected on this host (/dev/disk/by-uuid/A41EBEB31EBE7E3C missing)"
        teardown
        return
    fi

    # BACKUP_DEVICE="" forces the script's own default to kick in.
    run_backup BACKUP_DEVICE="" BACKUP_MOUNTPOINT="$SANDBOX/mnt-default"

    if [ "$RUN_RC" -eq 0 ]; then pass "exits 0"; else fail "expected exit 0, got $RUN_RC: $(tail -3 "$OUT")"; fi
    if grep -qE "^findmnt -n -o TARGET /dev/disk/by-uuid/A41EBEB31EBE7E3C\$" "$STUB_LOG"; then
        pass "queried the disk via its by-uuid path"
    else
        fail "no by-uuid findmnt query; log: $(grep '^findmnt' "$STUB_LOG" || echo none)"
    fi
    if ! grep -qE '^findmnt .*/dev/sd[a-z][0-9]*' "$STUB_LOG"; then
        pass "never queried an unstable sdX name"
    else
        fail "script asked findmnt about an sdX device: $(grep '^findmnt' "$STUB_LOG")"
    fi

    teardown
}

# --- runner ---------------------------------------------------------------

[ -f "$SCRIPT" ] || { echo "script not found: $SCRIPT" >&2; exit 2; }
mkdir -p /tmp/opencode

test_foreign_mount_refused
test_unmounted_gets_mounted_and_synced
test_already_mounted_syncs_in_place
test_uncreatable_destination_aborts
test_missing_device_aborts
test_unwritable_destination_aborts
test_default_device_is_uuid_based

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
