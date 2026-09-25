# Shared by the scripts in bin/: per-host settings.
#
# Sourced, never executed. The scripts reach it through their own symlink
# target, so it stays in the repository like everything else.

# ---------- Host settings ----------
# Everything that differs between a desktop and a headless host lives in one
# optional file. Absent, or with every line commented out, the defaults below
# apply and the tool behaves exactly as it always has.
CONF_FILE="$HOME/.config/proton-drive-backup/backup.conf"
CONF_KEYS="SOURCE_ROOT"
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
