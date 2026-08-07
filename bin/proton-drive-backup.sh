#!/usr/bin/env bash
#
# Sauvegarde ~/Documents/drive vers Proton Drive, selon les correspondances
# declarees dans ~/.config/proton-drive-backup/mappings.conf.
#
# Lance par le timer systemd proton-drive-backup.timer, avec confirmation
# graphique. Voir aussi proton-drive-backup-check.sh (alerte de retard).
#
set -uo pipefail

# ---------- Configuration ----------
PROTON_DRIVE="$HOME/bin/proton-drive"
SOURCE_ROOT="$HOME/Documents/drive"
MAPPINGS_FILE="$HOME/.config/proton-drive-backup/mappings.conf"
LOG_DIR="$HOME/.local/state/proton-drive-backup"
LOG_FILE="$LOG_DIR/backup.log"
STAMP_SUCCESS="$LOG_DIR/last-success"   # epoch de la derniere sauvegarde REUSSIE
DEST_UIDS="$LOG_DIR/dest-uids"          # <chemin distant><TAB><uid> : detection des renommages
MAX_LOG_BYTES=1048576                   # 1 Mio, puis rotation simple
CONFIRM_TIMEOUT=300                     # secondes ; sans reponse -> on ne fait rien
VERSION_INDEX="https://proton.me/download/drive/cli/index.html"
VERSION_TIMEOUT=8                       # secondes max pour la verification de version
# -----------------------------------

# Mode simulation : affiche le plan (correspondances resolues) et sort, sans
# confirmation ni transfert. Sert a valider mappings.conf avant de l'appliquer.
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

mkdir -p "$LOG_DIR"

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

notify() {
    # $1 = urgence (normal|critical), $2 = titre, $3 = corps
    notify-send --app-name="Proton Drive" --urgency="$1" "$2" "$3" 2>/dev/null || true
}

# Rotation avant ecriture
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi

log "--- Reveil du timer ---"

# --- Verifications prealables -------------------------------------------------
if [ ! -x "$PROTON_DRIVE" ]; then
    log "ERREUR: binaire introuvable ou non executable: $PROTON_DRIVE"
    notify critical "Sauvegarde impossible" "CLI Proton Drive introuvable."
    exit 1
fi

if [ ! -d "$SOURCE_ROOT" ]; then
    log "ERREUR: dossier source absent: $SOURCE_ROOT"
    notify critical "Sauvegarde impossible" "Dossier absent : $SOURCE_ROOT"
    exit 1
fi

if [ ! -f "$MAPPINGS_FILE" ]; then
    log "ERREUR: fichier de correspondances absent: $MAPPINGS_FILE"
    notify critical "Sauvegarde impossible" \
        "Fichier de correspondances absent :
$MAPPINGS_FILE"
    exit 1
fi

# --- Lecture des correspondances ----------------------------------------------
# On remplit deux tableaux paralleles (les tableaux associatifs compliqueraient
# l'ordre d'affichage, qu'on veut stable et identique au fichier).
declare -a MAP_KEYS=() MAP_DESTS=()
CATCHALL_DEST=""
ROOTFILES_DEST=""

while IFS= read -r line; do
    # Retire commentaires en fin de ligne, espaces de bord
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    case "$line" in
        *"->"*) ;;
        *) log "CONFIG: ligne ignoree (pas de '->') : $line"; continue ;;
    esac

    key="${line%%->*}"
    dest="${line#*->}"
    key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
    dest="$(printf '%s' "$dest" | sed 's/^[[:space:]]*//; s|/*$||')"

    if [ -z "$key" ] || [ -z "$dest" ]; then
        log "CONFIG: ligne incomplete ignoree : $line"
        continue
    fi

    case "$key" in
        '*') CATCHALL_DEST="$dest" ;;
        '.') ROOTFILES_DEST="$dest" ;;
        *)   MAP_KEYS+=("$key"); MAP_DESTS+=("$dest") ;;
    esac
done < "$MAPPINGS_FILE"

log "CONFIG: ${#MAP_KEYS[@]} correspondance(s) explicite(s), defaut='${CATCHALL_DEST:-aucun}', racine='${ROOTFILES_DEST:-aucun}'"

# Cherche la destination declaree pour un nom de dossier. Vide si aucune.
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

# --- Construction de la liste des taches --------------------------------------
# JOB_SRCS[i]  : dossier local (ou la chaine ".ROOTFILES" pour les fichiers isoles)
# JOB_DESTS[i] : dossier distant destinataire
# JOB_LABELS[i]: libelle affiche a l'utilisateur
declare -a JOB_SRCS=() JOB_DESTS=() JOB_LABELS=()
SKIPPED_REPORT=""

shopt -s dotglob nullglob

# 1. Sous-dossiers de premier niveau
for entry in "$SOURCE_ROOT"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"

    if dest="$(lookup_dest "$name")"; then
        :
    elif [ -n "$CATCHALL_DEST" ]; then
        dest="${CATCHALL_DEST//%name%/$name}"
    else
        log "IGNORE: '$name' sans correspondance et aucune regle par defaut."
        SKIPPED_REPORT="$SKIPPED_REPORT
  • $name (aucune correspondance)"
        continue
    fi

    # Un dossier vide n'a rien a envoyer et ferait echouer l'upload
    contents=("$entry"/*)
    if [ ${#contents[@]} -eq 0 ]; then
        log "IGNORE: '$name' est vide."
        continue
    fi

    JOB_SRCS+=("$entry")
    JOB_DESTS+=("$dest")
    JOB_LABELS+=("$name → $dest")
done

# 2. Fichiers poses directement a la racine
rootfiles=()
for entry in "$SOURCE_ROOT"/*; do
    [ -f "$entry" ] && rootfiles+=("$entry")
done
if [ ${#rootfiles[@]} -gt 0 ]; then
    if [ -n "$ROOTFILES_DEST" ]; then
        JOB_SRCS+=(".ROOTFILES")
        JOB_DESTS+=("$ROOTFILES_DEST")
        JOB_LABELS+=("${#rootfiles[@]} fichier(s) a la racine → $ROOTFILES_DEST")
    else
        log "IGNORE: ${#rootfiles[@]} fichier(s) a la racine, aucune regle '.'."
        SKIPPED_REPORT="$SKIPPED_REPORT
  • ${#rootfiles[@]} fichier(s) a la racine (aucune regle '.')"
    fi
fi

shopt -u dotglob nullglob

# --- Sortie du mode simulation ------------------------------------------------
# Placee avant l'abandon "rien a sauvegarder" : une simulation doit afficher son
# plan meme vide, et ne jamais emettre de notification.
if [ "$DRY_RUN" -eq 1 ]; then
    printf '\nPlan de sauvegarde (simulation, aucun transfert) :\n\n'
    printf '  Source : %s\n' "$SOURCE_ROOT"
    printf '  Regles : %s\n\n' "$MAPPINGS_FILE"
    for i in "${!JOB_SRCS[@]}"; do
        printf '  %2d. %s\n' "$((i+1))" "${JOB_LABELS[$i]}"
    done
    if [ -n "$SKIPPED_REPORT" ]; then
        printf '\n  Ignore :%s\n' "$SKIPPED_REPORT"
    fi
    printf '\n  %d destination(s).\n\n' "${#JOB_SRCS[@]}"
    exit 0
fi

if [ ${#JOB_SRCS[@]} -eq 0 ]; then
    log "ABANDON: rien a sauvegarder."
    notify normal "Sauvegarde annulee" "Aucun contenu a envoyer depuis $SOURCE_ROOT."
    exit 0
fi

# --- Session valide ? ---------------------------------------------------------
# Avant la confirmation, pour ne pas faire cliquer l'utilisateur pour rien.
if ! "$PROTON_DRIVE" filesystem list /my-files >/dev/null 2>&1; then
    log "ERREUR: session Proton Drive absente ou expiree."
    notify critical "Proton Drive : reconnexion requise" \
        "Lance « proton-drive auth login » dans un terminal."
    exit 1
fi

# --- Verification de version --------------------------------------------------
# Purement informatif : aucune mise a jour n'est installee automatiquement, et
# un echec reseau ne doit jamais empecher la sauvegarde de tourner.
VERSION_NOTE=""
check_version() {
    local local_v remote_v newest
    local_v=$("$PROTON_DRIVE" version 2>/dev/null \
        | grep -oP 'cli-drive@\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$local_v" ]; then
        log "VERSION: impossible de lire la version locale."
        return
    fi

    remote_v=$(curl -sL --max-time "$VERSION_TIMEOUT" "$VERSION_INDEX" 2>/dev/null \
        | grep -oP '<h1>Proton Drive CLI \K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$remote_v" ]; then
        log "VERSION: verification impossible (reseau ou page indisponible). Locale: $local_v"
        return
    fi

    if [ "$local_v" = "$remote_v" ]; then
        log "VERSION: a jour ($local_v)."
        return
    fi

    newest=$(printf '%s\n%s\n' "$local_v" "$remote_v" | sort -V | tail -1)
    if [ "$newest" = "$remote_v" ]; then
        log "VERSION: mise a jour disponible ($local_v -> $remote_v)."
        VERSION_NOTE="\n\n⚠️  <b>Mise a jour disponible :</b> $local_v → $remote_v"
        notify normal "Proton Drive CLI : mise a jour disponible" \
            "Version $remote_v disponible (installee : $local_v)."
    else
        log "VERSION: locale ($local_v) plus recente que publiee ($remote_v)."
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
[ -n "$SKIPPED_REPORT" ] && SKIP_BLOCK="\n\n<b>Ignore :</b><tt>$SKIPPED_REPORT</tt>"

zenity --question \
    --title="Sauvegarde Proton Drive" \
    --icon-name=folder-remote \
    --width=520 \
    --timeout="$CONFIRM_TIMEOUT" \
    --ok-label="Sauvegarder" \
    --cancel-label="Plus tard" \
    --text="Lancer la sauvegarde vers Proton Drive ?\n\n<b>${#JOB_SRCS[@]} destination(s) :</b><tt>$JOB_LIST</tt>\n\n<b>Total local :</b> $TOTAL_FILES fichiers ($TOTAL_SIZE)\n\n<small>Seuls les fichiers modifies seront transferes.</small>$SKIP_BLOCK$VERSION_NOTE" \
    2>/dev/null
ANSWER=$?

case "$ANSWER" in
    0) log "Confirme par l'utilisateur (${#JOB_SRCS[@]} tache(s))." ;;
    5) log "ABANDON: pas de reponse en ${CONFIRM_TIMEOUT}s."; exit 0 ;;
    *) log "ABANDON: refuse par l'utilisateur."; exit 0 ;;
esac

# --- Creation des chemins distants --------------------------------------------
# create-folder n'est pas idempotent (il echoue si le nom existe deja), d'ou le
# test prealable via `info`. On remonte l'arborescence pour creer aussi les
# niveaux intermediaires manquants.
# UID Proton d'un noeud distant, vide s'il n'existe pas.
# L'ancre ^\s*uid evite de capturer parentUid, present dans la meme sortie.
remote_uid() {
    "$PROTON_DRIVE" filesystem info "$1" 2>/dev/null \
        | grep -oP "^\s*uid: '\K[^']+" | head -1
}

# Empreintes enregistrees lors des sauvegardes precedentes.
declare -A KNOWN_UID=()
if [ -f "$DEST_UIDS" ]; then
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] && KNOWN_UID["$k"]="$v"
    done < "$DEST_UIDS"
fi
declare -A NEW_UID=()

# Le CLI n'adresse que par chemin (l'UID n'est pas accepte comme cible). Un
# dossier renommee ou deplace cote Drive laisse donc son chemin vacant, et une
# sauvegarde naive le recreerait puis re-enverrait tout : le contenu se
# retrouverait scinde entre l'ancien dossier et un nouveau. On compare donc
# l'UID courant a celui memorise pour transformer cette duplication silencieuse
# en alerte explicite.
# Codes : 0 = utilisable, 1 = rupture detectee, 2 = premiere utilisation.
check_dest_identity() {
    local dest="$1" known current
    known="${KNOWN_UID[$dest]:-}"
    current="$(remote_uid "$dest")"

    if [ -z "$known" ]; then
        return 2
    fi

    if [ -z "$current" ]; then
        DEST_ISSUE="le dossier distant a ete renomme, deplace ou supprime"
        return 1
    fi

    if [ "$current" != "$known" ]; then
        DEST_ISSUE="un autre dossier occupe desormais ce chemin"
        return 1
    fi

    return 0
}

ensure_remote_path() {
    local path="$1" parent leaf

    # Racines Drive : toujours presentes, jamais a creer
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
        log "  dossier distant cree : $path"
        return 0
    fi
    # Course possible avec une autre execution : on revalide avant d'echouer
    "$PROTON_DRIVE" filesystem info "$path" >/dev/null 2>&1
}

# --- Transfert ----------------------------------------------------------------
notify normal "Sauvegarde en cours" "${#JOB_SRCS[@]} destination(s) vers Proton Drive..."
# Sortie de chaque upload capturee a part : on doit l'inspecter pour decider
# d'une eventuelle nouvelle tentative, tout en la conservant dans le journal.
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
            # On ne recree surtout pas : ce serait scinder le contenu en deux.
            log "  ALERTE: $DEST_ISSUE ($dest). Destination ignoree."
            BROKEN_REPORT="$BROKEN_REPORT
  • $dest : $DEST_ISSUE"
            # Empreinte conservee : sans elle, la prochaine execution croirait a
            # une premiere utilisation et dupliquerait sans prevenir.
            NEW_UID["$dest"]="${KNOWN_UID[$dest]}"
            FAILED=$((FAILED+1))
            continue
            ;;
        2) log "  (premiere sauvegarde vers cette destination)" ;;
    esac

    if ! ensure_remote_path "$dest"; then
        log "  ECHEC: impossible de creer/atteindre $dest"
        FAILED=$((FAILED+1))
        continue
    fi

    # Empreinte relevee des que le dossier est en place, independamment de
    # l'issue du transfert : son identite est valide dans les deux cas.
    NEW_UID["$dest"]="$(remote_uid "$dest")"

    # On envoie le CONTENU de la source : c'est ce qui autorise un dossier
    # distant de nom different du dossier local.
    if [ "$src" = ".ROOTFILES" ]; then
        items=()
        for f in "$SOURCE_ROOT"/*; do [ -f "$f" ] && items+=("$f"); done
    else
        items=("$src"/*)
    fi

    if [ ${#items[@]} -eq 0 ]; then
        log "  (vide, ignore)"
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
        # Un seul fichier a extension image mais au contenu invalide (corrompu,
        # tronque, mal nomme) fait echouer tout le lot. Plutot que de desactiver
        # les miniatures partout, on ne retente sans elles que dans ce cas.
        if grep -q 'Failed to generate thumbnails' "$UPLOAD_OUT"; then
            log "  Miniature impossible sur un fichier : nouvelle tentative sans miniatures."
            if "$PROTON_DRIVE" filesystem upload \
                --skip-thumbnails \
                --file-conflict-strategy replace \
                --folder-conflict-strategy merge \
                "${items[@]}" "$dest" >> "$LOG_FILE" 2>&1; then
                log "  OK sans miniatures."
                DONE=$((DONE+1))
            else
                log "  ECHEC du transfert vers $dest (meme sans miniatures)"
                FAILED=$((FAILED+1))
            fi
        else
            log "  ECHEC du transfert vers $dest"
            FAILED=$((FAILED+1))
        fi
    fi
done
shopt -u dotglob nullglob

# Reecriture des empreintes. Seules les destinations de cette execution sont
# conservees : celles retirees de mappings.conf disparaissent d'elles-memes.
: > "$DEST_UIDS"
for d in "${!NEW_UID[@]}"; do
    [ -n "${NEW_UID[$d]}" ] && printf '%s\t%s\n' "$d" "${NEW_UID[$d]}" >> "$DEST_UIDS"
done

ELAPSED=$(( $(date +%s) - START ))

# --- Bilan --------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
    log "SUCCES: $DONE destination(s) en ${ELAPSED}s."
    # Horodatage lu par proton-drive-backup-check.sh (surveillance des 3 jours).
    # Ecrit uniquement si TOUTES les destinations ont reussi : un succes partiel
    # ne doit pas faire croire que l'ensemble est a jour.
    date +%s > "$STAMP_SUCCESS"
    notify normal "Sauvegarde terminee" \
        "$DONE destination(s) traitee(s) en ${ELAPSED}s."
    exit 0
else
    log "ECHEC PARTIEL: $DONE reussie(s), $FAILED en echec, ${ELAPSED}s."
    if [ -n "$BROKEN_REPORT" ]; then
        # Cas distinct d'une panne de transfert : il demande une decision de
        # l'utilisateur, pas une nouvelle tentative.
        notify critical "Destination Proton Drive introuvable" \
            "Rien n'a ete recree pour eviter de dupliquer le contenu.
$BROKEN_REPORT

Corrige le nom sur le Drive, ou mets a jour mappings.conf."
    else
        notify critical "Sauvegarde incomplete" \
            "$FAILED destination(s) en echec sur $((DONE+FAILED)).
Details : $LOG_FILE"
    fi
    exit 1
fi
