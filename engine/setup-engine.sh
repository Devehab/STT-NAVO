#!/bin/bash
# Installs Navo's local engine: uv, a Python 3.12 venv, MLX + PyTorch, and the models
# (speech to text, the cleanup model and, when asked for, the language models for AI writing).
# Run by the Navo app (Settings > Speech engines > Install) or by hand:
#   HF_TOKEN=hf_xxx ./engine/setup-engine.sh
#
# Environment:
#   NAVO_SUPPORT_DIR  default: ~/Library/Application Support/Navo
#   NAVO_ASR_MODELS   speech models to download, space separated.
#                     default: CohereLabs/cohere-transcribe-arabic-07-2026
#                     two engines: "CohereLabs/cohere-transcribe-arabic-07-2026 audarai/Audar-ASR-V1-Turbo"
#                     the others: mlx-community/whisper-large-v3-turbo-asr-fp16,
#                     mlx-community/Qwen3-ASR-1.7B-bf16
#   NAVO_ASR_MODEL    older name for a single speech model
#   NAVO_LLM_MODEL    local cleanup model, default: mlx-community/Qwen3-4B-Instruct-2507-4bit
#   NAVO_SKIP_LLM=1   skip downloading the cleanup model
#   NAVO_EXTRA_MODELS more models to download, space separated, for example the language models
#                     for AI writing (the app downloads them from Settings > AI writing):
#                     "mlx-community/gemma-4-e4b-it-4bit mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
#   HF_TOKEN          Hugging Face token (Cohere is gated; Audar, Whisper and Qwen3-ASR are public)
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="${NAVO_SUPPORT_DIR:-$HOME/Library/Application Support/Navo}"
ENGINE_HOME="$SUPPORT_DIR/engine"
VENV="$ENGINE_HOME/venv"
ASR_MODELS="${NAVO_ASR_MODELS:-${NAVO_ASR_MODEL:-CohereLabs/cohere-transcribe-arabic-07-2026}}"
LLM_MODEL="${NAVO_LLM_MODEL:-mlx-community/Qwen3-4B-Instruct-2507-4bit}"
if [ "${NAVO_SKIP_LLM:-0}" = "1" ]; then LLM_MODEL=""; fi

# GUI apps do not inherit the login shell PATH.
export PATH="$HOME/.local/bin:$HOME/.homebrew/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PYTHONUNBUFFERED=1

# Run from a terminal without a token: ask once (input is hidden). The app passes HF_TOKEN itself.
GATED_MODEL=""
for model in $ASR_MODELS; do
  case "$model" in CohereLabs/*) GATED_MODEL="$model" ;; esac
done
if [ -n "$GATED_MODEL" ] && [ -z "${HF_TOKEN:-}" ] && [ ! -s "${HF_HOME:-$HOME/.cache/huggingface}/token" ] && [ -t 0 ]; then
  echo "The Cohere speech model is gated on Hugging Face. Paste a Read token (hf_...) from the account"
  echo "that accepted the terms at https://huggingface.co/$GATED_MODEL"
  read -r -s -p "Hugging Face token: " HF_TOKEN
  echo
  export HF_TOKEN
fi

progress() { echo "NAVO_PROGRESS $1 $2"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(uname -m)" = "arm64" ] || fail "The local engine needs an Apple Silicon Mac (M1 or newer)."
mkdir -p "$ENGINE_HOME"

progress 0.02 "Checking uv"
if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found, installing it to ~/.local/bin"
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh
  export PATH="$HOME/.local/bin:$PATH"
fi
UV="$(command -v uv)" || fail "uv installation failed"
echo "Using $("$UV" --version)"

progress 0.06 "Creating Python 3.12 environment"
if [ ! -x "$VENV/bin/python" ]; then
  "$UV" venv --python 3.12 "$VENV"
fi

progress 0.12 "Installing MLX, PyTorch and transformers"
"$UV" pip install --python "$VENV/bin/python" --upgrade -r "$SRC_DIR/requirements.txt"

progress 0.30 "Checking packages"
"$VENV/bin/python" - <<'PY'
import importlib
for name in ("mlx_audio", "mlx_lm", "transformers", "torch", "fastapi", "uvicorn", "httpx", "soundfile"):
    importlib.import_module(name)
import torch, transformers, mlx_audio
print(f"torch {torch.__version__} (mps={torch.backends.mps.is_available()}), transformers {transformers.__version__}")
PY

export PYTHONPATH="$SRC_DIR"
set -- $ASR_MODELS
COUNT=$#
INDEX=0
for model in "$@"; do
  START=$(awk "BEGIN { printf \"%.3f\", 0.32 + 0.48 * $INDEX / $COUNT }")
  END=$(awk "BEGIN { printf \"%.3f\", 0.32 + 0.48 * ($INDEX + 1) / $COUNT }")
  "$VENV/bin/python" -m navo_engine.download --model "$model" --label "Downloading speech model" \
    --progress-start "$START" --progress-end "$END"
  INDEX=$((INDEX + 1))
done

if [ -n "$LLM_MODEL" ]; then
  "$VENV/bin/python" -m navo_engine.download --model "$LLM_MODEL" --label "Downloading cleanup model" \
    --progress-start 0.80 --progress-end 0.97
fi

for model in ${NAVO_EXTRA_MODELS:-}; do
  "$VENV/bin/python" -m navo_engine.download --model "$model" --label "Downloading $model" \
    --progress-start 0.97 --progress-end 0.99
done

cat > "$ENGINE_HOME/installed.json" <<JSON
{
  "asr_models": "$ASR_MODELS",
  "llm_model": "$LLM_MODEL",
  "extra_models": "${NAVO_EXTRA_MODELS:-}",
  "python": "$VENV/bin/python",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

progress 1.0 "Local engine installed"
echo "Done. Navo will start the engine automatically."
