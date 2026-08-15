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

# ---------- Configuration ----------
MAX_AGE_DAYS=3
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"
STAMP_WARNED="$LOG_DIR/last-warned"   # rate limit: at most one alert per day
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
    if [[ "$WARNED" =~ ^[0-9]+$ ]] && [ $(( NOW - WARNED )) -lt 86400 ]; then
        log "WATCHDOG: still stale, alert already raised less than 24h ago."
        exit 0
    fi
fi

# --- Diagnosis ----------------------------------------------------------------
# Report the likely cause rather than a bare "it did not run".
CAUSE=""
if ! systemctl --user is-enabled --quiet proton-drive-backup.timer 2>/dev/null; then
    CAUSE="The timer is disabled."
elif ! "$HOME/bin/proton-drive" filesystem list /my-files >/dev/null 2>&1; then
    CAUSE="Proton Drive session expired: run 'proton-drive auth login'."
else
    CAUSE="Backup was most likely declined at the last prompts."
fi

log "WATCHDOG: ALERT - $AGE_TEXT. $CAUSE"
date +%s > "$STAMP_WARNED"

notify-send \
    --app-name="Proton Drive" \
    --urgency=critical \
    --icon=dialog-warning \
    "Proton Drive backup is overdue" \
    "More than $MAX_AGE_DAYS days without a successful backup.
$AGE_TEXT.

$CAUSE" 2>/dev/null || true

exit 0
