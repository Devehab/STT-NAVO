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
# macOS ties the microphone, Accessibility and system audio permissions to the app's signature.
# When it changes (Navo 0.22.3 left a certificate Apple revoked), the old switches stay on in
# System Settings but no longer apply, so they are cleared and Navo asks once more.
OLD_SIGNATURE=""
[ -d "$DEST" ] && OLD_SIGNATURE="$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => //p')"

# An update replaces the app only. Your history, recordings and models are kept.
rm -rf "$DEST"
ditto "$MOUNT/Navo.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

NEW_SIGNATURE="$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => //p')"
if [ -n "$OLD_SIGNATURE" ] && [ "$OLD_SIGNATURE" != "$NEW_SIGNATURE" ]; then
  for service in Accessibility Microphone AudioCapture; do
    tccutil reset "$service" com.ehab-kahwati.navo >/dev/null 2>&1 || true
  done
  RESET_PERMISSIONS=1
fi

# macOS keeps a note of every Navo it has seen, also on installer disks that are gone (opening
# Navo.dmg in Finder leaves one). Several notes for one app can keep Spotlight from finding it, so
# the ones whose files are gone are dropped, and the installed copy is the one macOS knows.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$MOUNT/Navo.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -dump 2>/dev/null \
    | awk '/^path:/ { p = $0; sub(/^path: +/, "", p); sub(/ \(0x[0-9a-f]+\)$/, "", p) }
           /^identifier: +com\.ehab-kahwati\.navo$/ { print p }' \
    | sort -u | while IFS= read -r gone; do
        if [ -n "$gone" ] && [ "$gone" != "$MOUNT/Navo.app" ] && [ ! -e "$gone" ]; then
          "$LSREGISTER" -u "$gone" >/dev/null 2>&1 || true
          "$LSREGISTER" -u "$gone" >/dev/null 2>&1 || true
        fi
      done
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi
mdimport "$DEST" >/dev/null 2>&1 || true

say "Opening Navo"
open "$DEST"
printf '\nNavo is in %s and it is open now.\nIts window shows three steps: download the engine, allow the microphone, allow Accessibility.\n' "$DEST_DIR"
if [ "${RESET_PERMISSIONS:-0}" = 1 ]; then
  printf 'Navo is signed differently from the copy it replaced, so macOS asks once more for the microphone and Accessibility.\n'
fi
