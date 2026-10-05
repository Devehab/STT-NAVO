#!/bin/bash
# Opens Navo on made-up sample data, for screenshots and demos:
#
#   bash scripts/demo.sh
#
# Your own history, recordings and clipboard are not shown and not touched: the sample data
# lives in its own folder (~/Library/Application Support/Navo/Demo) and is filled again on
# every start. The clipboard is not read while the demo runs. Quit Navo and open it normally
# to get your own data back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/Navo.app"
if [ ! -d "$APP" ]; then
  APP="$ROOT/build/Navo.app"
fi
if [ ! -d "$APP" ]; then
  echo "error: Navo is not built yet. Run: bash scripts/run.sh" >&2
  exit 1
fi

if pgrep -x Navo >/dev/null 2>&1; then
  echo "==> Quitting the running Navo"
  osascript -e 'tell application id "com.ehab-kahwati.navo" to quit' >/dev/null 2>&1 || pkill -x Navo || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Navo >/dev/null 2>&1 || break
    sleep 0.5
  done
fi

open -n "$APP" --args --demo
echo "==> Navo is running on sample data."
echo "    To go back to your own: quit Navo, then open it again as usual."
