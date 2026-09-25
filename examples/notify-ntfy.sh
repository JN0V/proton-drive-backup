#!/usr/bin/env bash
#
# Example notification command for proton-drive-backup: publishes to an ntfy
# topic (https://ntfy.sh, or a server of your own). Needs curl only.
#
# In ~/.config/proton-drive-backup/backup.conf:
#   NOTIFY=command
#   NOTIFY_COMMAND=~/bin/notify-ntfy.sh
#
# Its own settings, in ~/.config/proton-drive-backup/ntfy.conf (chmod 600 if it
# holds a token), or in the environment:
#   NTFY_URL=https://ntfy.example.org/proton-backup
#   NTFY_TOKEN=tk_...            # only if the server requires one
#
# Called as: notify-ntfy.sh URGENCY TITLE BODY, URGENCY being low, normal or
# critical. Exits 0 once the server has accepted the message.
#
set -uo pipefail

CONF="$HOME/.config/proton-drive-backup/ntfy.conf"

# KEY=value, last one wins; read, not sourced. Same rules as backup.conf: a
# value may be quoted; unquoted, a # at its start or after a space starts a
# comment.
read_key() {
    local line value q found=""
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        value="${BASH_REMATCH[1]%$'\r'}"
        case "$value" in
            \"*|\'*)
                q="${value:0:1}"
                value="${value:1}"
                value="${value%%"$q"*}" ;;
            *)
                value=" $value"
                value="${value%%[[:space:]]#*}"
                value="${value# }"
                value="${value%"${value##*[![:space:]]}"}" ;;
        esac
        found="$value"
    done < "$CONF"
    printf '%s' "$found"
}
if [ -f "$CONF" ]; then
    NTFY_URL="${NTFY_URL:-$(read_key NTFY_URL)}"
    NTFY_TOKEN="${NTFY_TOKEN:-$(read_key NTFY_TOKEN)}"
fi
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

[ $# -eq 3 ] || { echo "usage: $0 URGENCY TITLE BODY" >&2; exit 2; }

server="${NTFY_URL%/*}"
topic="${NTFY_URL##*/}"
# ntfy topic names are letters, digits, - and _: anything else, a query string
# included, is a URL this script would misread.
if ! [[ "$topic" =~ ^[-_A-Za-z0-9]{1,64}$ ]] || [[ "$server" != *://* ]]; then
    echo "NTFY_URL '$NTFY_URL' is not a topic URL (https://server/topic)" >&2
    exit 1
fi

# JSON string literal, built without jq. Backslash and quote first, then the
# usual short escapes, then every other control character, which JSON forbids
# raw: a folder name can carry one, and the whole message would be refused.
json_str() {
    local s="$1" i c
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    for i in {1..31}; do
        printf -v c "\\x$(printf %02x "$i")"
        s="${s//"$c"/$(printf '\\u%04x' "$i")}"
    done
    printf '"%s"' "$s"
}

# Only what needs acting on may buzz a phone: routine messages arrive silently,
# and the ntfy app's per-topic minimum priority can hide them altogether.
tags=""
case "$1" in
    critical) priority=4; tags=', "tags": ["warning"]' ;;
    low)      priority=1 ;;
    *)        priority=2 ;;
esac

# Published as JSON rather than through the Title header: titles carry folder
# names, and HTTP headers do not carry UTF-8 reliably.
payload="{\"topic\": $(json_str "$topic"), \"title\": $(json_str "$2"), \
\"message\": $(json_str "$3"), \"priority\": $priority$tags}"

# The token goes through curl's config on stdin, not the command line, where
# any local user could read it in the process list. Inside a quoted config
# value, backslash and double quote must be escaped.
token="${NTFY_TOKEN//\\/\\\\}"
token="${token//\"/\\\"}"
printf '%s' "${NTFY_TOKEN:+header = \"Authorization: Bearer $token\"}" \
    | curl -fsS --max-time 15 -K - \
        -H 'Content-Type: application/json' --data-binary "$payload" \
        "$server" >/dev/null
