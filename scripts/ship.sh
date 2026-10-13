#!/bin/bash
# Ships a new version in one go, every time work is finished:
#
#   bash scripts/ship.sh
#
#   1. builds and installs Navo on this Mac (scripts/run.sh), so a broken build stops here
#   2. pushes the code and the website to GitHub (scripts/publish.sh)
#   3. makes the DMG and the GitHub release, which the website's Download button and the
#      one-line installer always point to (scripts/release.sh)
#
# Before running it: the version in Resources/Info.plist is raised and CHANGELOG.md has a
# section for it. The release notes are taken from there.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

grep -q "^## $VERSION\$" CHANGELOG.md || {
  echo "error: CHANGELOG.md has no section for $VERSION. Add one, then run this again." >&2
  exit 1
}
if gh release view "v$VERSION" --repo "${NAVO_REPO_SLUG:-Devehab/STT-NAVO}" >/dev/null 2>&1; then
  echo "==> Release v$VERSION exists already: its files will be replaced."
fi

echo "==> 1/3 Building Navo $VERSION"
bash scripts/run.sh

echo "==> 2/3 Pushing the code and the website"
bash scripts/publish.sh "Navo $VERSION"

echo "==> 3/3 Making the download and the release"
bash scripts/release.sh

echo
echo "==> Navo $VERSION is out."
echo "    Website:  https://devehab.github.io/STT-NAVO/"
echo "    Download: https://github.com/Devehab/STT-NAVO/releases/latest/download/Navo.dmg"
