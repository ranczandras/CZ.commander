#!/bin/zsh
# Publish a CZ.commander release to GitHub.
#   ./release.sh 1.1.0 "What changed in this version"
# Bumps VERSION, commits, builds + signs the app, zips it, tags vX.Y.Z, pushes and
# creates the GitHub release with the zip attached (always named CZ.commander.zip, so
# .../releases/latest/download/CZ.commander.zip is a stable download link). Older releases
# and their tags are deleted: GitHub only keeps the newest version.
# The installed app is NOT replaced by this script; it updates itself via the in-app updater.
set -e

VERSION="$1"
NOTES="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: ./release.sh <version> [notes]" >&2
    exit 1
fi

PROJECT_DIR="${0:A:h}"
BUILD_DIR="${CZ_BUILD_DIR:-$HOME/.cache/czcommander-build}"
GH="${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}"
cd "$PROJECT_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean; commit or stash first." >&2
    exit 1
fi

echo "$VERSION" > VERSION
git add VERSION
git commit -m "Release v$VERSION"

CZ_SKIP_INSTALL=1 zsh ./build_app.sh

ZIP="$BUILD_DIR/CZ.commander.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$BUILD_DIR/stage/CZ.commander.app" "$ZIP"

git tag "v$VERSION"
git push
git push origin "v$VERSION"

BODY="$NOTES

## Install
1. Download **CZ.commander.zip**, unzip it and move **CZ.commander.app** to /Applications.
2. The app is not notarized by Apple, so macOS blocks the first launch. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway** (or run
   \`xattr -dr com.apple.quarantine /Applications/CZ.commander.app\`).

Requires macOS 14 or later on Apple Silicon."

"$GH" release create "v$VERSION" "$ZIP" --title "CZ.commander $VERSION" --notes "$BODY" --latest

# Keep only the newest release on GitHub
REPO="$("$GH" repo view --json nameWithOwner -q .nameWithOwner)"
for TAG in $("$GH" release list --repo "$REPO" --limit 100 --json tagName -q '.[].tagName'); do
    if [[ "$TAG" != "v$VERSION" ]]; then
        echo "Removing old release $TAG"
        "$GH" release delete "$TAG" --repo "$REPO" --yes --cleanup-tag
    fi
done
echo "Released v$VERSION"
