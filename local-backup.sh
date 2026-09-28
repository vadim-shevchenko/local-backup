#!/bin/bash

LANG=en_IL.UTF-8

# === Configuration ===
DEVICE="/dev/sdb1"
MOUNTPOINT="/mnt/sdb1"
SOURCE="$HOME/Documents/private/"
DEST="$MOUNTPOINT/backup/private/"
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

# 1. Check if already mounted
if mountpoint -q "$MOUNTPOINT"; then
    echo -e "${GREEN}Drive is already mounted at $MOUNTPOINT${NC}"
else
    echo "Mounting $DEVICE to $MOUNTPOINT ..."

    if sudo mount -t ntfs-3g -o defaults,uid=$(id -u),gid=$(id -g),umask=022 "$DEVICE" "$MOUNTPOINT"; then
        echo -e "${GREEN}Successfully mounted${NC}"
    else
        echo -e "${RED}Failed to mount the drive. Exiting.${NC}"
        exit 1
    fi
fi

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

rsync $RSYNC_OPTS "$SOURCE" "$DEST" 2>&1 | tee -a "$LOGFILE"

RSYNC_EXIT=${PIPESTATUS[0]}

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

# 4. Unmount the drive
echo
echo "Unmounting $MOUNTPOINT ..."
if sudo umount "$MOUNTPOINT"; then
    echo -e "${GREEN}Successfully unmounted${NC}"
else
    echo -e "${RED}Failed to unmount. Please check manually.${NC}"
fi

echo
echo "=== Script finished ==="
echo "Log saved to: $LOGFILE"