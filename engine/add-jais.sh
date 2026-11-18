#!/bin/bash
# Adds what Jais-ASR needs to Navo's engine: mlx-vlm at the one commit IFM's Jais-ASR patch is
# made for, with that patch applied (jais/mlx-vlm-jais-asr.patch, from IFM/Jais-ASR-MLX-8bit,
# Apache 2.0), plus Pillow. Pure Python: nothing is compiled, no developer tools.
# Run by the app before it downloads Jais-ASR (Settings > Speech engines), or by hand:
#   ./engine/add-jais.sh
# Safe to run again: it stops early when the engine already has it.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="${NAVO_SUPPORT_DIR:-$HOME/Library/Application Support/Navo}"
VENV="$SUPPORT_DIR/engine/venv"
# mlx-vlm at the commit the patch is made for, and the checksum of that archive.
COMMIT="6ecadd767ca1c7c54763289c750dd180d7945037"
ARCHIVE_URL="https://github.com/Blaizzy/mlx-vlm/archive/$COMMIT.tar.gz"
ARCHIVE_SHA256="c4da040513b71de4fc91c46013b8b3dd937507274c37bf86b5be8be656aa5c42"
PATCH="$SRC_DIR/jais/mlx-vlm-jais-asr.patch"
PATCH_SHA256="f51698414bfdba710ce0cae42d773e567428abcaf758eb762476f5f4fe73ecc7"

export PATH="$HOME/.local/bin:$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PYTHONPYCACHEPREFIX="${PYTHONPYCACHEPREFIX:-$HOME/Library/Caches/Navo/pycache}"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_PROGRESS=1

progress() { echo "NAVO_PROGRESS $1 $2"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$VENV/bin/python" ] || fail "Navo's engine is not installed yet. Install it first in Settings > Speech engines."

check() {
  "$VENV/bin/python" - <<'PY'
import importlib
import inspect
for name in ("mlx_vlm", "mlx_vlm.models.jais_asr", "PIL"):
    importlib.import_module(name)
from mlx_vlm import generate, load
from mlx_vlm.generate import ar
# The patch's language pin: without it the engine could not hold Jais to Arabic or English.
assert "generation_processors" in inspect.getsource(ar), "mlx-vlm is not patched for Jais-ASR"
from importlib.metadata import version
print("Jais-ASR support: mlx-vlm", version("mlx-vlm"), "with the Jais-ASR patch")
PY
}

progress 0.02 "Checking Jais-ASR support"
if check >/dev/null 2>&1; then
  check
  progress 1.0 "Jais-ASR support is ready"
  exit 0
fi

[ -f "$PATCH" ] || fail "The Jais-ASR patch is missing from Navo. Download Navo again."
[ "$(shasum -a 256 "$PATCH" | awk '{ print $1 }')" = "$PATCH_SHA256" ] \
  || fail "The Jais-ASR patch in Navo is damaged. Download Navo again."

progress 0.05 "Checking uv"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh \
    || fail "Could not download the installer. Check the internet connection and try again."
fi
UV="$(command -v uv)" || fail "uv installation failed"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/navo-jais.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

progress 0.10 "Downloading mlx-vlm for Jais-ASR"
curl -fL --retry 3 --silent --show-error -o "$WORK/mlx-vlm.tar.gz" "$ARCHIVE_URL" \
  || fail "Could not download mlx-vlm. Check the internet connection and try again."
[ "$(shasum -a 256 "$WORK/mlx-vlm.tar.gz" | awk '{ print $1 }')" = "$ARCHIVE_SHA256" ] \
  || fail "The mlx-vlm download is not the expected file. Try again later."

progress 0.40 "Adding Jais-ASR to mlx-vlm"
mkdir "$WORK/src"
tar -xzf "$WORK/mlx-vlm.tar.gz" -C "$WORK/src" --strip-components 1 \
  || fail "Could not unpack mlx-vlm."
(cd "$WORK/src" && /usr/bin/patch -p1 --forward --silent < "$PATCH") \
  || fail "Could not apply the Jais-ASR patch to mlx-vlm."

progress 0.55 "Installing mlx-vlm and Pillow"
# --no-deps: the engine already has MLX, transformers, PyTorch and mlx-audio at versions mlx-vlm
# takes; its other requirements (OpenCV, a web server) are for images, video and its own server,
# which Navo never uses. Pillow is the one it imports for every model.
"$UV" pip install --python "$VENV/bin/python" --no-deps --reinstall-package mlx-vlm "$WORK/src" \
  || fail "Could not install mlx-vlm. Check the internet connection and try again."
"$UV" pip install --python "$VENV/bin/python" --only-binary Pillow "Pillow>=10.3.0" \
  || fail "Could not install Pillow. Check the internet connection and try again."

progress 0.92 "Checking Jais-ASR support"
check || fail "mlx-vlm was added but does not start on this Mac."
progress 1.0 "Jais-ASR support added"
