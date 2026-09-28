# Local Backup

A Bash script that uses `rsync` to back up `~/Documents/private/` to the `backup/private/` directory on `/dev/sdb1`.

## Requirements

- Bash
- `rsync`
- `findmnt` (provided by util-linux)
- `ntfs-3g` when the script needs to mount the drive itself
- `sudo` permissions to mount or unmount the drive

## Configuration

Edit the configuration variables near the top of `local-backup.sh` to change:

- `DEVICE`: backup drive partition (default: `/dev/sdb1`)
- `DEFAULT_MOUNTPOINT`: where the script mounts the drive if it is not mounted (default: `/mnt/sdb1`)
- `SOURCE`: directory to back up (default: `~/Documents/private/`)
- `LOGFILE`: where `rsync` output is appended (default: `~/rsync-backup.log`)

The source path ends in `/`, so its contents are copied into `backup/private/` on the drive.

## Usage

```bash
./local-backup.sh
```

Preview the transfer without having `rsync` change files:

```bash
./local-backup.sh --dry-run
# or
./local-backup.sh -n
```

Delete destination files that are not present in the source:

```bash
./local-backup.sh --delete
# or
./local-backup.sh -d
```

Options can be combined, for example `./local-backup.sh --dry-run --delete` to preview the deletion behavior. Review the output carefully before running without `--dry-run` when using `--delete`.

## Mount behavior

The script checks whether `DEVICE` is already mounted. If it is, that mountpoint is used and left mounted when the script exits. Otherwise, the script mounts the device at `DEFAULT_MOUNTPOINT` and attempts to unmount it after the sync.

The destination is `<mountpoint>/backup/private/`. In dry-run mode the script does not create that directory. If it does not already exist, `rsync` may list the source contents as items it would copy. Dry-run prevents `rsync` from changing files, but the script may still mount and unmount the drive.

## Logging

`rsync` output is appended to the configured logfile. Each sync is marked with start and finish timestamps. The script also prints status and the selected source and destination paths to the terminal.
