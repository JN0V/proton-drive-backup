# Shared by the scripts in bin/: per-host settings and notifications.
#
# Sourced, never executed. The scripts reach it through their own symlink
# target, so it stays in the repository like everything else.

# ---------- Host settings ----------
# Everything that differs between a desktop and a headless host lives in one
# optional file. Absent, or with every line commented out, the defaults below
# apply and the tool behaves exactly as it always has.
CONF_FILE="$HOME/.config/proton-drive-backup/backup.conf"
CONF_KEYS="SOURCE_ROOT NOTIFY NOTIFY_COMMAND"
CONF_IGNORED=""      # unknown keys and malformed lines, for the caller to log

# KEY=value lines, read rather than sourced: a typo in a settings file must not
# be able to run anything. A value may be quoted; unquoted, a # at its start or
# after a space starts a comment. A leading ~/ expands to the home directory.
#
# What gets ignored is reported by line number and key only, never by content:
# the offending line may well hold a secret, and the log is not private.
if [ -f "$CONF_FILE" ]; then
    _n=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _n=$((_n + 1))
        [[ "$_line" =~ ^[[:space:]]*(#|$) ]] && continue
        if ! [[ "$_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
            CONF_IGNORED="$CONF_IGNORED line $_n (not KEY=value);"
            continue
        fi
        _key="${BASH_REMATCH[1]}"
        _value="${BASH_REMATCH[2]}"
        case "$_value" in
            \"*|\'*)
                _q="${_value:0:1}"
                _value="${_value:1}"
                if [[ "$_value" != *"$_q"* ]]; then
                    CONF_IGNORED="$CONF_IGNORED line $_n (unclosed quote);"
                    continue
                fi
                _value="${_value%%"$_q"*}" ;;
            *)
                # The space prepended lets a value made only of a comment
                # ("KEY= # later") come out empty rather than as the comment.
                _value=" $_value"
                _value="${_value%%[[:space:]]#*}"
                _value="${_value# }"
                _value="${_value%"${_value##*[![:space:]]}"}" ;;
        esac
        case "$_value" in
            "~/"*) _value="$HOME/${_value#"~/"}" ;;
        esac
        case " $CONF_KEYS " in
            *" $_key "*) printf -v "CONF_$_key" '%s' "$_value" ;;
            *)           CONF_IGNORED="$CONF_IGNORED line $_n (unknown key $_key);" ;;
        esac
    done < "$CONF_FILE"
    unset _n _line _key _value _q
fi

# Value of a setting: PROTON_DRIVE_BACKUP_<KEY> from the environment first, so a
# one-off run can override it, then the file, then the given default.
conf() {
    local env="PROTON_DRIVE_BACKUP_$1" file="CONF_$1"
    if [ -n "${!env:-}" ]; then
        printf '%s' "${!env}"
    elif [ -n "${!file:-}" ]; then
        printf '%s' "${!file}"
    else
        printf '%s' "$2"
    fi
}

# ---------- Notifications ----------
# Space-separated list of backends:
#   desktop  notify-send, the default
#   command  NOTIFY_COMMAND, an executable of your own: the way to reach a phone,
#            a chat or a mailbox from a host without a desktop
#   none     nothing
NOTIFY_BACKENDS="$(conf NOTIFY desktop)"
NOTIFY_COMMAND="$(conf NOTIFY_COMMAND "")"
NOTIFY_TIMEOUT=30                      # seconds; a notification must never hold a run

_notify_log() {
    declare -F log >/dev/null && log "$@"
    return 0
}

# NOTIFY_COMMAND URGENCY TITLE BODY, URGENCY being low, normal or critical. Exit
# status 0 means delivered. The tool knows nothing of the service behind it,
# which keeps any service reachable and its credentials out of backup.conf.
#
# A single executable path, called directly: no arguments are split from it and
# nothing is evaluated, so the settings file never turns into shell code. It
# must be absolute, like SOURCE_ROOT: a relative one would be checked against
# the working directory and then looked up in PATH, two different answers.
# Its output is discarded rather than logged, since it may echo a secret.
notify_command() {
    local rc
    if [ -z "$NOTIFY_COMMAND" ]; then
        _notify_log "NOTIFY: 'command' is listed but NOTIFY_COMMAND is empty."
        return 1
    fi
    if [[ "$NOTIFY_COMMAND" != /* ]] || [ ! -f "$NOTIFY_COMMAND" ] || [ ! -x "$NOTIFY_COMMAND" ]; then
        _notify_log "NOTIFY: NOTIFY_COMMAND must be an absolute path to an executable file: $NOTIFY_COMMAND"
        return 1
    fi
    # -k: a command that ignores SIGTERM is killed 5 seconds later.
    timeout -k 5 "$NOTIFY_TIMEOUT" "$NOTIFY_COMMAND" "$1" "$2" "$3" </dev/null >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            124) _notify_log "NOTIFY: $NOTIFY_COMMAND timed out after ${NOTIFY_TIMEOUT}s." ;;
            137) _notify_log "NOTIFY: $NOTIFY_COMMAND ignored the timeout and was killed." ;;
            *)   _notify_log "NOTIFY: $NOTIFY_COMMAND failed (exit $rc)." ;;
        esac
        return 1
    fi
    return 0
}

# Non-zero when a backend that can tell (command) failed to deliver, or when
# NOTIFY names no known backend at all: the watchdog must not count an alert
# nobody received. notify-send is fire-and-forget, as it always was.
notify() {
    # $1 = urgency (low|normal|critical), $2 = title, $3 = body, $4 = icon (optional)
    local backend backends icon=() rc=0 known=0
    [ -n "${4:-}" ] && icon=(--icon="$4")
    # Split into an array, not with an unquoted expansion: that would also glob.
    read -r -a backends <<< "$NOTIFY_BACKENDS"
    for backend in "${backends[@]}"; do
        case "$backend" in
            desktop)
                known=1
                notify-send --app-name="Proton Drive" --urgency="$1" "${icon[@]}" \
                    "$2" "$3" 2>/dev/null || true ;;
            command) known=1; notify_command "$1" "$2" "$3" || rc=1 ;;
            none)    known=1 ;;
            *)       _notify_log "NOTIFY: unknown backend '$backend' ignored." ;;
        esac
    done
    # "desktop,command" is one unknown word: nothing was sent, and saying
    # otherwise would let the watchdog believe its alert went out.
    if [ "$known" -eq 0 ]; then
        _notify_log "NOTIFY: no known backend in '$NOTIFY_BACKENDS', nothing sent."
        rc=1
    fi
    # A notification is invisible to someone watching a terminal, and a CLI run
    # would otherwise report nothing at all — not even its outcome.
    [ -t 2 ] && printf '\n%s\n%s\n' "$2" "$3" >&2
    return "$rc"
}
