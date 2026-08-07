# proton-drive-backup

Sauvegarde planifiée de dossiers locaux vers Proton Drive, via le CLI officiel
`proton-drive`, avec confirmation graphique et surveillance des retards.

**Besoin couvert :** envoyer automatiquement le contenu de `~/Documents/drive`
vers un ou plusieurs emplacements de Proton Drive, à heure fixe, sans intervention
sauf validation.

## Pourquoi ce dépôt existe

Le CLI Proton Drive (v0.7.0) ne fait **pas** de synchronisation continue : il
exécute une opération puis rend la main. Il n'existe pas non plus de client
graphique Linux à ce jour (annoncé pour fin 2026). Ce dépôt construit la couche
de planification, de confirmation et de contrôle qui manque autour du CLI.

## Installation

```bash
./install.sh
```

Les fichiers réels restent dans ce dépôt ; l'installation ne pose que des liens
symboliques dans `~/bin` et `~/.config/systemd/user`. Un `git pull` suffit donc
à mettre à jour l'installation.

Prérequis : `proton-drive` dans `~/bin`, session ouverte via
`proton-drive auth login`, et `zenity` (présent par défaut sur Ubuntu GNOME).

## Configuration

Les correspondances vivent dans `~/.config/proton-drive-backup/mappings.conf`
(hors dépôt : données personnelles). Modèle documenté dans
`config/mappings.conf.example`.

Règle unique : **le contenu de la source est déposé dans le dossier distant**,
ce qui autorise un nom distant différent du nom local.

```
photos   ->  /my-files/Nos photos
.        ->  /my-files/drive
*        ->  /my-files/drive/%name%
```

Vérifier ses règles sans rien envoyer :

```bash
proton-drive-backup.sh --dry-run
```

## Fonctionnement

| Composant | Rôle |
|---|---|
| `proton-drive-backup.timer` | Déclenche à 12h00. `Persistent=true` : rattrape une échéance manquée (PC éteint) à la session suivante. |
| `proton-drive-backup.sh` | Résout les correspondances, demande confirmation, transfère. |
| `proton-drive-backup-check.timer` | Déclenche à 13h00. |
| `proton-drive-backup-check.sh` | Alerte si aucune sauvegarde n'a **réussi** depuis 3 jours. |

État dans `~/.local/state/proton-drive-backup/` : journal, horodatage du dernier
succès, empreintes UID des destinations.

## Décisions de conception

Les points ci-dessous sont contre-intuitifs et ont été validés par test contre
le CLI réel.

**Stratégies de conflit obligatoires.** Sans `--file-conflict-strategy` et
`--folder-conflict-strategy`, le CLI pose une question interactive et le service
resterait bloqué jusqu'au timeout.

**Repli sur les miniatures.** Un seul fichier à extension image mais au contenu
invalide (corrompu, tronqué, mal nommé) fait échouer *tout le lot*. Le script
détecte ce cas précis et relance uniquement ce lot avec `--skip-thumbnails`,
plutôt que de désactiver les miniatures partout.

**Détection des renommages distants.** Le CLI n'adresse que par chemin
(`Path "<uid>" not supported`). Un dossier renommé côté Drive laisse son chemin
vacant, et une sauvegarde naïve le recréerait puis renverrait tout — scindant le
contenu en deux. Le script mémorise l'UID de chaque destination et **arrête**
la destination concernée au lieu de la recréer.

**`create-folder` n'est pas idempotent** : il échoue si le nom existe. D'où un
test `filesystem info` préalable à chaque niveau de l'arborescence.

**Horodatage de succès conditionné à la réussite totale.** Un succès partiel
n'écrit pas `last-success` : sinon le chien de garde croirait l'ensemble à jour.

**Chien de garde séparé.** Si le timer de sauvegarde ne se déclenche plus, une
vérification hébergée dans le script de sauvegarde ne tournerait jamais. D'où
une unité systemd indépendante.

## Limites

Sauvegarde **ascendante uniquement** : rien ne redescend, et une suppression
locale ne supprime pas la copie distante. Le renommage ou la suppression d'un
*fichier* laisse un orphelin côté Drive. Ce n'est pas un miroir.

Pour un miroir bidirectionnel : attendre le client graphique Linux, ou rclone
(backend `protondrive`, avec des limites connues sur le 2FA non interactif et
l'absence de gestion des mtimes).
