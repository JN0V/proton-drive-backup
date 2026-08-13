#!/usr/bin/env bash
#
# Searches Proton Drive by name.
#
# The CLI (0.8.0) has no search command: the only way to find a file is to walk
# the remote tree with `filesystem list` and match locally. One API call per
# folder, around 1.5 s each, which makes a live walk far too slow to repeat.
# Results are therefore cached in an index and searches read from that.
#
# Interactive and read-only, unlike proton-drive-backup.sh. Deliberately a
# separate script: that one is driven by systemd, upload-only, and its exit
# codes are watched.
#
set -uo pipefail

# ---------- Configuration ----------
PROTON_DRIVE="$HOME/bin/proton-drive"
STATE_DIR="$HOME/.local/state/proton-drive-backup"
INDEX="$STATE_DIR/index.tsv"        # <path><TAB><type><TAB><size><TAB><mtime>
INDEX_META="$STATE_DIR/index.meta"  # coverage and freshness of the above
DEFAULT_ROOT="/my-files"
STALE_DAYS=7                        # beyond this, the index age is flagged
# Roots walked by --all. /photos is absent because it is not listable at all
# (see the note on photos in the usage text below); /trash because deleted
# nodes in every result would be noise. Reach it deliberately with -p /trash.
ALL_ROOTS=(/my-files /shared-by-me /shared-with-me /devices)
# -----------------------------------

usage() {
    cat <<'EOF'
Usage: proton-drive-find.sh [OPTIONS] TERM...

Searches the Proton Drive index by name. Every TERM must appear in the path
(case-insensitive, plain substring, no globbing needed).

  proton-drive-find.sh invoice 2024
  proton-drive-find.sh .pdf --type f
  proton-drive-find.sh --refresh

Options:
  -r, --refresh     Rebuild the index before searching (or on its own).
  -l, --live        Walk the Drive now instead of reading the index. Slow, but
                    always current, and needs no prior indexing.
  -p, --path PATH   Restrict to a subtree (default: /my-files). Also selects
                    the root walked by --refresh/--live.
  -a, --all         Also cover the shared and device roots, not just /my-files.
                    Deleted files stay out; reach them with -p /trash.
  -t, --type f|d    Files only, or folders only.
      --paths       Print bare paths, one per line, for piping into
                    `proton-drive filesystem download`.
  -h, --help        This help.

The index lives in ~/.local/state/proton-drive-backup/index.tsv and is never
refreshed automatically: a full walk costs one API call per folder.

Photos: images under /photos cannot be searched. `photo timeline` returns UIDs
and capture times but no names, and the CLI rejects a UID as a path. Only the
copies present in the /my-files tree are indexed.
EOF
}

# --- Arguments ----------------------------------------------------------------
REFRESH=0
LIVE=0
ALL=0
PATHS_ONLY=0
TYPE=""
ROOT=""
declare -a TERMS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--refresh) REFRESH=1 ;;
        -l|--live)    LIVE=1 ;;
        -a|--all)     ALL=1 ;;
        --paths)      PATHS_ONLY=1 ;;
        -p|--path)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            ROOT="${2%/}"; shift
            ;;
        -t|--type)
            [ $# -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
            case "$2" in
                f|file|files)     TYPE="file" ;;
                d|dir|folder|folders) TYPE="folder" ;;
                *) echo "Unknown type: $2 (expected f or d)" >&2; exit 2 ;;
            esac
            shift
            ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; while [ $# -gt 0 ]; do TERMS+=("$1"); shift; done ;;
        -*)           echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            TERMS+=("$1") ;;
    esac
    shift
done

if [ ${#TERMS[@]} -eq 0 ] && [ "$REFRESH" -eq 0 ]; then
    usage >&2
    exit 2
fi

# --- Preflight ----------------------------------------------------------------
if [ ! -x "$PROTON_DRIVE" ]; then
    echo "Proton Drive CLI not found: $PROTON_DRIVE" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required (the CLI's JSON output is parsed with it)." >&2
    exit 1
fi

mkdir -p "$STATE_DIR"

# The session is only needed when actually talking to the Drive; a search over
# an existing index works offline.
need_session() {
    if ! "$PROTON_DRIVE" filesystem list "$DEFAULT_ROOT" >/dev/null 2>&1; then
        echo "Proton Drive session missing or expired." >&2
        echo "Run: proton-drive auth login" >&2
        exit 1
    fi
}

# --- Walking the remote tree --------------------------------------------------
# Emits one TSV line per node on stdout. Breadth-first over an explicit queue
# rather than recursion, so progress can be reported and depth is not a concern.
#
# PROGRESS=1 draws a counter on stderr; left off in live mode, where matches are
# streamed to stdout as they are found and a redrawn line would interleave.
PROGRESS=0
WALK_FOLDERS=0
WALK_ENTRIES=0
WALK_FAILED=0

walk() {
    local -a queue=("$@")
    local head=0 dir out base

    while [ "$head" -lt "${#queue[@]}" ]; do
        dir="${queue[$head]}"
        head=$((head + 1))

        if ! out="$("$PROTON_DRIVE" filesystem list -j "$dir" 2>&1)"; then
            # A single unreadable folder must not abort the whole walk: report
            # it and carry on, the rest of the tree is still worth indexing.
            printf '\rWARN: cannot list %s\n' "$dir" >&2
            WALK_FAILED=$((WALK_FAILED + 1))
            continue
        fi

        WALK_FOLDERS=$((WALK_FOLDERS + 1))

        # A root path is "/x", so a plain concatenation never doubles a slash.
        base="$dir"
        [ "$base" = "/" ] && base=""

        # An undecryptable name comes back as {"ok":false,...} with no value;
        # the node is still listed so the gap is visible rather than silent.
        # @tsv escapes any tab or newline inside a name, so lines stay intact.
        #
        # The UID is deliberately not kept: it would be four fifths of the file
        # and nothing can consume it, since the CLI rejects a UID as a path.
        while IFS=$'\t' read -r p t s m; do
            [ -z "$p" ] && continue
            WALK_ENTRIES=$((WALK_ENTRIES + 1))
            printf '%s\t%s\t%s\t%s\n' "$p" "$t" "$s" "$m"
            [ "$t" = "folder" ] && queue+=("$p")
        done < <(printf '%s' "$out" | jq -r --arg base "$base" '
            .[]? | [ $base + "/" + (.name.value // "<name unavailable>"),
                     .type,
                     (.totalStorageSize // 0),
                     (.modificationTime // "") ] | @tsv' 2>/dev/null)

        if [ "$PROGRESS" -eq 1 ]; then
            printf '\r  %d folder(s) scanned, %d entries...' \
                "$WALK_FOLDERS" "$WALK_ENTRIES" >&2
        fi
    done
}

# --- Filters ------------------------------------------------------------------
# Each term is tested against the path only. Matching the whole line would let
# "2024" hit a modification date or a UID and return noise.
match_terms() {
    if [ $# -eq 0 ]; then
        cat
    else
        local t="${1,,}"
        shift
        awk -F'\t' -v t="$t" 'index(tolower($1), t) > 0' | match_terms "$@"
    fi
}

filter_type() {
    [ -z "$TYPE" ] && { cat; return; }
    awk -F'\t' -v ty="$TYPE" '$2 == ty'
}

filter_prefix() {
    local p="$1"
    [ -z "$p" ] && { cat; return; }
    awk -F'\t' -v p="$p" 'substr($1, 1, length(p)) == p'
}

# --- Output -------------------------------------------------------------------
render() {
    local path type size mtime n=0 kind human

    while IFS=$'\t' read -r path type size mtime; do
        [ -z "$path" ] && continue
        n=$((n + 1))

        if [ "$PATHS_ONLY" -eq 1 ]; then
            printf '%s\n' "$path"
            continue
        fi

        if [ "$type" = "folder" ]; then
            kind="d"; human="-"
        else
            kind="f"
            human="$(numfmt --to=iec "$size" 2>/dev/null)" || human="$size"
        fi
        printf '  %s  %8s  %s  %s\n' "$kind" "$human" "${mtime:0:10}" "$path"
    done

    if [ "$PATHS_ONLY" -eq 0 ]; then
        if [ "$n" -eq 0 ]; then
            printf '\n  No match.\n\n' >&2
        else
            printf '\n  %d result(s).\n\n' "$n" >&2
        fi
    fi
    [ "$n" -gt 0 ]
}

# --- Index rebuild ------------------------------------------------------------
declare -a ROOTS=()
if [ "$ALL" -eq 1 ]; then
    ROOTS=("${ALL_ROOTS[@]}")
elif [ -n "$ROOT" ]; then
    ROOTS=("$ROOT")
else
    ROOTS=("$DEFAULT_ROOT")
fi

rebuild_index() {
    need_session

    # Written to a temp file and moved into place: a walk interrupted halfway
    # must not leave a truncated index that later searches would trust.
    local tmp
    tmp="$(mktemp "$INDEX.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
    trap 'rm -f "$tmp"' EXIT

    printf 'Indexing %s ...\n' "${ROOTS[*]}" >&2
    PROGRESS=1
    walk "${ROOTS[@]}" > "$tmp"
    PROGRESS=0
    printf '\r%*s\r' 60 '' >&2   # wipe the progress line before the summary

    if [ "$WALK_FOLDERS" -eq 0 ]; then
        echo "Nothing could be listed, index left untouched." >&2
        exit 1
    fi

    mv -f "$tmp" "$INDEX"
    trap - EXIT

    {
        printf 'built=%s\n' "$(date +%s)"
        printf 'roots=%s\n' "$(IFS=,; printf '%s' "${ROOTS[*]}")"
        printf 'folders=%s\nentries=%s\nfailed=%s\n' \
            "$WALK_FOLDERS" "$WALK_ENTRIES" "$WALK_FAILED"
    } > "$INDEX_META"

    printf '  %d folder(s), %d entries indexed.\n' "$WALK_FOLDERS" "$WALK_ENTRIES" >&2
    if [ "$WALK_FAILED" -gt 0 ]; then
        printf '  %d folder(s) could not be listed and are missing from the index.\n' \
            "$WALK_FAILED" >&2
    fi
    printf '\n' >&2
}

# --- Live search --------------------------------------------------------------
if [ "$LIVE" -eq 1 ]; then
    need_session
    printf 'Walking %s (no index used)...\n\n' "${ROOTS[*]}" >&2
    walk "${ROOTS[@]}" | filter_type | match_terms "${TERMS[@]}" | render
    exit $?
fi

# --- Indexed search -----------------------------------------------------------
[ "$REFRESH" -eq 1 ] && rebuild_index

if [ ${#TERMS[@]} -eq 0 ]; then
    exit 0   # --refresh on its own
fi

if [ ! -s "$INDEX" ]; then
    echo "No index yet." >&2
    echo "Build one with --refresh (a few minutes), or search live with --live." >&2
    exit 1
fi

# Freshness and coverage are reported, never silently assumed: the index is only
# ever as current as the last explicit refresh.
INDEX_ROOTS=""
BUILT=""
if [ -f "$INDEX_META" ]; then
    BUILT="$(sed -n 's/^built=//p' "$INDEX_META")"
    INDEX_ROOTS="$(sed -n 's/^roots=//p' "$INDEX_META")"
fi

if [ -n "$BUILT" ] && [[ "$BUILT" =~ ^[0-9]+$ ]]; then
    AGE_DAYS=$(( ( $(date +%s) - BUILT ) / 86400 ))
    NOTE="index from $(date -d "@$BUILT" '+%Y-%m-%d %H:%M')"
    [ "$AGE_DAYS" -ge "$STALE_DAYS" ] && \
        NOTE="$NOTE — ${AGE_DAYS} days old, consider --refresh"
    printf '\n  %s\n\n' "$NOTE" >&2
fi

# Asking for a subtree the index never covered would otherwise return an empty
# result that reads like "the file is not on the Drive".
if [ -n "$ROOT" ] && [ -n "$INDEX_ROOTS" ]; then
    COVERED=0
    IFS=',' read -ra IR <<< "$INDEX_ROOTS"
    for r in "${IR[@]}"; do
        case "$ROOT" in "$r"|"$r"/*) COVERED=1 ;; esac
    done
    if [ "$COVERED" -eq 0 ]; then
        printf '  WARNING: %s is outside the indexed roots (%s).\n' \
            "$ROOT" "$INDEX_ROOTS" >&2
        printf '           Refresh with: --refresh --path %s\n\n' "$ROOT" >&2
    fi
fi

filter_prefix "$ROOT" < "$INDEX" | filter_type | match_terms "${TERMS[@]}" | render
exit $?
