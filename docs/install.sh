#!/bin/bash
# Installs Navo in one step:
#
#   curl -fsSL https://devehab.github.io/STT-NAVO/install.sh | bash
#
# It downloads the newest Navo.dmg from GitHub, copies Navo into Applications and opens it.
# Because the file comes through curl and not a browser, macOS does not put it in quarantine,
# so Navo opens right away with no "could not verify" warning. Nothing else is changed on the
# Mac, and no password is asked for. Read this file before running it if you like: it is short.
set -euo pipefail

URL="https://github.com/Devehab/STT-NAVO/releases/latest/download/Navo.dmg"

say() { printf '\n==> %s\n' "$1"; }
stop() { printf '\nNavo was not installed: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || stop "Navo is a Mac app."
[ "$(uname -m)" = "arm64" ] || stop "Navo needs a Mac with Apple Silicon (M1 or newer). This Mac has an Intel processor."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || stop "Navo needs macOS 14 or later. This Mac has macOS $(sw_vers -productVersion). Update it in System Settings > General > Software Update."

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    hdiutil detach "$MOUNT" -quiet 2>/dev/null || hdiutil detach "$MOUNT" -force -quiet 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

say "Downloading Navo"
curl -fL --progress-bar "$URL" -o "$WORK/Navo.dmg" || stop "the download failed. Check the internet connection and run the line again."

say "Installing"
MOUNT="$WORK/disk"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/Navo.dmg" -nobrowse -readonly -noautoopen -quiet -mountpoint "$MOUNT" || stop "the downloaded file could not be opened."
[ -d "$MOUNT/Navo.app" ] || stop "the download does not contain Navo."

DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/Navo.app"

if pgrep -x Navo >/dev/null 2>&1; then
  osascript -e 'tell application id "com.ehab-kahwati.navo" to quit' >/dev/null 2>&1 || pkill -x Navo || true
  sleep 1
fi
# An update replaces the app only. Your history, recordings and models are kept.
rm -rf "$DEST"
ditto "$MOUNT/Navo.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

say "Opening Navo"
open "$DEST"
printf '\nNavo is in %s and it is open now.\nIts window shows three steps: download the engine, allow the microphone, allow Accessibility.\n' "$DEST_DIR"
