#!/usr/bin/env bash
#
# Watchdog: alerts when no Proton Drive backup has SUCCEEDED for the last
# MAX_AGE_DAYS days.
#
# Deliberately independent from proton-drive-backup.service: if that unit stops
# firing altogether (timer disabled, session expired, repeated cancellations), a
# check hosted inside the backup script would never run. Hence its own timer.
#
set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh" || exit 1

# ---------- Configuration ----------
MAX_AGE_DAYS=3
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"
STAMP_WARNED="$LOG_DIR/last-warned"   # rate limit: at most one alert per day
# Just under a day, not 24h: the timer fires at 13:00 plus up to 5 min of random
# delay, so an alert sent at 13:04 would otherwise mute the next day's check if
# it happened to fire at 13:01.
WARN_INTERVAL_SEC=72000
BACKUP_UNIT="proton-drive-backup.service"
# -----------------------------------

MAX_AGE_SEC=$(( MAX_AGE_DAYS * 86400 ))
NOW=$(date +%s)

mkdir -p "$LOG_DIR"

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# A backup may be running (both catch-ups firing together at session start, or
# the confirmation prompt still unanswered). Do not judge in that case.
if systemctl --user is-active --quiet "$BACKUP_UNIT" 2>/dev/null; then
    log "WATCHDOG: backup in progress, check deferred."
    exit 0
fi

# --- Age of the last success --------------------------------------------------
if [ -f "$STAMP_SUCCESS" ]; then
    LAST=$(cat "$STAMP_SUCCESS" 2>/dev/null)
    # Guard against a corrupt or empty file
    if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
        log "WATCHDOG: unreadable timestamp, treated as missing."
        LAST=""
    fi
else
    LAST=""
fi

if [ -z "$LAST" ]; then
    AGE_TEXT="no successful backup on record"
    STALE=1
else
    AGE_SEC=$(( NOW - LAST ))
    AGE_DAYS=$(( AGE_SEC / 86400 ))
    # ISO format: locale-independent, and unambiguous across regions where
    # dd/mm and mm/dd would be read differently.
    LAST_HUMAN=$(date -d "@$LAST" '+%Y-%m-%d %H:%M')
    if [ "$AGE_SEC" -gt "$MAX_AGE_SEC" ]; then
        AGE_TEXT="last success: $LAST_HUMAN ($AGE_DAYS days ago)"
        STALE=1
    else
        STALE=0
    fi
fi

if [ "$STALE" -eq 0 ]; then
    log "WATCHDOG: OK (last success ${AGE_DAYS}d ago)."
    rm -f "$STAMP_WARNED"   # back to normal: re-arm future alerts
    exit 0
fi

# --- Rate limit ---------------------------------------------------------------
# Without this, an expired session would raise an alert on every timer tick.
if [ -f "$STAMP_WARNED" ]; then
    WARNED=$(cat "$STAMP_WARNED" 2>/dev/null)
    if [[ "$WARNED" =~ ^[0-9]+$ ]] && [ $(( NOW - WARNED )) -lt "$WARN_INTERVAL_SEC" ]; then
        log "WATCHDOG: still stale, alert already raised today."
        exit 0
    fi
fi

# --- Diagnosis ----------------------------------------------------------------
# Report the likely cause rather than a bare "it did not run".
CAUSE=""
if ! systemctl --user is-enabled --quiet proton-drive-backup.timer 2>/dev/null; then
    CAUSE="The timer is disabled."
else
    # The CLI prints its errors on stdout, not stderr, so both are captured:
    # the wording is the only thing separating a dead session from a Drive that
    # was never reached, and sending someone to `auth login` over a dropped
    # wifi is exactly the false alarm this check exists to avoid.
    PROBE_OUT="$(timeout 60 "$HOME/bin/proton-drive" filesystem list /my-files 2>&1)"
    PROBE_RC=$?
    if [ "$PROBE_RC" -eq 0 ]; then
        # The Drive answers, so the reason lies in how the runs ended. Blaming
        # the prompt without looking was fine while every run asked one; a
        # headless host runs with --yes, and there the prompt is never the cause.
        #
        # Judged on the last run, not on the last outcome line: a run killed on
        # its timeout or by a power cut logs no outcome at all, and reaching
        # back to an older one would name a cause that no longer applies. Dry
        # runs are skipped, since they say nothing about the backup.
        LAST_OUTCOME="$(cat "$LOG_FILE.1" "$LOG_FILE" 2>/dev/null | awk '
            function close_run() {
                if (!inrun) return
                if (out != "DRY") last = (out == "" ? "UNFINISHED" : out)
            }
            / --- Timer fired ---$/ { close_run(); inrun = 1; out = ""; next }
            inrun && out == "" && /^[0-9-]+ [0-9:]+  DRY RUN/ { out = "DRY"; next }
            inrun && out == "" && /^[0-9-]+ [0-9:]+  (SUCCESS|ABORT|PARTIAL FAILURE|ERROR|POSTPONED)/ {
                sub(/^[^ ]+ [^ ]+  /, ""); out = $0
            }
            END { close_run(); print last }')"
        case "$LAST_OUTCOME" in
            "")
                CAUSE="No backup run on record." ;;
            UNFINISHED)
                CAUSE="The last run did not finish: timed out, killed or cut by a shutdown." ;;
            "ABORT: declined"*|"ABORT: no answer"*)
                CAUSE="Backup was most likely declined at the last prompts." ;;
            SUCCESS*)
                # Only --only runs log a success without stamping it.
                CAUSE="Only partial (--only) runs succeeded since." ;;
            *)
                CAUSE="Last run: $LAST_OUTCOME" ;;
        esac
    elif [ "$PROBE_RC" -eq 124 ] || printf '%s' "$PROBE_OUT" | grep -qiE \
'unable to connect|connectionrefused|connectionreset|connectiontimeout|econnrefused|econnreset|econnaborted|enetunreach|ehostunreach|enotfound|eai_again|etimedout|getaddrinfo|socket hang up|fetch failed|network'; then
        CAUSE="Proton Drive is unreachable from here: check the network."
    else
        CAUSE="Proton Drive session expired: run 'proton-drive auth login'."
    fi
fi

log "WATCHDOG: ALERT - $AGE_TEXT. $CAUSE"

# Counted as raised only once delivered: on a headless host the notification
# command is the only channel, and an alert lost to an outage must not mute the
# next check.
if notify critical "Proton Drive backup is overdue" \
    "More than $MAX_AGE_DAYS days without a successful backup.
$AGE_TEXT.

$CAUSE" dialog-warning; then
    date +%s > "$STAMP_WARNED"
else
    log "WATCHDOG: alert not delivered, the next check will send it again."
fi

exit 0
