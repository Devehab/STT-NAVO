#!/bin/bash
# One command to go from source to a running Navo:
#   1. builds Navo.app
#   2. installs it to ~/Applications
#   3. on the first run, installs the local engine (reads HF_TOKEN from .env)
#   4. launches Navo
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/scripts/build-app.sh" "${1:-release}"

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Navo.app"
SUPPORT="$HOME/Library/Application Support/Navo"

mkdir -p "$DEST_DIR"
if pgrep -x Navo >/dev/null 2>&1; then
  echo "==> Quitting the running Navo"
  osascript -e 'tell application id "com.ehab-kahwati.navo" to quit' >/dev/null 2>&1 || pkill -x Navo || true
  sleep 1
fi
rm -rf "$DEST"
ditto "$ROOT/build/Navo.app" "$DEST"
echo "==> Installed $DEST"

# Tell macOS about the installed copy: the navo:// link the Share extension opens, Open With for
# audio files, and the Share extension itself. The build copy is unregistered so it never answers.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -u "$ROOT/build/Navo.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi
APPEX="$DEST/Contents/PlugIns/NavoShare.appex"
if [ -d "$APPEX" ]; then
  pluginkit -r "$ROOT/build/Navo.app/Contents/PlugIns/NavoShare.appex" >/dev/null 2>&1 || true
  pluginkit -a "$APPEX" >/dev/null 2>&1 || true
  pluginkit -e use -i com.ehab-kahwati.navo.share >/dev/null 2>&1 || true
  echo "==> Share extension registered: Share > Navo in Voice Memos and Finder"
fi

# macOS ties Accessibility, Microphone and System Audio approvals to the code signature. When the signature
# changes, the old switch stays on in System Settings but no longer applies, so clear it and
# let Navo ask once for the new signature.
DR_FILE="$ROOT/build/.designated-requirement"
DR="$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => //p')"
if [ ! -f "$DR_FILE" ] || [ "$(cat "$DR_FILE")" != "$DR" ]; then
  echo "==> New code signature: resetting Navo's old Accessibility, Microphone and System Audio approvals"
  tccutil reset Accessibility com.ehab-kahwati.navo >/dev/null 2>&1 || true
  tccutil reset Microphone com.ehab-kahwati.navo >/dev/null 2>&1 || true
  tccutil reset AudioCapture com.ehab-kahwati.navo >/dev/null 2>&1 || true
  echo "    Navo will ask for them once more."
fi
printf '%s' "$DR" > "$DR_FILE"

if [ ! -f "$SUPPORT/engine/installed.json" ]; then
  if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
  fi
  echo "==> First run: installing the local engine (one-time download, about 7 GB)"
  if ! NAVO_SUPPORT_DIR="$SUPPORT" bash "$DEST/Contents/Resources/engine/setup-engine.sh"; then
    echo "!! The engine install failed (see above). Fix it and run this script again,"
    echo "   or use Navo > Settings > Speech engines > Install local engine."
  fi
fi

open "$DEST"
echo "==> Navo is running. Hold Right Option and talk."
