#!/bin/bash
# CZ.commander installer: downloads the latest release from GitHub and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/ranczandras/CZ.commander/main/install.sh | bash
#
# The app is signed with a self-made certificate, so a copy downloaded with a browser is
# blocked by Gatekeeper ("damaged" / "cannot be opened"). Downloading with curl and clearing
# the quarantine flag avoids that. Later updates install from inside the app.
set -euo pipefail

REPO="ranczandras/CZ.commander"
URL="https://github.com/$REPO/releases/latest/download/CZ.commander.zip"
APP="CZ.commander.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "CZ.commander runs on macOS only." >&2
    exit 1
fi
version="$(sw_vers -productVersion)"
if (( ${version%%.*} < 14 )); then
    echo "CZ.commander needs macOS 14 Sonoma or newer (this Mac has $version)." >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading CZ.commander..."
curl -fL --progress-bar -o "$tmp/CZ.commander.zip" "$URL"
ditto -x -k "$tmp/CZ.commander.zip" "$tmp/unpacked"
if [[ ! -d "$tmp/unpacked/$APP" ]]; then
    echo "The download does not contain $APP." >&2
    exit 1
fi

dest="${CZ_INSTALL_DIR:-/Applications}"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi

if [[ -z "${CZ_INSTALL_DIR:-}" ]] && pgrep -x CZCommander >/dev/null 2>&1; then
    echo "Quitting the running CZ.commander..."
    osascript -e 'quit app "CZ.commander"' >/dev/null 2>&1 || true
    sleep 2
fi

rm -rf "${dest:?}/$APP"
ditto "$tmp/unpacked/$APP" "$dest/$APP"
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

echo "Installed: $dest/$APP"
if [[ -z "${CZ_NO_OPEN:-}" ]]; then
    open "$dest/$APP"
fi
