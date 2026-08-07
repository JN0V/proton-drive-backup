#!/usr/bin/env bash
#
# Backs up ~/Documents/drive to Proton Drive, following the mappings declared
# in ~/.config/proton-drive-backup/mappings.conf.
#
# Started by the systemd timer proton-drive-backup.timer, with a graphical
# confirmation prompt. See also proton-drive-backup-check.sh (staleness alert).
#
set -uo pipefail

# ---------- Configuration ----------
PROTON_DRIVE="$HOME/bin/proton-drive"
SOURCE_ROOT="$HOME/Documents/drive"
MAPPINGS_FILE="$HOME/.config/proton-drive-backup/mappings.conf"
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"   # epoch of the last SUCCESSFUL backup
DEST_UIDS="$LOG_DIR/dest-uids"          # <remote path><TAB><uid>: rename detection
MAX_LOG_BYTES=1048576                   # 1 MiB, then simple rotation
CONFIRM_TIMEOUT=300                     # seconds; no answer -> do nothing
VERSION_INDEX="https://proton.me/download/drive/cli/index.html"
VERSION_TIMEOUT=8                       # max seconds for the version check
# -----------------------------------

# Dry-run mode: print the plan (resolved mappings) and exit, with no prompt and
# no transfer. Used to validate mappings.conf before applying it.
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$LOG_DIR"

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

notify() {
    # $1 = urgency (normal|critical), $2 = title, $3 = body
    notify-send --app-name="Proton Drive" --urgency="$1" "$2" "$3" 2>/dev/null || true
}

# Rotate before writing
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

log "--- Timer fired ---"

# --- Preflight checks ---------------------------------------------------------
if [ ! -x "$PROTON_DRIVE" ]; then
    log "ERROR: binary missing or not executable: $PROTON_DRIVE"
    notify critical "Backup unavailable" "Proton Drive CLI not found."
    exit 1
fi

if [ ! -d "$SOURCE_ROOT" ]; then
    log "ERROR: source directory missing: $SOURCE_ROOT"
    notify critical "Backup unavailable" "Directory missing: $SOURCE_ROOT"
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
    exit 0
fi

if [ ${#JOB_SRCS[@]} -eq 0 ]; then
    log "ABORT: nothing to back up."
    notify normal "Backup cancelled" "Nothing to send from $SOURCE_ROOT."
    exit 0
fi

# --- Valid session? -----------------------------------------------------------
# Checked before the prompt, so the user is never asked to click for nothing.
if ! "$PROTON_DRIVE" filesystem list /my-files >/dev/null 2>&1; then
    log "ERROR: Proton Drive session missing or expired."
    notify critical "Proton Drive: sign-in required" \
        "Run 'proton-drive auth login' in a terminal."
    exit 1
fi

# --- Version check ------------------------------------------------------------
# Informational only: no update is ever installed automatically, and a network
# failure must never prevent the backup from running.
VERSION_NOTE=""
check_version() {
    local local_v remote_v newest
    local_v=$("$PROTON_DRIVE" version 2>/dev/null \
        | grep -oP 'cli-drive@\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$local_v" ]; then
        log "VERSION: cannot read the local version."
        return
    fi

    remote_v=$(curl -sL --max-time "$VERSION_TIMEOUT" "$VERSION_INDEX" 2>/dev/null \
        | grep -oP '<h1>Proton Drive CLI \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$remote_v" ]; then
        log "VERSION: check failed (network or page unavailable). Local: $local_v"
        return
    fi

    if [ "$local_v" = "$remote_v" ]; then
        log "VERSION: up to date ($local_v)."
        return
    fi

    newest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -1)
    if [ "$newest" = "$remote_v" ]; then
        log "VERSION: update available ($local_v -> $remote_v)."
        VERSION_NOTE="\n\n⚠️  <b>Update available:</b> $local_v → $remote_v"
        notify normal "Proton Drive CLI: update available" \
            "Version $remote_v is available (installed: $local_v)."
    else
        log "VERSION: local ($local_v) is newer than published ($remote_v)."
    fi
}
check_version

# --- Confirmation -------------------------------------------------------------
TOTAL_FILES=$(find "$SOURCE_ROOT" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$SOURCE_ROOT" | cut -f1)

JOB_LIST=""
for label in "${JOB_LABELS[@]}"; do
    JOB_LIST="$JOB_LIST
  • $label"
done

SKIP_BLOCK=""
[ -n "$SKIPPED_REPORT" ] && SKIP_BLOCK="\n\n<b>Skipped:</b><tt>$SKIPPED_REPORT</tt>"

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

case "$ANSWER" in
    0) log "Confirmed by the user (${#JOB_SRCS[@]} job(s))." ;;
    5) log "ABORT: no answer within ${CONFIRM_TIMEOUT}s."; exit 0 ;;
    *) log "ABORT: declined by the user."; exit 0 ;;
esac

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

    if "$PROTON_DRIVE" filesystem upload \
        --file-conflict-strategy replace \
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
                --file-conflict-strategy replace \
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
# removed from mappings.conf disappear on their own.
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
    # suggest the whole set is up to date.
    date +%s > "$STAMP_SUCCESS"
    notify normal "Backup complete" \
        "$DONE destination(s) processed in ${ELAPSED}s."
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
