#!/bin/bash
# Puts the project on GitHub and turns on the website (GitHub Pages from the docs folder):
#
#   bash scripts/publish.sh
#
# Run it again after any change to push the new version. Files in .gitignore (build, dist,
# backups, .env) are never uploaded.
set -euo pipefail

REPO="${NAVO_REPO:-https://github.com/Devehab/STT-NAVO.git}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -d .git ]; then
  git init -q -b main
  git remote add origin "$REPO"
fi
git remote set-url origin "$REPO"

if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  echo "error: .env is tracked by git. Remove it with: git rm --cached .env" >&2
  exit 1
fi

git add -A
if git diff --cached --quiet; then
  echo "==> Nothing new to commit"
else
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo "")"
  git commit -q -m "${1:-Navo $VERSION}"
  echo "==> Committed"
fi
git push -u origin main
echo "==> Pushed to $REPO"

# The website. Needs the GitHub CLI; without it, the two clicks are printed below.
SLUG="$(printf '%s' "$REPO" | sed -E 's#^https://github.com/##; s#\.git$##')"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if gh api "repos/$SLUG/pages" >/dev/null 2>&1; then
    echo "==> GitHub Pages is already on"
  elif gh api -X POST "repos/$SLUG/pages" -f 'source[branch]=main' -f 'source[path]=/docs' >/dev/null 2>&1; then
    echo "==> GitHub Pages turned on"
  else
    echo "!! Could not turn on GitHub Pages from here. Do it by hand (below)."
  fi
else
  echo "==> To turn on the website: github.com/$SLUG > Settings > Pages >"
  echo "    Source: Deploy from a branch, Branch: main, Folder: /docs, Save."
fi
OWNER="$(printf '%s' "$SLUG" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]')"
echo "==> Website (a minute or two after the first push): https://$OWNER.github.io/$(printf '%s' "$SLUG" | cut -d/ -f2)/"
