#!/bin/bash
# Checks Jais-ASR in Navo on this Mac, end to end, and prints a report:
#
#   curl -fsSL https://devehab.github.io/STT-NAVO/check-jais.sh | bash
#   curl -fsSL https://devehab.github.io/STT-NAVO/check-jais.sh | bash -s -- --compare
#
# It sends four short recordings (two Levantine Arabic with English words in them, two English)
# to Navo's engine on this Mac and compares the text with what is said. Nothing leaves the Mac
# except downloading the check and the recordings from Navo's website. It uses Navo's own Python,
# so nothing is installed. Navo must be open, with Jais-ASR downloaded in Settings > Speech engines.
set -euo pipefail

PY="${NAVO_SUPPORT_DIR:-$HOME/Library/Application Support/Navo}/engine/venv/bin/python"
SITE="https://devehab.github.io/STT-NAVO"

[ -x "$PY" ] || { echo "Navo's engine is not installed on this Mac: open Navo > Settings > Speech engines > Install local engine." >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "$SITE/check-jais.py" -o "$WORK/check-jais.py" || { echo "Could not download the check. Check the internet connection." >&2; exit 2; }
"$PY" -I "$WORK/check-jais.py" "$@"
