#!/bin/bash

LANG=en_IL.UTF-8

# === Configuration ===
DEVICE="/dev/sdb1"
DEFAULT_MOUNTPOINT="/mnt/sdb1"          # Used only when we need to mount it
SOURCE="$HOME/Documents/private/"
LOGFILE="$HOME/rsync-backup.log"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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

# 1. Check if the device is already mounted (find real mountpoint)
EXISTING_MOUNT=$(findmnt -n -o TARGET "$DEVICE" 2>/dev/null)

if [ -n "$EXISTING_MOUNT" ]; then
    MOUNTPOINT="$EXISTING_MOUNT"
    echo -e "${GREEN}Drive $DEVICE is already mounted at: $MOUNTPOINT${NC}"
    echo "Using existing mountpoint (will NOT unmount at the end)"
    WE_MOUNTED=false
else
    MOUNTPOINT="$DEFAULT_MOUNTPOINT"
    echo "Drive $DEVICE is not mounted."
    echo "Mounting to default location: $MOUNTPOINT ..."

    # Create mountpoint if it doesn't exist
    sudo mkdir -p "$MOUNTPOINT"

    if sudo mount -t ntfs-3g -o defaults,uid=$(id -u),gid=$(id -g),umask=022 "$DEVICE" "$MOUNTPOINT"; then
        echo -e "${GREEN}Successfully mounted at $MOUNTPOINT${NC}"
        WE_MOUNTED=true
    else
        echo -e "${RED}Failed to mount the drive. Exiting.${NC}"
        exit 1
    fi
fi

# Destination path (based on the actual mountpoint we found/used)
DEST="$MOUNTPOINT/backup/private/"

# 2. Create destination directory (skip in dry-run)
if [ "$DRY_RUN" = false ]; then
    mkdir -p "$DEST"
fi

# 3. Run rsync
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

# 4. Unmount only if this script mounted the drive
if [ "$WE_MOUNTED" = true ]; then
    echo
    echo "Unmounting $MOUNTPOINT (because this script mounted it) ..."
    if sudo umount "$MOUNTPOINT"; then
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