#!/usr/bin/env bash
#
# Installs (or reinstalls) the Proton Drive backup from this repository.
#
# Principle: the real files stay in the repository, the system only gets
# symlinks. A git pull is therefore enough to update the installation, with
# nothing to copy over.
#
# --headless prepares a host without a graphical session (a server, a Raspberry
# Pi): the daily run no longer asks for confirmation, and the checks that such a
# host needs — lingering, session storage — are reported.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/bin"
UNIT_DIR="$HOME/.config/systemd/user"
CONF_DIR="$HOME/.config/proton-drive-backup"
HEADLESS_DROPIN="$UNIT_DIR/proton-drive-backup.service.d/headless.conf"

HEADLESS=0
case "${1:-}" in
    "")         ;;
    --headless) HEADLESS=1 ;;
    -h|--help)
        echo "Usage: install.sh [--headless]"
        echo "  --headless  Run the daily backup with --yes: for a host without a desktop."
        exit 0 ;;
    *)  echo "Unknown option: $1" >&2; exit 2 ;;
esac

# Everything below talks to the user's systemd manager. It exists for a desktop
# session and for an SSH login, but not under `su` or `sudo -u`, where every
# systemctl call would fail with a bus error that says nothing useful.
if ! systemctl --user show-environment >/dev/null 2>&1; then
    echo "No systemd user manager reachable for $USER." >&2
    echo "Log in as $USER directly (desktop or SSH), not through su or sudo." >&2
    exit 1
fi

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

# A drop-in rather than a second copy of the unit: the unit itself stays a
# symlink into the repository, and only the command line differs.
if [ "$HEADLESS" -eq 1 ]; then
    mkdir -p "$(dirname "$HEADLESS_DROPIN")"
    cat > "$HEADLESS_DROPIN" <<'EOF'
# Written by install.sh --headless: nobody is there to answer a prompt.
[Service]
ExecStart=
ExecStart=%h/bin/proton-drive-backup.sh --yes
EOF
    echo "  $HEADLESS_DROPIN (unattended: --yes)"
elif [ -f "$HEADLESS_DROPIN" ]; then
    # Never removed silently: dropping it would bring the prompt back on a host
    # where nobody can answer it, and every run would be lost.
    echo "  $HEADLESS_DROPIN kept (unattended). Delete it to get the prompt back."
fi

echo
echo "== Configuration =="
# Never overwritten: they hold your personal settings.
for name in mappings backup; do
    if [ -f "$CONF_DIR/$name.conf" ]; then
        echo "  $CONF_DIR/$name.conf already exists, kept as is."
    else
        cp "$REPO/config/$name.conf.example" "$CONF_DIR/$name.conf"
        echo "  $CONF_DIR/$name.conf created from the template."
    fi
done

echo
echo "== Activation =="
systemctl --user daemon-reload
systemctl --user enable --now proton-drive-backup.timer >/dev/null
systemctl --user enable --now proton-drive-backup-check.timer >/dev/null
systemctl --user list-timers 'proton-drive-*' --no-pager

if [ "$HEADLESS" -eq 1 ]; then
    echo
    echo "== Headless checks =="
    # Without lingering, the user manager — and its timers — only lives while
    # someone is logged in: the backup would silently never run.
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ]; then
        echo "  Lingering enabled: timers run without anyone logged in."
    else
        echo "  WARNING: lingering is off, timers stop when you log out. Run:"
        echo "    sudo loginctl enable-linger $USER"
    fi
    # The CLI's default store is the desktop keychain, which does not exist here.
    # Captured first: `grep -q` in a pipe under pipefail can fail the test
    # through the writer's SIGPIPE.
    STORE_LINE="$(systemctl --user show-environment | grep '^PROTON_DRIVE_CREDENTIALS_STORE=' || true)"
    if [ -n "$STORE_LINE" ]; then
        echo "  Session store set for the timers: $STORE_LINE"
    else
        echo "  WARNING: PROTON_DRIVE_CREDENTIALS_STORE is not set for the timers."
        echo "  See 'Headless hosts' in the README."
    fi
    # Read the way the scripts read it, quotes, comments and overrides included.
    # Joined on a unit separator rather than a newline: $(...) strips trailing
    # newlines, which would merge an empty NOTIFY_COMMAND into NOTIFY.
    NOTIFY_SETTINGS="$(set +eu; source "$REPO/lib/common.sh"; \
        printf '%s\037%s\037' "$NOTIFY_BACKENDS" "$NOTIFY_COMMAND")"
    NOTIFY_BACKENDS="${NOTIFY_SETTINGS%%$'\037'*}"
    NOTIFY_COMMAND="${NOTIFY_SETTINGS#*$'\037'}"
    NOTIFY_COMMAND="${NOTIFY_COMMAND%$'\037'}"
    if [[ " $NOTIFY_BACKENDS " != *" command "* ]]; then
        echo "  NOTE: NOTIFY has no 'command' in $CONF_DIR/backup.conf:"
        echo "  desktop notifications reach nobody here. See NOTIFY_COMMAND in the README."
    elif [[ "$NOTIFY_COMMAND" != /* ]] || [ ! -f "$NOTIFY_COMMAND" ] || [ ! -x "$NOTIFY_COMMAND" ]; then
        echo "  WARNING: NOTIFY_COMMAND must be an absolute path to an executable file:"
        echo "    '$NOTIFY_COMMAND'"
    fi
fi

echo
echo "Done. Review your mappings with:"
echo "  proton-drive-backup.sh --dry-run"
