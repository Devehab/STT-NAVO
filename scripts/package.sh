#!/bin/bash
# Makes the download: dist/Navo-<version>.dmg, a disk image with Navo and a link to
# Applications, laid out so people drag Navo in. Anyone with an Apple Silicon Mac on macOS 14 or
# later can install it; Navo sets up its speech engine itself on the first run.
#
#   bash scripts/package.sh
#
# Without an Apple Developer ID, macOS asks once, on the first open, to allow Navo (System
# Settings > Privacy & Security > Open Anyway), and the disk image says how. With one, the
# download opens on any Mac with no warning. Store your notary login once, then pass both:
#
#   xcrun notarytool store-credentials navo --apple-id you@example.com --team-id TEAMID
#   NAVO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NAVO_NOTARY_PROFILE=navo \
#     bash scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Navo.app"
DIST="$ROOT/dist"
ART="$ROOT/scripts/dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$DIST/Navo-$VERSION.dmg"
NOTARY_PROFILE="${NAVO_NOTARY_PROFILE:-}"

WORK="$(mktemp -d)"
MOUNT=""

detach() {
  local _
  for _ in 1 2 3 4 5; do
    hdiutil detach "$1" -quiet 2>/dev/null && return 0
    sleep 1
  done
  hdiutil detach "$1" -force -quiet 2>/dev/null || true
}

cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then
    detach "$MOUNT"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. The app.
echo "==> Building Navo $VERSION"
bash "$ROOT/scripts/build-app.sh" release

# Read whole outputs before picking lines, so no command in a pipe is cut off early.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1 || true)"
SIGNER="$(printf '%s\n' "$SIGN_INFO" | sed -n 's/^Authority=//p' | sed -n 1p)"
DEVELOPER_ID=0
case "$SIGNER" in
  "Developer ID Application:"*) DEVELOPER_ID=1 ;;
esac
if [ -n "$NOTARY_PROFILE" ] && [ "$DEVELOPER_ID" = 0 ]; then
  echo "error: notarizing needs a \"Developer ID Application\" certificate. Set NAVO_SIGN_IDENTITY to it." >&2
  exit 1
fi
NOTARIZE=0
if [ "$DEVELOPER_ID" = 1 ] && [ -n "$NOTARY_PROFILE" ]; then
  NOTARIZE=1
fi
codesign --verify --deep --strict "$APP"

# 2. What the disk image holds: the app, a link to Applications, the window's background.
echo "==> Preparing the disk image"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Navo.app"
ln -s /Applications "$STAGE/Applications"
BACKGROUND="background"
if [ "$NOTARIZE" = 0 ]; then
  # Says how to allow Navo on the first open.
  BACKGROUND="background-unverified"
fi
tiffutil -cathidpicheck "$ART/$BACKGROUND.png" "$ART/$BACKGROUND@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 40 ))
RW="$WORK/navo-rw.dmg"
hdiutil create -quiet -size "${SIZE_MB}m" -fs HFS+ -volname "Navo" -srcfolder "$STAGE" -format UDRW -ov "$RW"
ATTACHED="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
MOUNT="$(printf '%s\n' "$ATTACHED" | awk -F'\t' '/Apple_HFS/ { sub(/[ \t]+$/, "", $NF); mount = $NF } END { print mount }')"
[ -d "$MOUNT" ] || { echo "error: could not open the disk image" >&2; exit 1; }

# The disk's own icon.
SETFILE="$(xcrun --find SetFile 2>/dev/null || true)"
if [ -n "$SETFILE" ]; then
  "$SETFILE" -a C "$MOUNT" || true
fi

# 3. The window people see: icons, positions and background. Finder does this, so macOS may ask
# once to let Terminal control Finder. Without it the disk image still works, it just looks plain.
DISK="$(basename "$MOUNT")"
if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 568}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Navo.app" of container window to {165, 205}
    set position of item "Applications" of container window to {495, 205}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "warning: Finder did not lay out the window. Allow Terminal in System Settings > Privacy & Security > Automation for the designed look."
else
  # Finder saves the layout in .DS_Store a moment after the window closes.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$MOUNT/.DS_Store" ] && break
    sleep 0.5
  done
fi
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
detach "$MOUNT"
MOUNT=""

# 4. Compress.
mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"
hdiutil convert "$RW" -quiet -format ULFO -o "$DMG"

# 5. With a Developer ID: sign the disk image, have Apple check it, and attach the result.
if [ "$DEVELOPER_ID" = 1 ]; then
  codesign --force --sign "$SIGNER" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  echo "==> Sending to Apple for notarization (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Made $DMG ($(du -h "$DMG" | cut -f1))"
echo "    SHA-256: $(cut -d' ' -f1 < "$DMG.sha256")"
if [ "$NOTARIZE" = 1 ]; then
  echo "    Notarized: opens on any Mac with no warning."
else
  echo "    Not notarized: on the first open people allow it once in System Settings > Privacy & Security > Open Anyway."
  echo "    To skip that step for everyone, see the top of this script (needs an Apple Developer ID)."
fi
