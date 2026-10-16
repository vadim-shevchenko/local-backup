#!/bin/bash

LANG=en_IL.UTF-8
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# === Configuration ===
# Device names (sda/sdb) are assigned in kernel probe order, which is not
# stable across boots: the system and backup disks have swapped names, making
# `findmnt /dev/sdb1` resolve to the system ESP (/boot/efi). Key off the
# filesystem UUID instead so the right disk is found on every boot.
# Override with BACKUP_DEVICE / BACKUP_MOUNTPOINT (used by the tests).
DEVICE="${BACKUP_DEVICE:-/dev/disk/by-uuid/A41EBEB31EBE7E3C}"
DEFAULT_MOUNTPOINT="${BACKUP_MOUNTPOINT:-/mnt/sdb1}"   # Used only when we need to mount it
SOURCE="$HOME/Documents/private/"
LOGFILE="$HOME/rsync-backup.log"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

load_sudo_password() {
    local password_file="$SCRIPT_DIR/.mnt-pwd"
    local owner_and_mode

    if [[ ! -e "$password_file" ]]; then
        if ! exec 3<>/dev/tty 2>/dev/null; then
            echo "No $password_file found and no interactive terminal is available for a password prompt." >&2
            return 1
        fi

        printf 'Enter sudo password: ' >&3
        if ! IFS= read -r -s -u 3 SUDO_PASSWORD; then
            printf '\n' >&3
            exec 3>&-
            echo "Could not read sudo password from terminal." >&2
            return 1
        fi
        printf '\n' >&3
        exec 3>&-

        if [[ -z "$SUDO_PASSWORD" ]]; then
            echo "Sudo password cannot be empty." >&2
            return 1
        fi
        return 0
    fi

    if [[ ! -f "$password_file" || ! -r "$password_file" ]]; then
        echo "Unreadable sudo password file: $password_file" >&2
        return 1
    fi

    owner_and_mode=$(stat -c '%u:%a' "$password_file")
    if [[ "$owner_and_mode" != "$(id -u):600" ]]; then
        echo "Set $password_file ownership to the current user and permissions to 600." >&2
        return 1
    fi

    IFS= read -r SUDO_PASSWORD < "$password_file" || true
    if [[ -z "$SUDO_PASSWORD" ]]; then
        echo "Sudo password file is empty: $password_file" >&2
        return 1
    fi
    return 0
}

run_sudo() {
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
}

# === Default options ===
DRY_RUN=false
DELETE=false
RSYNC_OPTS="-avh --progress"
WE_MOUNTED=false
MOUNTPOINT=""                           # Will be set dynamically

# === Parse arguments ===
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)
            DRY_RUN=true
            RSYNC_OPTS="$RSYNC_OPTS --dry-run"
            ;;
        --delete|-d)
            DELETE=true
            RSYNC_OPTS="$RSYNC_OPTS --delete"
            ;;
        *)
            echo -e "${RED}Unknown option: $arg${NC}"
            echo "Usage: $0 [--dry-run|-n] [--delete|-d]"
            exit 1
            ;;
    esac
done

# Show mode
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}>>> DRY-RUN MODE ENABLED (no changes will be made) <<<${NC}"
fi
if [ "$DELETE" = true ]; then
    echo -e "${YELLOW}>>> DELETE MODE ENABLED (files not in source will be deleted) <<<${NC}"
else
    echo -e "${GREEN}>>> Safe mode: files will only be added/updated (no deletions) <<<${NC}"
fi
echo

echo "=== Starting backup script ==="
echo "Time: $(date)"
echo

# 1. Make sure the backup disk is actually connected (the by-uuid symlink
#    only exists while the disk is present)
if [ ! -e "$DEVICE" ]; then
    echo -e "${RED}Backup disk not found: $DEVICE (is the disk connected?)${NC}"
    exit 1
fi

# 2. Check if the device is already mounted (find real mountpoint)
EXISTING_MOUNT=$(findmnt -n -o TARGET "$DEVICE" 2>/dev/null)

if [ -n "$EXISTING_MOUNT" ]; then
    MOUNTPOINT="$EXISTING_MOUNT"

    # Never write into a mount that isn't the NTFS backup disk, no matter
    # what the device lookup returned.
    MOUNT_FSTYPE=$(findmnt -n -o FSTYPE -T "$MOUNTPOINT" 2>/dev/null)
    case "$MOUNT_FSTYPE" in
        ntfs|ntfs3|fuseblk) ;;
        *)
            echo -e "${RED}Refusing: $MOUNTPOINT holds '$MOUNT_FSTYPE' - not the NTFS backup disk.${NC}"
            exit 1
            ;;
    esac

    echo -e "${GREEN}Drive $DEVICE is already mounted at: $MOUNTPOINT${NC}"
    echo "Using existing mountpoint (will NOT unmount at the end)"
    WE_MOUNTED=false
else
    MOUNTPOINT="$DEFAULT_MOUNTPOINT"
    echo "Drive $DEVICE is not mounted."
    echo "Mounting to default location: $MOUNTPOINT ..."

    if ! load_sudo_password; then
        exit 1
    fi

    # Create mountpoint if it doesn't exist
    run_sudo mkdir -p "$MOUNTPOINT"

    if run_sudo mount -t ntfs-3g -o defaults,uid=$(id -u),gid=$(id -g),umask=022 "$DEVICE" "$MOUNTPOINT"; then
        echo -e "${GREEN}Successfully mounted at $MOUNTPOINT${NC}"
        WE_MOUNTED=true
    else
        echo -e "${RED}Failed to mount the drive. Exiting.${NC}"
        exit 1
    fi
fi

# Destination path (based on the actual mountpoint we found/used)
DEST="$MOUNTPOINT/backup/private/"

# 3. Create destination directory and verify we can write to it (skip in
#    dry-run, where nothing is created)
if [ "$DRY_RUN" = false ]; then
    if ! mkdir -p "$DEST"; then
        echo -e "${RED}Cannot create destination: $DEST${NC}"
        exit 1
    fi
    if [ ! -w "$DEST" ]; then
        echo -e "${RED}Destination is not writable: $DEST${NC}"
        exit 1
    fi
fi

# 4. Run rsync
echo
echo "Starting rsync from:"
echo "  Source: $SOURCE"
echo "  Dest:   $DEST"
echo "----------------------------------------"

printf '=== Sync started: %s ===\n' "$(date)" >> "$LOGFILE"
rsync $RSYNC_OPTS "$SOURCE" "$DEST" 2>&1 | tee -a "$LOGFILE"

RSYNC_EXIT=${PIPESTATUS[0]}
printf '=== Sync finished: %s ===\n' "$(date)" >> "$LOGFILE"

echo "----------------------------------------"

if [ $RSYNC_EXIT -eq 0 ]; then
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Dry-run completed successfully (no files were changed)${NC}"
    else
        echo -e "${GREEN}Rsync completed successfully${NC}"
    fi
else
    echo -e "${RED}Rsync finished with errors (exit code $RSYNC_EXIT)${NC}"
fi

# 5. Unmount only if this script mounted the drive
if [ "$WE_MOUNTED" = true ]; then
    echo
    echo "Unmounting $MOUNTPOINT (because this script mounted it) ..."
    if run_sudo umount "$MOUNTPOINT"; then
        echo -e "${GREEN}Successfully unmounted${NC}"
    else
        echo -e "${RED}Failed to unmount. Please check manually.${NC}"
    fi
else
    echo
    echo -e "${GREEN}Leaving the drive mounted at $MOUNTPOINT${NC}"
fi

echo
echo "=== Script finished ==="
echo "Log saved to: $LOGFILE"