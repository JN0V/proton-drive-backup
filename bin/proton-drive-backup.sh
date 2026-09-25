#!/usr/bin/env bash
#
# Backs up a local folder (~/Documents/drive unless backup.conf says otherwise)
# to Proton Drive, following the mappings declared in
# ~/.config/proton-drive-backup/mappings.conf.
#
# Started by the systemd timer proton-drive-backup.timer, with a graphical
# confirmation prompt; run from a terminal it asks in the terminal instead. A
# headless host runs it with --yes (see install.sh --headless).
# See also proton-drive-backup-check.sh (staleness alert).
#
set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || exit 1

# ---------- Configuration ----------
PROTON_DRIVE="$HOME/bin/proton-drive"
SOURCE_ROOT="$(conf SOURCE_ROOT "$HOME/Documents/drive")"
MAPPINGS_FILE="$HOME/.config/proton-drive-backup/mappings.conf"
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"   # epoch of the last SUCCESSFUL backup
DEST_UIDS="$LOG_DIR/dest-uids"          # <remote path><TAB><uid>: rename detection
MAX_LOG_BYTES=1048576                   # 1 MiB, then simple rotation
CONFIRM_TIMEOUT=300                     # seconds; no answer -> do nothing
MIN_CLI_VERSION="0.8.0"                 # create-new-revision requires it
VERSION_TIMEOUT=15                      # max seconds for `proton-drive version`
SESSION_TIMEOUT=60                      # max seconds for one session probe
SESSION_TRIES=5                         # probes before giving up
SESSION_RETRY_DELAY=20                  # seconds between two probes
# -----------------------------------

usage() {
    cat <<'EOF'
Usage: proton-drive-backup.sh [OPTIONS]

Backs up the source folder to Proton Drive, following the mappings declared in
~/.config/proton-drive-backup/mappings.conf. Asks for confirmation first.

The source is ~/Documents/drive unless SOURCE_ROOT is set in
~/.config/proton-drive-backup/backup.conf (or PROTON_DRIVE_BACKUP_SOURCE_ROOT
in the environment).

Options:
  -n, --dry-run   Print the resolved plan and exit. No prompt, no transfer.
  -y, --yes       Assume yes: skip the confirmation entirely.
      --only PATH Back up only this sub-path of the source (relative, e.g.
                  "Projects/reports"). Its destination is the mapping of its
                  top-level folder plus the remaining path. Other fingerprints
                  are kept untouched, and the success stamp is not written:
                  a partial run must not pass for a full one.
      --cli       Ask in the terminal, even under a graphical session.
      --gui       Ask with a zenity dialog, even from a terminal.
  -h, --help      This help.

Without --cli or --gui the prompt follows where the script was started from:
the terminal when stdin is one (a manual run), a zenity dialog otherwise (the
systemd timer). No answer within 5 minutes counts as a decline, either way.
EOF
}

# --- Arguments ----------------------------------------------------------------
# Dry-run mode: print the plan (resolved mappings) and exit, with no prompt and
# no transfer. Used to validate mappings.conf before applying it.
DRY_RUN=0
ASSUME_YES=0
PROMPT_MODE=auto        # auto | cli | gui
ONLY=""                 # sub-path restriction, see --only

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        --cli)        PROMPT_MODE=cli ;;
        --gui)        PROMPT_MODE=gui ;;
        --only)       shift; ONLY="${1:-}"; [ -n "$ONLY" ] || { echo "--only needs a path" >&2; exit 2; } ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

mkdir -p "$LOG_DIR"

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Whatever goes wrong, the Proton Drive CLI exits 1 and prints its complaint on
# stdout; only the wording tells a dead session apart from an API it never
# reached. These are the signatures of the second case.
drive_unreachable() {
    printf '%s' "$1" | grep -qiE \
'unable to connect|connectionrefused|connectionreset|connectiontimeout|econnrefused|econnreset|econnaborted|enetunreach|ehostunreach|enotfound|eai_again|etimedout|getaddrinfo|socket hang up|fetch failed|network'
}

# Rotate before writing
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

log "--- Timer fired ---"
[ -n "$CONF_IGNORED" ] && log "CONFIG: ignored in $CONF_FILE:$CONF_IGNORED"

# --- Preflight checks ---------------------------------------------------------
if [ ! -x "$PROTON_DRIVE" ]; then
    log "ERROR: binary missing or not executable: $PROTON_DRIVE"
    notify critical "Backup unavailable" "Proton Drive CLI not found."
    exit 1
fi

# Relative would mean relative to wherever the script happens to be started:
# $HOME under systemd, anything at all from a shell.
case "$SOURCE_ROOT" in
    /*) ;;
    *)
        log "ERROR: SOURCE_ROOT must be an absolute path: $SOURCE_ROOT"
        notify critical "Backup unavailable" "SOURCE_ROOT is not an absolute path: $SOURCE_ROOT"
        exit 1 ;;
esac

if [ ! -d "$SOURCE_ROOT" ]; then
    log "ERROR: source directory missing: $SOURCE_ROOT"
    notify critical "Backup unavailable" "Directory missing: $SOURCE_ROOT"
    exit 1
fi

if [ ! -r "$SOURCE_ROOT" ] || [ ! -x "$SOURCE_ROOT" ]; then
    log "ERROR: source directory not readable: $SOURCE_ROOT"
    notify critical "Backup unavailable" "Cannot read $SOURCE_ROOT"
    exit 1
fi

# Not a single entry is not a quiet day, it is a source that is not there: on a
# server, typically a disk that failed to mount, leaving the bare mount point.
# Left to the "nothing to back up" path below, it would be a silent daily
# no-op until the watchdog noticed, three days later. A dry run shows the empty
# plan instead, which says the same thing without an alert.
if [ "$DRY_RUN" -eq 0 ] && [ -z "$(ls -A "$SOURCE_ROOT" 2>/dev/null)" ]; then
    log "ERROR: source directory is empty: $SOURCE_ROOT"
    notify critical "Backup unavailable" \
        "$SOURCE_ROOT is empty. An unmounted disk?"
    exit 1
fi

if [ ! -f "$MAPPINGS_FILE" ]; then
    log "ERROR: mappings file missing: $MAPPINGS_FILE"
    notify critical "Backup unavailable" \
        "Mappings file missing:
$MAPPINGS_FILE"
    exit 1
fi

# --- Reading the mappings -----------------------------------------------------
# Two parallel arrays rather than an associative one: we want the display order
# to stay stable and identical to the file.
declare -a MAP_KEYS=() MAP_DESTS=()
CATCHALL_DEST=""
ROOTFILES_DEST=""

while IFS= read -r line; do
    # Strip trailing comments and surrounding whitespace
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    case "$line" in
        *"->"*) ;;
        *) log "CONFIG: line ignored (no '->'): $line"; continue ;;
    esac

    key="${line%%->*}"
    dest="${line#*->}"
    key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
    dest="$(printf '%s' "$dest" | sed 's/^[[:space:]]*//; s|/*$||')"

    if [ -z "$key" ] || [ -z "$dest" ]; then
        log "CONFIG: incomplete line ignored: $line"
        continue
    fi

    case "$key" in
        '*') CATCHALL_DEST="$dest" ;;
        '.') ROOTFILES_DEST="$dest" ;;
        *)   MAP_KEYS+=("$key"); MAP_DESTS+=("$dest") ;;
    esac
done < "$MAPPINGS_FILE"

log "CONFIG: ${#MAP_KEYS[@]} explicit mapping(s), catch-all='${CATCHALL_DEST:-none}', root='${ROOTFILES_DEST:-none}'"

# Destination declared for a folder name. Non-zero if there is none.
lookup_dest() {
    local name="$1" i
    for i in "${!MAP_KEYS[@]}"; do
        if [ "${MAP_KEYS[$i]}" = "$name" ]; then
            printf '%s' "${MAP_DESTS[$i]}"
            return 0
        fi
    done
    return 1
}

# --- Building the job list ----------------------------------------------------
# JOB_SRCS[i]  : local directory (or the literal ".ROOTFILES" for loose files)
# JOB_DESTS[i] : receiving remote directory
# JOB_LABELS[i]: label shown to the user
declare -a JOB_SRCS=() JOB_DESTS=() JOB_LABELS=()
SKIPPED_REPORT=""

shopt -s dotglob nullglob

# 1. Top-level subdirectories
for entry in "$SOURCE_ROOT"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"

    if dest="$(lookup_dest "$name")"; then
        :
    elif [ -n "$CATCHALL_DEST" ]; then
        dest="${CATCHALL_DEST//%name%/$name}"
    else
        log "SKIP: '$name' has no mapping and there is no catch-all rule."
        SKIPPED_REPORT="$SKIPPED_REPORT
  • $name (no mapping)"
        continue
    fi

    # An empty directory has nothing to send and would fail the upload
    contents=("$entry"/*)
    if [ ${#contents[@]} -eq 0 ]; then
        log "SKIP: '$name' is empty."
        continue
    fi

    JOB_SRCS+=("$entry")
    JOB_DESTS+=("$dest")
    JOB_LABELS+=("$name → $dest")
done

# 2. Files sitting directly at the root
rootfiles=()
for entry in "$SOURCE_ROOT"/*; do
    [ -f "$entry" ] && rootfiles+=("$entry")
done
if [ ${#rootfiles[@]} -gt 0 ]; then
    if [ -n "$ROOTFILES_DEST" ]; then
        JOB_SRCS+=(".ROOTFILES")
        JOB_DESTS+=("$ROOTFILES_DEST")
        JOB_LABELS+=("${#rootfiles[@]} root file(s) → $ROOTFILES_DEST")
    else
        log "SKIP: ${#rootfiles[@]} root file(s), no '.' rule."
        SKIPPED_REPORT="$SKIPPED_REPORT
  • ${#rootfiles[@]} root file(s) (no '.' rule)"
    fi
fi

shopt -u dotglob nullglob

# --- Single sub-path (--only) -------------------------------------------------
# Replaces the whole job list with one job: the sub-path's contents go to the
# mapping of its top-level folder, extended with the rest of the path. Used to
# push one folder right after it changed, without waiting for the daily run.
if [ -n "$ONLY" ]; then
    ONLY="${ONLY%/}"
    only_src="$SOURCE_ROOT/$ONLY"
    if [ ! -d "$only_src" ]; then
        log "ERROR: --only: '$only_src' is not a directory."
        echo "--only: '$only_src' is not a directory" >&2
        exit 2
    fi
    only_top="${ONLY%%/*}"
    only_rest="${ONLY#"$only_top"}"      # "" or "/rest/of/path"
    if only_dest="$(lookup_dest "$only_top")"; then
        :
    elif [ -n "$CATCHALL_DEST" ]; then
        only_dest="${CATCHALL_DEST//%name%/$only_top}"
    else
        log "ERROR: --only: '$only_top' has no mapping and there is no catch-all rule."
        echo "--only: '$only_top' has no mapping and there is no catch-all rule" >&2
        exit 2
    fi
    JOB_SRCS=("$only_src")
    JOB_DESTS=("$only_dest$only_rest")
    JOB_LABELS=("$ONLY → $only_dest$only_rest")
    SKIPPED_REPORT=""
fi

# --- Dry-run exit -------------------------------------------------------------
# Placed before the "nothing to back up" bail-out: a dry run must print its plan
# even when empty, and must never raise a notification.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\nBackup plan (dry run, no transfer):\n\n'
    printf '  Source   : %s\n' "$SOURCE_ROOT"
    printf '  Mappings : %s\n\n' "$MAPPINGS_FILE"
    for i in "${!JOB_SRCS[@]}"; do
        printf '  %2d. %s\n' "$((i+1))" "${JOB_LABELS[$i]}"
    done
    if [ -n "$SKIPPED_REPORT" ]; then
        printf '\n  Skipped:%s\n' "$SKIPPED_REPORT"
    fi
    printf '\n  %d destination(s).\n\n' "${#JOB_SRCS[@]}"
    # Every run logs how it ended; the watchdog skips this one.
    log "DRY RUN: plan printed, nothing transferred."
    exit 0
fi

if [ ${#JOB_SRCS[@]} -eq 0 ]; then
    log "ABORT: nothing to back up."
    notify normal "Backup cancelled" "Nothing to send from $SOURCE_ROOT."
    exit 0
fi

# --- Valid session? -----------------------------------------------------------
# Checked before the prompt, so the user is never asked to answer for nothing.
#
# The probe is a network call, so its failure means one of two very different
# things: the session is gone, or the Drive was simply out of reach. Reading
# the second as the first is not a corner case here — the timer is Persistent=,
# so a missed run fires the very moment the machine wakes up, a few seconds
# before NetworkManager is back on the wifi. That is enough to raise a
# "sign in again" alert for a session that never stopped being valid.
#
# Hence: keep retrying while the failure only looks like a missing network, and
# blame the session only when the CLI says something else.
SESSION_OUT=""
SESSION_RC=1
SESSION_TRY=1
while [ "$SESSION_TRY" -le "$SESSION_TRIES" ]; do
    # The CLI prints its errors on stdout, not stderr, so both are captured.
    SESSION_OUT="$(timeout "$SESSION_TIMEOUT" \
        "$PROTON_DRIVE" filesystem list /my-files 2>&1)"
    SESSION_RC=$?
    [ "$SESSION_RC" -eq 0 ] && break
    # 124 is `timeout` cutting a hanging call off: a network symptom as well.
    if [ "$SESSION_RC" -ne 124 ] && ! drive_unreachable "$SESSION_OUT"; then
        break
    fi
    if [ "$SESSION_TRY" -lt "$SESSION_TRIES" ]; then
        log "Proton Drive unreachable (try $SESSION_TRY/$SESSION_TRIES), \
retrying in ${SESSION_RETRY_DELAY}s."
        sleep "$SESSION_RETRY_DELAY"
    fi
    SESSION_TRY=$((SESSION_TRY + 1))
done

if [ "$SESSION_RC" -ne 0 ]; then
    if [ "$SESSION_RC" -eq 124 ] || drive_unreachable "$SESSION_OUT"; then
        # Nothing is broken and there is nothing to fix, so this stays a plain
        # notification and exits 0: an absent network is not a failed unit, and
        # a lasting one is what the watchdog is there to catch.
        log "POSTPONED: Proton Drive unreachable after $SESSION_TRIES tries."
        notify normal "Backup postponed" \
            "Proton Drive is unreachable — no network. The next run will retry."
        exit 0
    fi
    log "ERROR: Proton Drive session missing or expired: ${SESSION_OUT%%$'\n'*}"
    notify critical "Proton Drive: sign-in required" \
        "Run 'proton-drive auth login' in a terminal."
    exit 1
fi

# --- Version ------------------------------------------------------------------
# Since 0.8.0 the CLI checks for updates itself, so `version` covers both needs
# in one call: reading the installed version, and reporting a newer one.
#
#   Proton Drive CLI cli-drive@0.8.0+06e8c605
#   Proton Drive SDK js@0.21.0+06e8c605
#   You are running the latest version.
#
# The third line reads "A newer version is available: X (you have Y)." when one
# is out, and is absent altogether when the check could not reach the network.
#
# Wrapped in `timeout`: that third line costs an HTTP request, and a hanging one
# must not hold the backup.
VERSION_OUT="$(timeout "$VERSION_TIMEOUT" "$PROTON_DRIVE" version 2>/dev/null)"
CLI_VERSION=$(printf '%s' "$VERSION_OUT" \
    | grep -oP 'cli-drive@\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)

# This script targets the 0.8 CLI and nothing older: create-new-revision does
# not exist before it, and every destination would fail on "Invalid conflict
# strategy". Better to say so than to let the whole run collapse.
if [ -z "$CLI_VERSION" ]; then
    log "ERROR: cannot read the CLI version."
    notify critical "Backup unavailable" \
        "Cannot read the Proton Drive CLI version."
    exit 1
fi
if [ "$(printf '%s\n%s\n' "$CLI_VERSION" "$MIN_CLI_VERSION" | sort -V | head -1)" \
     != "$MIN_CLI_VERSION" ]; then
    log "ERROR: CLI $CLI_VERSION is too old, $MIN_CLI_VERSION or later required."
    notify critical "Proton Drive CLI too old" \
        "Version $CLI_VERSION installed, $MIN_CLI_VERSION or later required.
Download: https://proton.me/download/drive/cli/index.html"
    exit 1
fi

# Informational only: no update is ever installed automatically, and a failed
# check must never prevent the backup from running.
NEWER_VERSION=$(printf '%s' "$VERSION_OUT" \
    | grep -oP 'A newer version is available: \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$NEWER_VERSION" ]; then
    log "VERSION: update available ($CLI_VERSION -> $NEWER_VERSION)."
    notify normal "Proton Drive CLI: update available" \
        "Version $NEWER_VERSION is available (installed: $CLI_VERSION)."
elif printf '%s' "$VERSION_OUT" | grep -q 'running the latest version'; then
    log "VERSION: up to date ($CLI_VERSION)."
else
    log "VERSION: update check unavailable (network). Local: $CLI_VERSION"
fi

# --- Confirmation -------------------------------------------------------------
# ANSWER follows zenity's convention throughout: 0 accepted, 5 timed out,
# anything else declined.
if [ "$ASSUME_YES" -eq 1 ]; then
    log "Confirmation skipped (--yes), ${#JOB_SRCS[@]} job(s)."
else
    # Frontend choice: an explicit --cli/--gui wins, otherwise the prompt
    # follows where the script was started from. The timer has no terminal, so
    # it keeps the dialog; a manual run is asked in the terminal it was typed
    # in, which is also the only frontend a plain SSH session can answer.
    if [ "$PROMPT_MODE" = auto ]; then
        if [ -t 0 ]; then PROMPT_MODE=cli; else PROMPT_MODE=gui; fi
    fi

    if [ "$PROMPT_MODE" = cli ] && [ ! -t 0 ]; then
        log "ERROR: --cli requested but stdin is not a terminal."
        notify critical "Backup unavailable" \
            "--cli needs a terminal. Use --yes for an unattended run."
        exit 1
    fi
    if [ "$PROMPT_MODE" = gui ] && ! command -v zenity >/dev/null 2>&1; then
        if [ -t 0 ]; then
            log "zenity is missing: asking in the terminal instead."
            PROMPT_MODE=cli
        else
            log "ERROR: zenity is missing and there is no terminal to ask in."
            notify critical "Backup unavailable" \
                "zenity is missing. Use --yes for an unattended run."
            exit 1
        fi
    fi

    TOTAL_FILES=$(find "$SOURCE_ROOT" -type f | wc -l)
    TOTAL_SIZE=$(du -sh "$SOURCE_ROOT" | cut -f1)

    JOB_LIST=""
    for label in "${JOB_LABELS[@]}"; do
        JOB_LIST="$JOB_LIST
  • $label"
    done

    if [ "$PROMPT_MODE" = gui ]; then
        SKIP_BLOCK=""
        [ -n "$SKIPPED_REPORT" ] && SKIP_BLOCK="\n\n<b>Skipped:</b><tt>$SKIPPED_REPORT</tt>"
        VERSION_NOTE=""
        [ -n "$NEWER_VERSION" ] && \
            VERSION_NOTE="\n\n⚠️  <b>Update available:</b> $CLI_VERSION → $NEWER_VERSION"

        zenity --question \
            --title="Proton Drive backup" \
            --icon-name=folder-remote \
            --width=520 \
            --timeout="$CONFIRM_TIMEOUT" \
            --ok-label="Back up" \
            --cancel-label="Later" \
            --text="Start the backup to Proton Drive?\n\n<b>${#JOB_SRCS[@]} destination(s):</b><tt>$JOB_LIST</tt>\n\n<b>Local total:</b> $TOTAL_FILES files ($TOTAL_SIZE)\n\n<small>Only modified files will be transferred.</small>$SKIP_BLOCK$VERSION_NOTE" \
            2>/dev/null
        ANSWER=$?
    else
        {
            printf '\nBackup to Proton Drive\n\n'
            printf '  %d destination(s):%s\n\n' "${#JOB_SRCS[@]}" "$JOB_LIST"
            printf '  Local total: %s files (%s)\n' "$TOTAL_FILES" "$TOTAL_SIZE"
            printf '  Only modified files will be transferred.\n'
            [ -n "$SKIPPED_REPORT" ] && printf '\n  Skipped:%s\n' "$SKIPPED_REPORT"
            [ -n "$NEWER_VERSION" ] && \
                printf '\n  Update available: %s -> %s\n' "$CLI_VERSION" "$NEWER_VERSION"
            printf '\n'
        } >&2

        # read -t returns >128 on timeout and 1 on EOF: the first is the same
        # unattended silence zenity reports as 5, the second a closed stdin,
        # which is a decline and not something to wait five minutes for.
        REPLY_LINE=""
        read -r -t "$CONFIRM_TIMEOUT" \
            -p "Back up now? [y/N] (no answer within ${CONFIRM_TIMEOUT}s = no) " \
            REPLY_LINE
        RC=$?
        printf '\n' >&2
        if [ "$RC" -gt 128 ]; then
            ANSWER=5
        elif [ "$RC" -ne 0 ]; then
            ANSWER=1
        else
            case "$REPLY_LINE" in
                y|Y|yes|Yes|YES) ANSWER=0 ;;
                *)               ANSWER=1 ;;
            esac
        fi
    fi

    case "$ANSWER" in
        0) log "Confirmed by the user (${#JOB_SRCS[@]} job(s))." ;;
        5) log "ABORT: no answer within ${CONFIRM_TIMEOUT}s."; exit 0 ;;
        *) log "ABORT: declined by the user."; exit 0 ;;
    esac
fi

# --- Remote path handling -----------------------------------------------------
# Proton UID of a remote node, empty when it does not exist.
# The ^\s*uid anchor avoids capturing parentUid, present in the same output.
remote_uid() {
    "$PROTON_DRIVE" filesystem info "$1" 2>/dev/null \
        | grep -oP "^\s*uid: '\K[^']+" | head -1
}

# Fingerprints recorded during previous backups.
declare -A KNOWN_UID=()
if [ -f "$DEST_UIDS" ]; then
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] && KNOWN_UID["$k"]="$v"
    done < "$DEST_UIDS"
fi
declare -A NEW_UID=()

# The CLI only addresses nodes by path (a UID is rejected as a target). A folder
# renamed or moved on the Drive side therefore leaves its path vacant, and a
# naive backup would recreate it and re-upload everything: the content would end
# up split between the old folder and a new one. Comparing the current UID with
# the recorded one turns that silent duplication into an explicit alert.
# Codes: 0 = usable, 1 = broken, 2 = first use.
check_dest_identity() {
    local dest="$1" known current
    known="${KNOWN_UID[$dest]:-}"
    current="$(remote_uid "$dest")"

    if [ -z "$known" ]; then
        return 2
    fi

    if [ -z "$current" ]; then
        DEST_ISSUE="the remote folder was renamed, moved or deleted"
        return 1
    fi

    if [ "$current" != "$known" ]; then
        DEST_ISSUE="a different folder now occupies this path"
        return 1
    fi

    return 0
}

# create-folder is not idempotent (it fails when the name already exists), hence
# the prior `info` probe. Walks up the tree so missing intermediate levels are
# created too.
ensure_remote_path() {
    local path="$1" parent leaf

    # Drive roots: always present, never to be created
    case "$path" in
        /my-files|/devices|/shared-with-me|/|"") return 0 ;;
    esac

    if "$PROTON_DRIVE" filesystem info "$path" >/dev/null 2>&1; then
        return 0
    fi

    parent="$(dirname "$path")"
    leaf="$(basename "$path")"

    ensure_remote_path "$parent" || return 1

    if "$PROTON_DRIVE" filesystem create-folder "$parent" "$leaf" >/dev/null 2>&1; then
        log "  created remote folder: $path"
        return 0
    fi
    # Possible race with another run: re-probe before declaring failure
    "$PROTON_DRIVE" filesystem info "$path" >/dev/null 2>&1
}

# --- Transfer -----------------------------------------------------------------
notify normal "Backup running" "${#JOB_SRCS[@]} destination(s) to Proton Drive..."
# Each upload's output is captured separately: we need to inspect it to decide
# whether to retry, while still keeping it in the log.
UPLOAD_OUT="$(mktemp)"
trap 'rm -f "$UPLOAD_OUT"' EXIT
START=$(date +%s)
FAILED=0
DONE=0
BROKEN_REPORT=""

shopt -s dotglob nullglob
for i in "${!JOB_SRCS[@]}"; do
    src="${JOB_SRCS[$i]}"
    dest="${JOB_DESTS[$i]}"
    log "[$((i+1))/${#JOB_SRCS[@]}] ${JOB_LABELS[$i]}"

    DEST_ISSUE=""
    check_dest_identity "$dest"
    case $? in
        1)
            # Deliberately not recreated: that would split the content in two.
            log "  ALERT: $DEST_ISSUE ($dest). Destination skipped."
            BROKEN_REPORT="$BROKEN_REPORT
  • $dest: $DEST_ISSUE"
            # Fingerprint kept: without it the next run would assume a first use
            # and duplicate silently.
            NEW_UID["$dest"]="${KNOWN_UID[$dest]}"
            FAILED=$((FAILED+1))
            continue
            ;;
        2) log "  (first backup to this destination)" ;;
    esac

    if ! ensure_remote_path "$dest"; then
        log "  FAILED: cannot create or reach $dest"
        FAILED=$((FAILED+1))
        continue
    fi

    # Fingerprint taken as soon as the folder is in place, regardless of the
    # transfer outcome: its identity is valid either way.
    NEW_UID["$dest"]="$(remote_uid "$dest")"

    # The source's CONTENTS are uploaded, which is what allows the remote folder
    # to carry a different name from the local one.
    if [ "$src" = ".ROOTFILES" ]; then
        items=()
        for f in "$SOURCE_ROOT"/*; do [ -f "$f" ] && items+=("$f"); done
    else
        items=("$src"/*)
    fi

    if [ ${#items[@]} -eq 0 ]; then
        log "  (empty, skipped)"
        continue
    fi

    # create-new-revision, not replace: replace trashes the remote file and
    # uploads a new node, so every modified file loses its UID and its history
    # and leaves a copy in the trash, run after run. A revision keeps the node.
    if "$PROTON_DRIVE" filesystem upload \
        --file-conflict-strategy create-new-revision \
        --folder-conflict-strategy merge \
        "${items[@]}" "$dest" > "$UPLOAD_OUT" 2>&1; then
        cat "$UPLOAD_OUT" >> "$LOG_FILE"
        DONE=$((DONE+1))
    else
        cat "$UPLOAD_OUT" >> "$LOG_FILE"
        # A single file with an image extension but invalid content (corrupt,
        # truncated, misnamed) fails the whole batch. Rather than disabling
        # thumbnails everywhere, retry without them only in that case.
        if grep -q 'Failed to generate thumbnails' "$UPLOAD_OUT"; then
            log "  Thumbnail generation failed on one file: retrying without thumbnails."
            if "$PROTON_DRIVE" filesystem upload \
                --skip-thumbnails \
                --file-conflict-strategy create-new-revision \
                --folder-conflict-strategy merge \
                "${items[@]}" "$dest" >> "$LOG_FILE" 2>&1; then
                log "  OK without thumbnails."
                DONE=$((DONE+1))
            else
                log "  FAILED: transfer to $dest (even without thumbnails)"
                FAILED=$((FAILED+1))
            fi
        else
            log "  FAILED: transfer to $dest"
            FAILED=$((FAILED+1))
        fi
    fi
done
shopt -u dotglob nullglob

# Rewrite the fingerprints. Only this run's destinations are kept, so entries
# removed from mappings.conf disappear on their own — except under --only,
# where a single destination was visited: the others are carried over as they
# were, or the next full run would take every one of them for a first backup.
if [ -n "$ONLY" ]; then
    for d in "${!KNOWN_UID[@]}"; do
        [ -n "${NEW_UID[$d]:-}" ] || NEW_UID["$d"]="${KNOWN_UID[$d]}"
    done
fi
: > "$DEST_UIDS"
for d in "${!NEW_UID[@]}"; do
    [ -n "${NEW_UID[$d]}" ] && printf '%s\t%s\n' "$d" "${NEW_UID[$d]}" >> "$DEST_UIDS"
done

ELAPSED=$(( $(date +%s) - START ))

# --- Outcome ------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    log "SUCCESS: $DONE destination(s) in ${ELAPSED}s."
    # Timestamp read by proton-drive-backup-check.sh (3-day staleness watch).
    # Written only when EVERY destination succeeded: a partial success must not
    # suggest the whole set is up to date — nor a --only run, for the same reason.
    if [ -z "$ONLY" ]; then
        date +%s > "$STAMP_SUCCESS"
        notify normal "Backup complete" \
            "$DONE destination(s) processed in ${ELAPSED}s."
    else
        notify low "Backup of $ONLY complete" "${ELAPSED}s."
    fi
    exit 0
else
    log "PARTIAL FAILURE: $DONE succeeded, $FAILED failed, ${ELAPSED}s."
    if [ -n "$BROKEN_REPORT" ]; then
        # Distinct from a transfer outage: this needs a decision from the user,
        # not a retry.
        notify critical "Proton Drive destination not found" \
            "Nothing was recreated, to avoid duplicating your content.
$BROKEN_REPORT

Restore the name on the Drive, or update mappings.conf."
    else
        notify critical "Backup incomplete" \
            "$FAILED of $((DONE+FAILED)) destination(s) failed.
Details: $LOG_FILE"
    fi
    exit 1
fi
