# proton-drive-backup

Scheduled backup of local folders to Proton Drive on Linux, built on the
official `proton-drive` CLI, with a confirmation prompt (graphical or in the
terminal), a staleness watchdog, and a search over the remote tree by name or
by content.

## Why this exists

The Proton Drive CLI (v0.8.0) does **not** do continuous synchronisation: it
runs one operation and exits. There is also no Linux desktop client yet — Proton
has announced one for late 2026. This repository builds the scheduling,
confirmation and monitoring layer that is missing around the CLI.

It is a **backup** tool, not a sync engine. See [Limitations](#limitations).

## Requirements

- The official [Proton Drive CLI](https://proton.me/blog/proton-drive-cli)
  **0.8.0 or later** at `~/bin/proton-drive`, signed in via
  `proton-drive auth login`. Earlier versions are refused: 0.8.0 renamed the
  conflict strategies the backup relies on.
- `systemd` user session, and `jq` for `proton-drive-find.sh`
- On a desktop: `libnotify` (`notify-send`), and `zenity` for the graphical
  prompt — a terminal-only run does without it
- On a host without a desktop: a notification command of your own — see
  [Notification command](#notification-command)
- Tested on Ubuntu 26.04 (GNOME / Wayland)

## Install

```bash
git clone https://github.com/JN0V/proton-drive-backup.git
cd proton-drive-backup
./install.sh
```

The real files stay in the repository; installation only places symlinks in
`~/bin` and `~/.config/systemd/user`. A `git pull` therefore updates the
installation, with nothing to copy.

## Configuration

Two files, both in `~/.config/proton-drive-backup/` and outside the repository.
`install.sh` creates them from the templates in `config/` and never overwrites
them afterwards.

### Host settings

`backup.conf` holds what differs from one machine to the next. Every line is
optional: left commented out, as in the template, the defaults apply.

| Key | Default | |
|---|---|---|
| `SOURCE_ROOT` | `~/Documents/drive` | Local folder whose subfolders are matched against the mappings. |
| `NOTIFY` | `desktop` | Space-separated list of `desktop` (`notify-send`), `command`, `none`. |
| `NOTIFY_COMMAND` | | Executable run for each notification when `command` is listed. See below. |

It is plain `KEY=value`, read rather than sourced: nothing is expanded but a
leading `~/`. Values may be quoted; unquoted, a `#` at the start of the value or
after a space starts a comment. An unknown key or a malformed line is logged by
line number, never by content, since the line may hold a secret and the log is
not private. `SOURCE_ROOT` must be absolute.
Any key can be overridden for one run from the environment, with a
`PROTON_DRIVE_BACKUP_` prefix:

```bash
PROTON_DRIVE_BACKUP_SOURCE_ROOT=/srv/export proton-drive-backup.sh --dry-run
```

### Notification command

`notify-send` covers a desktop. Anything else — a phone, a chat, a mailbox — is
reached through a command of your own, which the tool calls as:

```
NOTIFY_COMMAND URGENCY TITLE BODY
```

- `URGENCY` is `low`, `normal` or `critical`. Only `critical` calls for action:
  a session to renew, a destination not found, a backup overdue.
- Exit status 0 means delivered. Anything else is logged, and the watchdog
  does not count an undelivered overdue alert as sent. Neither does a `NOTIFY`
  that names no known backend, such as the typo `desktop,command`.
- The command gets 30 seconds, and its output is discarded: it may echo a
  secret, and the log is not private.
- `NOTIFY_COMMAND` is an absolute path (or `~/…`) to an executable file,
  nothing more: no arguments, no shell. Its credentials live in its own files,
  not in `backup.conf`.

```
NOTIFY=desktop command
NOTIFY_COMMAND=~/bin/notify-phone.sh
```

Two starting points:

- **ntfy** — [`examples/notify-ntfy.sh`](examples/notify-ntfy.sh) publishes to
  an [ntfy](https://ntfy.sh) topic with `curl` alone, reading `NTFY_URL` and an
  optional `NTFY_TOKEN` from `~/.config/proton-drive-backup/ntfy.conf`. Critical
  messages are sent at high priority, the others at low priority, silent on a
  phone. `ntfy.conf` follows the same rules as `backup.conf`. Link it into
  place: `ln -s "$PWD/examples/notify-ntfy.sh" ~/bin/notify-ntfy.sh`.
  Messages carry folder names and paths: on a public server such as ntfy.sh,
  anyone who knows the topic reads them, so pick a name nobody would guess, or
  a server of your own.
- **[Apprise](https://github.com/caronc/apprise)**, which speaks to a hundred
  services, from its default configuration file:

  ```sh
  #!/bin/sh
  [ "$1" = critical ] && type=failure || type=info
  exec apprise -n "$type" -t "$2" -b "$3"
  ```

### Mappings

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

## Running it by hand

The timer's job is the daily run, but the script is usable on its own:

```bash
proton-drive-backup.sh            # asks where you started it from
proton-drive-backup.sh --yes      # no question asked
```

The prompt follows the context. Started from a terminal it asks in that
terminal; started by the timer — no terminal on stdin — it opens the zenity
dialog. `--cli` and `--gui` force one or the other, which is what a graphical
session needs to be answered over SSH, or a terminal run to hand the question
to the desktop.

```
Backup to Proton Drive

  2 destination(s):
  • photos → /my-files/Family pictures
  • 3 root file(s) → /my-files/drive

  Local total: 816 files (262M)
  Only modified files will be transferred.

Back up now? [y/N] (no answer within 300s = no)
```

`-y, --yes` skips the question altogether, for a scripted or headless run.
Progress is otherwise silent by design: on a terminal the notifications are
mirrored to stderr, so a CLI run still reports its outcome.

| | |
|---|---|
| `-n, --dry-run` | Print the resolved plan and exit. No prompt, no transfer. |
| `-y, --yes` | Assume yes: skip the confirmation. |
| `--only PATH` | Back up only this sub-path of the source (relative, e.g. `Projects/reports`), to the mapping of its top-level folder extended with the rest of the path. Meant for pushing one folder right after it changed, from another service's `ExecStartPost`. Other destinations' fingerprints are kept as they are, and the success stamp is not written: a partial run must not pass for a full one. |
| `--cli` | Ask in the terminal, even under a graphical session. |
| `--gui` | Ask with a zenity dialog, even from a terminal. |

## How it works

| Component | Role |
|---|---|
| `proton-drive-backup.timer` | Fires at 12:00. `Persistent=true`: a deadline missed while the machine was off is caught up at the next session. |
| `proton-drive-backup.sh` | Resolves mappings, asks for confirmation, transfers. |
| `proton-drive-backup-check.timer` | Fires at 13:00, an hour after the backup window so the result is judged on a finished run. |
| `proton-drive-backup-check.sh` | Alerts when no backup has **succeeded** for 3 days. |
| `proton-drive-find.sh` | Searches the remote tree by name, or by content with `--have`. Manual, read-only, no timer. |
| `lib/common.sh` | Shared by `proton-drive-backup.sh` and the watchdog: reads `backup.conf`, sends notifications. |

Both timers carry `RandomizedDelaySec=5min`, so the actual firing is spread
over the five minutes that follow — a run starting at 12:04 is normal. On the
backup timer this also applies to the catch-up, which keeps the confirmation
dialog from popping up in the middle of a login.

State lives in `~/.local/state/proton-drive-backup/`: log, last-success
timestamp, destination UID fingerprints.

Nothing is ever transferred without an explicit confirmation, unless `--yes`
says otherwise. No answer within 5 minutes counts as a decline, dialog or
terminal alike.

## Headless hosts

The same repository runs on a machine without a desktop — a server, a
Raspberry Pi — reached over SSH. Four things differ from a desktop.

**Nobody answers the prompt.** Install with:

```bash
./install.sh --headless
```

It adds a drop-in, `~/.config/systemd/user/proton-drive-backup.service.d/headless.conf`,
that runs the timer's backup with `--yes`; the unit itself stays a symlink into
the repository. zenity is not needed. A manual run over SSH still asks in the
terminal. A later `./install.sh` without the flag keeps the drop-in: removing it
would bring back a prompt that nobody can answer, and every run would be lost.

**Timers need lingering.** A user's systemd manager, and its timers, only
lives while that user is logged in, unless lingering is enabled:

```bash
sudo loginctl enable-linger "$USER"
```

`install.sh --headless` reports whether it is.

**The session cannot go in a keychain.** The CLI stores its session in the
desktop keychain by default, which a headless host does not have. Its
`PROTON_DRIVE_CREDENTIALS_STORE` variable selects another store:

| Value | Where | |
|---|---|---|
| `keychain` | desktop secret service | Default. Needs a desktop session. |
| `unsafe_file` | `~/.local/share/proton-drive-cli/auth-session.json`, mode 600 | In clear: anyone who can read the file holds the session. Nothing to unlock, so it survives reboots. |
| `pass` | [`pass`](https://www.passwordstore.org/), entry `ch.proton.drive/drive-sdk-cli/auth-session` | Encrypted with GPG. An unattended run needs `gpg-agent` to hold the key unlocked — by default for only 10 minutes after its last use — or a key without a passphrase, which is hardly safer than `unsafe_file`. A locked key is likely to be reported as a session to sign in again. |

The variable has to reach both the timers and your shell — `auth login` writes
to the store it names, and the scripts read from theirs:

```bash
# Timers: read by the systemd user manager
mkdir -p ~/.config/environment.d
echo 'PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file' > ~/.config/environment.d/proton-drive.conf
systemctl --user daemon-reload
systemctl --user show-environment | grep PROTON_DRIVE     # check

# Shells, including SSH sessions
echo 'export PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file' >> ~/.profile
```

Then sign in. `auth login` prints a link: open it in a browser on any other
device.

**Notifications need a command.** `notify-send` reaches nobody without a
desktop: set `NOTIFY=command` and a [notification command](#notification-command).
`install.sh --headless` warns when there is none. Prefer a path that does not
depend on the link it reports on: an alert about an unreachable Drive has little
chance of crossing that same broken connection to a remote service.

## Searching the Drive

The CLI has no search command, so `proton-drive-find.sh` walks the remote tree
with `filesystem list` and matches locally. One API call per folder, around
1.5 s each — far too slow to repeat, so the walk is cached in an index and
searches read from that.

Budget the first walk accordingly: on a Drive of 2 263 folders and 68 367
nodes it took **1 h 35 min** and produced an 8 MB index. A later refresh of the
same Drive, grown to 2 388 folders and 70 366 nodes, took 1 h 40 min. Since the
index gained a size and a digest column it weighs around 11 MB. Searches
against it return in about 60 ms.

```bash
proton-drive-find.sh --refresh        # build the index (slow, occasional)
proton-drive-find.sh invoice 2024     # instant, offline
```

```
  index from 2026-08-08 09:12

  f    317K  2024-03-23  /my-files/drive/admin/invoice-2024-03.pdf
  d       -  2024-01-08  /my-files/drive/invoices 2024

  2 result(s).
```

Every term must appear in the path, case-insensitively, as a plain substring —
so `invoice 2024` also matches a file named `invoice.pdf` sitting inside a
folder named `2024`. `--type f|d` narrows to files or folders, `--path` to a
subtree, `--all` widens to the shared and device roots. Deleted files stay out
of every result unless you ask for them with `--path /trash`.

The index is **never refreshed automatically**; its age is printed at every
search and flagged past 7 days. `--live` skips it entirely and walks the Drive
on the spot, which is slow but always current.

`--have` answers the opposite question — *is this local file already on the
Drive?* — on content rather than on name:

```bash
proton-drive-find.sh --have ~/Downloads/*.pdf
```

```
  on Drive   /home/you/Downloads/invoice-2024-03.pdf
               /my-files/drive/admin/invoice-2024-03.pdf
  ABSENT     /home/you/Downloads/quote-2026.pdf
```

Empty files are reported as `empty` rather than found: every zero-byte file
shares one digest, so a match against another empty file on the Drive says
nothing — and this answer is meant to be safe to feed into a deletion.

It hashes each file and looks the digest up in the index (see *The index keeps
the plaintext size and a digest* below). Offline, instant, and blind to names:
a file renamed on either side still matches, and two unrelated files that
happen to share a name do not. Exit status is 0 only when every file was found,
so it composes into a script that deletes local copies once they are safely
remote. An index built before the digest column existed is refused with a
pointer to `--refresh`.

`--paths` prints bare paths for piping:

```bash
proton-drive-find.sh --paths report.pdf \
  | xargs -r -d '\n' sh -c 'proton-drive filesystem download "$@" ~/Downloads' _
```

Two details that both bite: `filesystem download` takes the remote paths
**first** and the local folder **last**, so a bare `xargs … download ~/Downloads`
passes the destination as the first path and the CLI answers
`EACCES … mkdir /my-files`. And remote paths routinely contain spaces, hence
`-d '\n'` rather than the default word splitting.

Note that anything backed up *from this machine* is already local, where `find`
is faster. Remote search earns its keep on what did not come from here: uploads
from a phone, additions made through the web app, older content.

## Design notes

The points below are counter-intuitive and were each established by testing
against the real CLI.

**Conflict strategies are mandatory.** Without `--file-conflict-strategy` and
`--folder-conflict-strategy`, the CLI asks an interactive question and a systemd
service would hang until its timeout.

**`replace` trashes, `create-new-revision` does not.** For files the backup uses
`create-new-revision`, added in CLI 0.8.0. `replace` — the only sane option
before it — trashes the remote file and uploads a *new node*: measured against
the real CLI, a modified file came back with a different UID, its creation date
reset, and the previous copy sitting in the trash. Repeated daily that fills the
trash and burns quota until an `empty-trash`, and no version history survives.
`create-new-revision` keeps the node and stacks a revision on it: same UID, same
creation date, previous content still reachable. Files whose content has not
changed are still skipped outright, so unmodified files gain no revision.

Two measurements worth knowing before assuming revisions are free. They are
**not**: after a second upload the node's `totalStorageSize` is the sum of both
revisions, so storage is consumed either way. What differs is that revisions
**survive `empty-trash`**, where everything `replace` had pushed into the trash
does not — emptying the trash destroys those older versions for good. Revisions
are a version history; a full trash is only a bill.

**Strategy names changed in 0.8.0**, which is why earlier CLIs are refused
rather than tolerated. `keep-both` became `rename`, `merge` disappeared for
files, the download side spells local overwrite `remove` where the upload side
spells remote overwrite `replace`, and the `-c/--conflict-strategy` catch-all
was dropped. A wrong value fails before any transfer, with exit code 1.

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

**Unreachable is not signed out.** The session probe is a network call, and the
CLI answers a dead session and an out-of-reach API the same way: exit 1, with
the reason printed on *stdout*. Since the timer is `Persistent=`, a missed run
fires the instant the machine wakes, seconds before the wifi is back — enough
to demand a new `auth login` for a session that never expired. The probe is
therefore retried (5 tries, 20 s apart, 60 s each) while the failure still
reads as a missing network, and the run is then *postponed* — a plain
notification and exit 0, since an absent network is neither a failed unit nor
anything to fix. Only a failure worded otherwise blames the session. The
watchdog draws the same distinction before naming a cause.

**Content-level delta is native.** Since CLI 0.7.0, files with identical content
are skipped automatically; only real changes are uploaded.

**The CLI checks for its own updates.** Since 0.8.0, `proton-drive version` adds
a line — `You are running the latest version.` or `A newer version is available:
X (you have Y).` — so the script reads its output instead of scraping the
download page, and reports the update in the confirmation prompt. That line
costs an HTTP request, hence the `timeout` wrapper: an update check must never
hold up a backup.

**Photos cannot be searched by name.** `/photos` is advertised as a root but
`filesystem list /photos` answers `Path type photos is not supported`. The
dedicated `photo timeline` returns node UIDs and capture times and no names, and
feeding one of those UIDs back to `filesystem info` hits the same
path-only restriction as everywhere else. Only photo copies living inside the
`/my-files` tree appear in the index.

**The stored size is not the file's size, and the gap has two causes.**
`totalStorageSize` — what `filesystem list` reports first — exceeds the
plaintext size by:

- **encryption**, an exact 59 bytes per 4 MiB block (53 on revisions written by
  an older SDK). Perfectly regular: a 20 MB PDF over 5 blocks is 295 bytes
  larger, every time.
- **a thumbnail**, for images, audio and video only. Not a small constant but
  **5 to 10 % of the file**: a 451 279-byte JPEG is stored as 476 948, a 5 MB
  photo can gain 500 KB.

The first is what a sample of PDFs shows, and it is misleading on its own: it
suggests the stored size is *nearly* the real one, and a model built on it
declares every photo and every MP3 modified. Both corrections are needed, and
even then an exact size match is not identity — two unrelated PDFs here shared
a byte count of 33 201.

None of which matters any more, because the real size is available directly.

**The index drops UIDs.** Storing them would be four fifths of the file for no
benefit: nothing can consume a UID, since the CLI only addresses nodes by path.

**The index keeps the plaintext size and a digest.** `filesystem list -j`
returns, per node, `activeRevision.claimedSize` — the size before encryption —
and `activeRevision.claimedDigests.sha1`, the sha1 of that plaintext. Both come
from the call the walk already makes, so they cost no extra request and about
40 bytes per file. The digest was verified against local files: exact.

That turns the index from a name catalogue into a content catalogue, and it is
what makes `--have` possible. Note `sha1Verified: false` in the CLI's output:
the digest is claimed by whichever client uploaded the revision, not recomputed
server-side. For "did this file come from here?" that is precisely the right
guarantee; it is not a defence against a tampered server.

**A truncated index is worse than none.** The walk writes to a temporary file
and moves it into place at the end, so a run interrupted halfway leaves the
previous index intact rather than a partial one that later searches would
quietly trust. For the same reason, an unlistable folder is reported and
counted, never skipped in silence.

## Limitations

Upload only. Nothing is pulled back down, and a local deletion does not remove
the remote copy. Renaming or deleting a *file* leaves an orphan on the Drive
side. This is not a mirror.

For true bidirectional sync: wait for Proton's Linux desktop client, or use
[rclone](https://rclone.org/protondrive/) (its `protondrive` backend has known
limitations around non-interactive 2FA and does not handle modification times).

## Licence

MIT
