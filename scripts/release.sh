#!/bin/bash
# Makes the download and puts it on GitHub, so the website's Download button gives it directly:
#
#   bash scripts/release.sh
#
# It builds dist/Navo-<version>.dmg (scripts/package.sh), then creates the GitHub release
# v<version> with two files: Navo.dmg (the name the website links to, always the newest) and
# Navo-<version>.dmg. Run again for the same version and the files are replaced.
# Needs the GitHub CLI, signed in: brew install gh && gh auth login
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SLUG="${NAVO_REPO_SLUG:-Devehab/STT-NAVO}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
DMG="dist/Navo-$VERSION.dmg"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "error: the GitHub CLI is needed. Run: brew install gh && gh auth login" >&2
  exit 1
fi

bash scripts/package.sh
[ -f "$DMG" ] || { echo "error: $DMG was not made" >&2; exit 1; }
cp -f "$DMG" dist/Navo.dmg

NOTES="Navo $VERSION for Apple Silicon Macs, macOS 14 or later.

Download Navo.dmg, open it and drag Navo into Applications.

This build is not signed with a paid Apple developer account, so macOS blocks it on the first open. Allow it once: open Navo, click Done, then System Settings > Privacy & Security > Open Anyway. Step by step: https://devehab.github.io/STT-NAVO/#first-open

SHA-256 of Navo-$VERSION.dmg: $(cut -d' ' -f1 < "$DMG.sha256")"

if gh release view "$TAG" --repo "$SLUG" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/Navo.dmg "$DMG" --repo "$SLUG" --clobber
  gh release edit "$TAG" --repo "$SLUG" --notes "$NOTES" --latest >/dev/null
  echo "==> Replaced the files of release $TAG"
else
  gh release create "$TAG" dist/Navo.dmg "$DMG" --repo "$SLUG" --title "Navo $VERSION" --notes "$NOTES" --latest
  echo "==> Created release $TAG"
fi

URL="https://github.com/$SLUG/releases/latest/download/Navo.dmg"
echo "==> Checking the download link"
if curl -fsIL -o /dev/null "$URL"; then
  echo "==> The Download button works: $URL"
else
  echo "!! The link does not answer yet: $URL. Wait a minute and open it in a browser."
fi
