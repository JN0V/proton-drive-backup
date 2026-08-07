#!/usr/bin/env bash
#
# Chien de garde : alerte si aucune sauvegarde Proton Drive n'a REUSSI
# depuis MAX_AGE_DAYS jours.
#
# Volontairement independant de proton-drive-backup.service : si ce dernier
# ne se declenche plus du tout (timer desactive, session expiree, annulations
# repetees), une verification hebergee dans le script de sauvegarde ne
# tournerait jamais. C'est donc son propre timer qui pilote ce script.
#
set -uo pipefail

# ---------- Configuration ----------
MAX_AGE_DAYS=3
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"
STAMP_WARNED="$LOG_DIR/last-warned"   # anti-spam : une alerte par jour maximum
BACKUP_UNIT="proton-drive-backup.service"
# -----------------------------------

MAX_AGE_SEC=$(( MAX_AGE_DAYS * 86400 ))
NOW=$(date +%s)

mkdir -p "$LOG_DIR"

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# Une sauvegarde est peut-etre en cours (rattrapage simultane au demarrage,
# ou fenetre de confirmation encore ouverte). On ne juge pas dans ce cas.
if systemctl --user is-active --quiet "$BACKUP_UNIT" 2>/dev/null; then
    log "SURVEILLANCE: sauvegarde en cours, verification reportee."
    exit 0
fi

# --- Age de la derniere reussite ----------------------------------------------
if [ -f "$STAMP_SUCCESS" ]; then
    LAST=$(cat "$STAMP_SUCCESS" 2>/dev/null)
    # Garde-fou : fichier corrompu ou vide
    if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
        log "SURVEILLANCE: horodatage illisible, traite comme absent."
        LAST=""
    fi
else
    LAST=""
fi

if [ -z "$LAST" ]; then
    AGE_TEXT="aucune sauvegarde reussie enregistree"
    STALE=1
else
    AGE_SEC=$(( NOW - LAST ))
    AGE_DAYS=$(( AGE_SEC / 86400 ))
    # Format numerique : le systeme est en locale en_US, un format avec nom de
    # jour/mois s'afficherait en anglais au milieu d'un texte francais.
    LAST_HUMAN=$(date -d "@$LAST" '+%d/%m/%Y a %H:%M')
    if [ "$AGE_SEC" -gt "$MAX_AGE_SEC" ]; then
        AGE_TEXT="derniere reussite : $LAST_HUMAN (il y a $AGE_DAYS jours)"
        STALE=1
    else
        STALE=0
    fi
fi

if [ "$STALE" -eq 0 ]; then
    log "SURVEILLANCE: OK (derniere reussite il y a ${AGE_DAYS}j)."
    rm -f "$STAMP_WARNED"   # retour a la normale : on reautorise une alerte future
    exit 0
fi

# --- Anti-spam ----------------------------------------------------------------
# Sans ca, une session expiree genererait une alerte a chaque passage du timer.
if [ -f "$STAMP_WARNED" ]; then
    WARNED=$(cat "$STAMP_WARNED" 2>/dev/null)
    if [[ "$WARNED" =~ ^[0-9]+$ ]] && [ $(( NOW - WARNED )) -lt 86400 ]; then
        log "SURVEILLANCE: retard confirme, alerte deja emise il y a moins de 24h."
        exit 0
    fi
fi

# --- Diagnostic ---------------------------------------------------------------
# On indique la cause probable plutot qu'un simple "ca n'a pas tourne".
CAUSE=""
if ! systemctl --user is-enabled --quiet proton-drive-backup.timer 2>/dev/null; then
    CAUSE="Le timer est desactive."
elif ! "$HOME/bin/proton-drive" filesystem list /my-files >/dev/null 2>&1; then
    CAUSE="Session Proton Drive expiree : relance « proton-drive auth login »."
else
    CAUSE="Sauvegarde probablement annulee lors des dernieres propositions."
fi

log "SURVEILLANCE: ALERTE - $AGE_TEXT. $CAUSE"
date +%s > "$STAMP_WARNED"

notify-send \
    --app-name="Proton Drive" \
    --urgency=critical \
    --icon=dialog-warning \
    "Sauvegarde Proton Drive en retard" \
    "Plus de $MAX_AGE_DAYS jours sans sauvegarde reussie.
$AGE_TEXT.

$CAUSE" 2>/dev/null || true

exit 0
