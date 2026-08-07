#!/usr/bin/env bash
#
# Installs (or reinstalls) the Proton Drive backup from this repository.
#
# Principle: the real files stay in the repository, the system only gets
# symlinks. A git pull is therefore enough to update the installation, with
# nothing to copy over.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/proton-drive-backup"

echo "Repository: $REPO"
mkdir -p "$BIN_DIR" "$UNIT_DIR" "$CONF_DIR"

echo
echo "== Scripts =="
for f in "$REPO"/bin/*.sh; do
    ln -sfn "$f" "$BIN_DIR/$(basename "$f")"
    echo "  $BIN_DIR/$(basename "$f") -> $f"
done

echo
echo "== systemd units =="
for f in "$REPO"/systemd/*; do
    ln -sfn "$f" "$UNIT_DIR/$(basename "$f")"
    echo "  $UNIT_DIR/$(basename "$f") -> $f"
done

echo
echo "== Configuration =="
# Never overwritten: it holds your personal mappings.
if [ -f "$CONF_DIR/mappings.conf" ]; then
    echo "  $CONF_DIR/mappings.conf already exists, kept as is."
else
    cp "$REPO/config/mappings.conf.example" "$CONF_DIR/mappings.conf"
    echo "  $CONF_DIR/mappings.conf created from the template."
fi

echo
echo "== Activation =="
systemctl --user daemon-reload
systemctl --user enable --now proton-drive-backup.timer >/dev/null
systemctl --user enable --now proton-drive-backup-check.timer >/dev/null
systemctl --user list-timers 'proton-drive-*' --no-pager

echo
echo "Done. Review your mappings with:"
echo "  proton-drive-backup.sh --dry-run"
