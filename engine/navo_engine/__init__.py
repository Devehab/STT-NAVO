"""Navo local engine.

A small localhost server that runs, on this Mac only:

* speech-to-text engines (Cohere Transcribe Arabic, Audar ASR V1 Turbo, Whisper Large v3
  Turbo and Qwen3-ASR 1.7B; up to two are on at once, each can be loaded or unloaded),
* language models that summarize and rewrite text (Gemma 4 E4B and Llama 3.1 8B; never in
  memory together with a speech model, at most 6 GB, asleep unless used),
* and a small MLX language model for transcript cleanup.

It exposes OpenAI-compatible endpoints.
"""

__version__ = "0.6.0"

DEFAULT_ASR_MODEL = "CohereLabs/cohere-transcribe-arabic-07-2026"
DEFAULT_LLM_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
DEFAULT_PORT = 7861
SAMPLE_RATE = 16000


def package_version(name: str):
    """Installed version of a Python package, without importing it (None when it is missing)."""
    from importlib import metadata

    try:
        return metadata.version(name)
    except Exception:
        return None
