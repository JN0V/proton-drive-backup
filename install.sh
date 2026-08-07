#!/usr/bin/env bash
#
# Installe (ou reinstalle) la sauvegarde Proton Drive depuis ce depot.
#
# Principe : les fichiers reels vivent dans le depot, le systeme n'a que des
# liens symboliques. Un git pull suffit donc a mettre a jour l'installation,
# sans rien recopier.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/proton-drive-backup"

echo "Depot   : $REPO"
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

echo
echo "== Scripts =="
for f in "$REPO"/bin/*.sh; do
    ln -sfn "$f" "$BIN_DIR/$(basename "$f")"
    echo "  $BIN_DIR/$(basename "$f") -> $f"
done

echo
echo "== Units systemd =="
for f in "$REPO"/systemd/*; do
    ln -sfn "$f" "$UNIT_DIR/$(basename "$f")"
    echo "  $UNIT_DIR/$(basename "$f") -> $f"
done

echo
echo "== Configuration =="
# Jamais ecrasee : elle contient les correspondances personnelles.
if [ -f "$CONF_DIR/mappings.conf" ]; then
    echo "  $CONF_DIR/mappings.conf existe deja, conserve."
else
    cp "$REPO/config/mappings.conf.example" "$CONF_DIR/mappings.conf"
    echo "  $CONF_DIR/mappings.conf cree depuis le modele."
fi

echo
echo "== Activation =="
systemctl --user daemon-reload
systemctl --user enable --now proton-drive-backup.timer >/dev/null
systemctl --user enable --now proton-drive-backup-check.timer >/dev/null
systemctl --user list-timers 'proton-drive-*' --no-pager

echo
echo "Termine. Verifier les correspondances :"
echo "  proton-drive-backup.sh --dry-run"
