"""The speech engines Navo can run, and how API requests pick one.

Each engine is one speech-to-text model. The server can load or unload each one on
request, so a Mac with less memory can keep only one. At most ``MAX_ENABLED_ENGINES``
are turned on at a time: four models in memory at once would crowd out everything else.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


@dataclass(frozen=True)
class EngineProfile:
    id: str
    name: str
    model_id: str
    family: str  # which backends can run it: "cohere_asr", "qwen3_asr" or "whisper"
    gated: bool
    # Files the engine never needs, skipped when downloading (GGUF and vLLM builds of the same model).
    ignore_patterns: tuple[str, ...] = ()
    # Request languages: "ar" (any dialect, with English mixed in), "en", "auto" where the
    # model can name the language itself, and the other ISO 639-1 codes the model knows.
    languages: tuple[str, ...] = ("ar", "en")
    aliases: tuple[str, ...] = field(default_factory=tuple)


COHERE = EngineProfile(
    id="cohere",
    name="Cohere Transcribe Arabic",
    model_id="CohereLabs/cohere-transcribe-arabic-07-2026",
    family="cohere_asr",
    gated=True,
    ignore_patterns=("*.gguf", "*.onnx"),
    aliases=("cohere-transcribe-arabic", "cohere-transcribe-arabic-07-2026", "cohere-transcribe"),
)

AUDAR = EngineProfile(
    id="audar",
    name="Audar ASR V1 Turbo",
    model_id="audarai/Audar-ASR-V1-Turbo",
    family="qwen3_asr",
    gated=False,
    ignore_patterns=("*.gguf", "vllm-*/*", "vllm-*"),
    languages=("ar", "en", "auto"),
    aliases=("audar-asr", "audar-asr-v1", "audar-asr-v1-turbo", "audar-turbo"),
)

# Whisper Large v3's 100 languages, as ISO 639-1 codes where there is one ("haw", "yue").
WHISPER_LANGUAGES = (
    "ar", "en", "auto",
    "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "sv", "it", "id", "hi",
    "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg",
    "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
    "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn",
    "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo", "ht", "ps",
    "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw",
    "su", "yue",
)

WHISPER = EngineProfile(
    id="whisper",
    name="Whisper Large v3 Turbo",
    model_id="mlx-community/whisper-large-v3-turbo-asr-fp16",
    family="whisper",
    gated=False,
    ignore_patterns=("*.gguf",),
    languages=WHISPER_LANGUAGES,
    # Never "whisper-1": OpenAI clients send it by default, and it keeps meaning the default engine.
    aliases=("whisper-large-v3-turbo", "whisper-turbo", "whisper-large-v3", "large-v3-turbo"),
)

# Qwen3-ASR's 30 languages (and 22 Chinese dialects, which come in as "zh").
QWEN3_LANGUAGES = (
    "ar", "en", "auto",
    "zh", "yue", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms",
    "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "hu", "mk", "ro",
)

QWEN3 = EngineProfile(
    id="qwen3",
    name="Qwen3-ASR 1.7B",
    model_id="mlx-community/Qwen3-ASR-1.7B-bf16",
    family="qwen3_asr",
    gated=False,
    ignore_patterns=("*.gguf",),
    languages=QWEN3_LANGUAGES,
    aliases=("qwen3-asr", "qwen3-asr-1.7b", "qwen3-asr-1.7b-bf16", "qwen3-asr-1.7b-fp16"),
)

PROFILES: dict[str, EngineProfile] = {p.id: p for p in (COHERE, AUDAR, WHISPER, QWEN3)}

# Engines that may be turned on at once. The others stay off: they never load and the API
# answers 503 for them until one of the two is turned off.
MAX_ENABLED_ENGINES = 2

# Every language some engine takes, in a stable order (for parsing request values).
ALL_LANGUAGES: tuple[str, ...] = tuple(dict.fromkeys(code for p in PROFILES.values() for code in p.languages))


def too_many_enabled(enabled: list[str] | tuple[str, ...] | set[str], engine_id: str) -> bool:
    """Turning `engine_id` on would go over the limit (an engine that is already on never does)."""
    return engine_id not in enabled and len(set(enabled)) >= MAX_ENABLED_ENGINES


def limit_message(enabled: list[str] | tuple[str, ...] | set[str], engine_id: str) -> str:
    on = [PROFILES[e].name if e in PROFILES else e for e in enabled]
    name = PROFILES[engine_id].name if engine_id in PROFILES else engine_id
    return (
        f"Only {MAX_ENABLED_ENGINES} speech engines can be on at once, and {' and '.join(on)} are on. "
        f"Turn one off first (POST /v1/engines/{{engine}}/disable), then turn on {name}."
    )


def ignore_patterns_for(model_id: str) -> list[str]:
    """Download filter for a Hugging Face repo id (known engines get their own list)."""
    for profile in PROFILES.values():
        if profile.model_id.lower() == model_id.lower():
            return list(profile.ignore_patterns)
    return ["*.gguf"]


def lookup(value: Optional[str], model_ids: Optional[dict[str, str]] = None) -> Optional[str]:
    """Engine id for an API `model` value such as "audar", "audar-asr-v1-turbo" or a Hugging Face id.

    Returns None when the value does not name an engine (for example "whisper-1" sent by an
    OpenAI client), so the caller can fall back to the default engine.
    """
    if not value:
        return None
    key = value.strip().lower()
    for profile in PROFILES.values():
        names = {
            profile.id,
            profile.model_id.lower(),
            profile.model_id.lower().split("/")[-1],
            *(alias.lower() for alias in profile.aliases),
        }
        if model_ids and profile.id in model_ids:
            names.add(model_ids[profile.id].lower())
        if key in names or key.split("/")[-1] in names:
            return profile.id
    return None
