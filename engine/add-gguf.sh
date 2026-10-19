#!/bin/bash
# Adds GGUF support to Navo's engine: llama.cpp with Metal, one ready-made package (nothing is
# compiled, no developer tools). Run by the app the first time a GGUF model is added
# (Settings > Cleanup and AI > Add a model), or by hand:  ./engine/add-gguf.sh
set -euo pipefail

SUPPORT_DIR="${NAVO_SUPPORT_DIR:-$HOME/Library/Application Support/Navo}"
VENV="$SUPPORT_DIR/engine/venv"
# Ready-made llama.cpp builds for Apple Silicon with Metal, by the llama-cpp-python project.
WHEELS="https://abetlen.github.io/llama-cpp-python/whl/metal"

export PATH="$HOME/.local/bin:$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export UV_PYTHON_PREFERENCE=only-managed
export UV_NO_PROGRESS=1

progress() { echo "NAVO_PROGRESS $1 $2"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$VENV/bin/python" ] || fail "Navo's engine is not installed yet. Install it first in Settings > Speech engines."

progress 0.05 "Checking uv"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh \
    || fail "Could not download the installer. Check the internet connection and try again."
fi
UV="$(command -v uv)" || fail "uv installation failed"

progress 0.15 "Downloading llama.cpp for GGUF models"
# These ready-made wheels carry a few extra bytes after their ZIP index, which uv's strict check
# refuses (pip accepts them). The relaxed check applies to this one install from that index only.
UV_INSECURE_NO_ZIP_VALIDATION=1 "$UV" pip install --python "$VENV/bin/python" --only-binary llama-cpp-python \
  --extra-index-url "$WHEELS" "llama-cpp-python>=0.3.33" \
  || fail "Could not add llama.cpp. Check the internet connection and try again."

progress 0.9 "Checking llama.cpp"
"$VENV/bin/python" -c "import llama_cpp; print('llama.cpp for GGUF models:', llama_cpp.__version__)" \
  || fail "llama.cpp was added but does not start on this Mac."
progress 1.0 "GGUF support added"
