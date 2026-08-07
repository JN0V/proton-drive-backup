# proton-drive-backup

Scheduled backup of local folders to Proton Drive on Linux, built on the
official `proton-drive` CLI, with a graphical confirmation prompt and a
staleness watchdog.

## Why this exists

The Proton Drive CLI (v0.7.0) does **not** do continuous synchronisation: it
runs one operation and exits. There is also no Linux desktop client yet — Proton
has announced one for late 2026. This repository builds the scheduling,
confirmation and monitoring layer that is missing around the CLI.

It is a **backup** tool, not a sync engine. See [Limitations](#limitations).

## Requirements

- The official [Proton Drive CLI](https://proton.me/blog/proton-drive-cli) at
  `~/bin/proton-drive`, signed in via `proton-drive auth login`
- `systemd` user session, `zenity`, `libnotify` (`notify-send`), `curl`
- Tested on Ubuntu 26.04 (GNOME / Wayland)

## Install

```bash
git clone git@github.com:JN0V/proton-drive-backup.git
cd proton-drive-backup
./install.sh
```

The real files stay in the repository; installation only places symlinks in
`~/bin` and `~/.config/systemd/user`. A `git pull` therefore updates the
installation, with nothing to copy.

## Configuration

Mappings live in `~/.config/proton-drive-backup/mappings.conf` (outside the
repository — it holds personal data). A documented template ships as
`config/mappings.conf.example`.

Single rule: **the contents of the source are placed into the remote folder**,
which allows the remote name to differ from the local one.

```
photos   ->  /my-files/Family pictures
.        ->  /my-files/drive
*        ->  /my-files/drive/%name%
```

`*` is the catch-all (`%name%` expands to the folder name); `.` covers files
sitting loose at the source root.

Check your rules without transferring anything:

```bash
proton-drive-backup.sh --dry-run
```

```
Backup plan (dry run, no transfer):

  Source   : /home/you/Documents/drive
  Mappings : /home/you/.config/proton-drive-backup/mappings.conf

   1. photos → /my-files/Family pictures
   2. notes → /my-files/drive/notes

  2 destination(s).
```

## How it works

| Component | Role |
|---|---|
| `proton-drive-backup.timer` | Fires at 12:00. `Persistent=true`: a deadline missed while the machine was off is caught up at the next session. |
| `proton-drive-backup.sh` | Resolves mappings, asks for confirmation, transfers. |
| `proton-drive-backup-check.timer` | Fires at 13:00. |
| `proton-drive-backup-check.sh` | Alerts when no backup has **succeeded** for 3 days. |

State lives in `~/.local/state/proton-drive-backup/`: log, last-success
timestamp, destination UID fingerprints.

Nothing is ever transferred without an explicit click. No answer within 5
minutes counts as a decline.

## Design notes

The points below are counter-intuitive and were each established by testing
against the real CLI.

**Conflict strategies are mandatory.** Without `--file-conflict-strategy` and
`--folder-conflict-strategy`, the CLI asks an interactive question and a systemd
service would hang until its timeout.

**Thumbnail fallback.** A single file with an image extension but invalid
content (corrupt, truncated, misnamed) fails *the entire batch*. The script
detects that specific error and retries only that batch with
`--skip-thumbnails`, rather than disabling thumbnails everywhere.

**Remote rename detection.** The CLI addresses nodes by path only — passing a
UID yields `Path "<uid>" not supported`. A folder renamed on the Drive side
leaves its path vacant, and a naive backup would recreate it and re-upload
everything, splitting the content between the old folder and a new one. The
script records each destination's UID and **stops** that destination instead of
recreating it.

**`create-folder` is not idempotent**: it fails when the name already exists.
Hence a `filesystem info` probe at every level of the tree.

**Success timestamp requires total success.** A partial failure does not write
`last-success`, otherwise the watchdog would believe the whole set is current.

**Separate watchdog.** If the backup timer stops firing, a check hosted inside
the backup script would never run. Hence an independent systemd unit.

**Content-level delta is native.** Since CLI 0.7.0, files with identical content
are skipped automatically; only real changes are uploaded.

## Limitations

Upload only. Nothing is pulled back down, and a local deletion does not remove
the remote copy. Renaming or deleting a *file* leaves an orphan on the Drive
side. This is not a mirror.

For true bidirectional sync: wait for Proton's Linux desktop client, or use
[rclone](https://rclone.org/protondrive/) (its `protondrive` backend has known
limitations around non-interactive 2FA and does not handle modification times).

## Licence

MIT
