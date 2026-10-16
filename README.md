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

- `DEVICE`: backup drive partition (default: `/dev/disk/by-uuid/A41EBEB31EBE7E3C`, the drive's filesystem UUID). A stable identifier is used because `sda`/`sdb` names are assigned in kernel probe order and can swap between the system and backup disks across boots. Override with the `BACKUP_DEVICE` environment variable.
- `DEFAULT_MOUNTPOINT`: where the script mounts the drive if it is not mounted (default: `/mnt/sdb1`, override with `BACKUP_MOUNTPOINT`)
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

Before syncing, the script fails fast instead of producing a cryptic `rsync` error:

- if `DEVICE` does not exist (drive not connected), it exits with `Backup disk not found`
- if the detected mountpoint is not an NTFS filesystem (`ntfs`, `ntfs3`, or `fuseblk`), it refuses to write to it
- if the destination directory cannot be created or is not writable, it exits before `rsync` runs

When it needs to mount the drive, the script reads the sudo password from `.mnt-pwd` in the same directory as `local-backup.sh`. Create that file, put the password on its first line, and restrict access to the current user:

```bash
touch .mnt-pwd
chmod 600 .mnt-pwd
```

The file must be owned by the user running the script and have exactly `600` permissions. It is excluded from Git. Storing a sudo password in plaintext is a security risk; a narrowly scoped `sudoers` rule is preferable where practical.

If `.mnt-pwd` does not exist, the script prompts for the password without echoing it, but only when an interactive terminal is available. Scheduled cron runs cannot prompt and therefore require `.mnt-pwd` when mounting the drive.

The destination is `<mountpoint>/backup/private/`. In dry-run mode the script does not create that directory. If it does not already exist, `rsync` may list the source contents as items it would copy. Dry-run prevents `rsync` from changing files, but the script may still mount and unmount the drive.

## Logging

`rsync` output is appended to the configured logfile. Each sync is marked with start and finish timestamps. The script also prints status and the selected source and destination paths to the terminal.

## Tests

```bash
tests/local-backup.test.sh
```

The tests run the script in a sandboxed `$HOME` with `findmnt`, `mount`, `umount`, `sudo`, and `rsync` stubbed via `PATH`, while `mkdir` and file operations run for real. They lock in the regression from October 2026: on boots where the disk names swapped, `findmnt /dev/sdb1` resolved to the system ESP (`/boot/efi`) and the script rsynced into a root-only path, failing with `Permission denied (13)`.
