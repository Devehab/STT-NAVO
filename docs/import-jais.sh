#!/bin/bash
# Adds Jais-ASR to Navo in one line, however bad the connection:
#
#   curl -fsSL https://devehab.github.io/STT-NAVO/import-jais.sh | bash
#
# The two model files (7 GB) are taken from Downloads when they are there, for example after a
# browser download:
#   https://huggingface.co/IFM/Jais-ASR-MLX-8bit/resolve/main/model-00001-of-00002.safetensors?download=true
#   https://huggingface.co/IFM/Jais-ASR-MLX-8bit/resolve/main/model-00002-of-00002.safetensors?download=true
# Otherwise it downloads them into Downloads itself, continuing a stopped download where it was
# and reconnecting when the connection slows to a crawl. Run it again at any time: it goes on.
#
# It checks each file against the checksum Hugging Face publishes, moves it into the model folder
# Navo reads (the same disk, so nothing is copied and no space is needed), downloads the small
# files that go with it (settings and tokenizer, about 21 MB), and opens Navo with Jais-ASR ready.
# Another model: bash import-jais.sh owner/model (its .safetensors files in Downloads).
set -euo pipefail

# Everything is in one function, read in full before it runs: piped into bash, no command here
# can swallow the rest of the script.
main() {

local REPO="${1:-IFM/Jais-ASR-MLX-8bit}"
APP="${NAVO_APP:-/Applications/Navo.app}"
ENGINE_SRC="$APP/Contents/Resources/engine"
SUPPORT="${NAVO_SUPPORT_DIR:-$HOME/Library/Application Support/Navo}"
PY="$SUPPORT/engine/venv/bin/python"
DOWNLOADS="${NAVO_DOWNLOADS:-$HOME/Downloads}"
HUB="${HF_HUB_CACHE:-${HF_HOME:-$HOME/.cache/huggingface}/hub}"
MODEL_DIR="$HUB/models--${REPO//\//--}"
TITLE="$REPO"; [ "${REPO#IFM/Jais-ASR}" != "$REPO" ] && TITLE="Jais-ASR"
# Compiled Python goes to the cache, never into Navo.app (that would break its signature).
export PYTHONPYCACHEPREFIX="$HOME/Library/Caches/Navo/pycache"

say() { printf '\n==> %s\n' "$1"; }
stop() { printf '\n%s was not added: %s\n' "$TITLE" "$1" >&2; exit 1; }

[ -d "$ENGINE_SRC/navo_engine" ] || stop "Navo is not in $APP. Install it first: curl -fsSL https://devehab.github.io/STT-NAVO/install.sh | bash"
grep -q "jais" "$ENGINE_SRC/navo_engine/engines.py" || stop "this Navo is too old for Jais-ASR. Update it first: curl -fsSL https://devehab.github.io/STT-NAVO/install.sh | bash"
[ -x "$PY" ] || stop "Navo's engine is not installed yet: open Navo > Settings > Speech engines > Install local engine, then run this again."
cd "$HOME"

# A download of the same model that Navo itself started would compete with this one: stop it.
if pgrep -f "navo_engine.download --model $REPO" >/dev/null 2>&1; then
  say "Stopping Navo's own download of $REPO (the browser files replace it)"
  pkill -f "navo_engine.download --model $REPO" || true
  sleep 2
fi

if [ "$REPO" = "IFM/Jais-ASR-MLX-8bit" ] || [ "${REPO#IFM/Jais-ASR}" != "$REPO" ]; then
  say "Checking that Navo's engine can run Jais-ASR"
  bash "$ENGINE_SRC/add-jais.sh" | sed '/^NAVO_PROGRESS/d' || stop "Jais-ASR support could not be added (see above). Check the internet connection and run this again."
fi

say "Asking Hugging Face which files $REPO has"
LIST="$(curl -fsSL --retry 3 "https://huggingface.co/api/models/$REPO/tree/main")" || stop "could not reach Hugging Face. Check the internet connection."
# One line per big file: name, size, sha256.
FILES="$(printf '%s' "$LIST" | "$PY" -c '
import json, sys
for f in json.load(sys.stdin):
    lfs = f.get("lfs") or {}
    if f.get("type") == "file" and f["path"].endswith(".safetensors") and lfs.get("oid"):
        print(f["path"], f["size"], lfs["oid"])
')"
[ -n "$FILES" ] || stop "Hugging Face lists no model files for $REPO."

mkdir -p "$MODEL_DIR/blobs"
# Unfinished pieces of earlier downloads in Navo: they can never be finished, only take space.
find "$MODEL_DIR/blobs" -maxdepth 1 -name "*.incomplete" -delete 2>/dev/null || true

while read -r NAME SIZE SHA; do
  BLOB="$MODEL_DIR/blobs/$SHA"
  if [ -f "$BLOB" ] && [ "$(stat -f %z "$BLOB")" = "$SIZE" ]; then
    echo "$NAME: already in Navo's model folder"
    continue
  fi
  # The browser may have named it "model-…(1).safetensors" when there was one already.
  FOUND=""
  STEM="${NAME%.safetensors}"
  while IFS= read -r CANDIDATE; do
    if [ "$(stat -f %z "$CANDIDATE")" = "$SIZE" ]; then FOUND="$CANDIDATE"; break; fi
  done < <(find "$DOWNLOADS" -maxdepth 2 -type f -name "$STEM*.safetensors" 2>/dev/null)
  if [ -z "$FOUND" ]; then
    # Not there (or not finished): download it here, the way that survives a bad connection.
    # -C - continues a file that is partly there, --speed-limit drops a connection that crawls
    # below 100 KB/s for a minute, and the loop opens a new one; nothing downloaded is lost.
    FOUND="$DOWNLOADS/$NAME"
    HAVE=0; [ -f "$FOUND" ] && HAVE="$(stat -f %z "$FOUND")"
    FREE="$(df -k "$DOWNLOADS" | awk 'NR == 2 { print $4 * 1024 }')"
    if [ "$(( SIZE - HAVE + 1000000000 ))" -gt "$FREE" ]; then
      stop "not enough free space for $NAME: it needs $(( (SIZE - HAVE) / 1000000000 + 1 )) GB more and this Mac has $(( FREE / 1000000000 )) GB free."
    fi
    say "Downloading $NAME ($(( SIZE / 1000000 )) MB$( [ "$HAVE" -gt 0 ] && echo ", continuing from $(( HAVE / 1000000 )) MB"))"
    TRY=0
    while [ "$(stat -f %z "$FOUND" 2>/dev/null || echo 0)" -lt "$SIZE" ]; do
      TRY=$((TRY + 1))
      [ "$TRY" -le 60 ] || stop "$NAME did not finish after many tries. Run this line again later: it continues where it stopped."
      [ "$TRY" -gt 1 ] && echo "Reconnecting (try $TRY): continuing from $(( $(stat -f %z "$FOUND") / 1000000 )) MB"
      curl -fL -C - --progress-bar --connect-timeout 30 --speed-limit 100000 --speed-time 60 \
        -o "$FOUND" "https://huggingface.co/$REPO/resolve/main/$NAME?download=true" || sleep 5
    done
    [ "$(stat -f %z "$FOUND")" = "$SIZE" ] || stop "$NAME came out larger than expected. Delete $FOUND and run this line again."
  fi
  say "Checking $(basename "$FOUND") ($(( SIZE / 1000000 )) MB, about a minute)"
  GOT="$(shasum -a 256 "$FOUND" | cut -d' ' -f1)"
  if [ "$GOT" != "$SHA" ]; then
    stop "$(basename "$FOUND") is damaged (its checksum is not Hugging Face's). Delete it and download it again: https://huggingface.co/$REPO/resolve/main/$NAME?download=true"
  fi
  echo "Checksum matches Hugging Face's: the file is complete and intact."
  mv -f "$FOUND" "$BLOB"
  chmod 644 "$BLOB"
  echo "Moved into Navo's model folder."
done <<< "$FILES"

say "Adding the small files that go with the model (about 21 MB)"
PYTHONPATH="$ENGINE_SRC" "$PY" -m navo_engine.download --model "$REPO" --label "Jais-ASR" \
  | sed -n '/^NAVO_MODEL_PATH /p;/^ERROR/p' \
  || stop "the small files could not be downloaded (see above). Run this line again: the big files stay in place."

PYTHONPATH="$ENGINE_SRC" "$PY" -c "
import sys
from navo_engine.models import cached_snapshot
sys.exit(0 if cached_snapshot('$REPO') else 1)
" || stop "the model folder is not complete. Run this line again."

say "$TITLE is ready"
echo "In Navo: Settings > Speech engines. $TITLE shows as downloaded: turn it on, or click Use for dictation"
echo "(only two engines can be on at once: turn one off first if two are on)."
if [ -d "$APP" ] && ! pgrep -xq Navo; then
  open "$APP"
fi
}

main "$@"
