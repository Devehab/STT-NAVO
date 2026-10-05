"""Speech-to-text backends.

Cohere Transcribe Arabic (family ``cohere_asr``), tried in order when ``backend="auto"``:

* ``mlx``: mlx-audio's native Cohere ASR port. Fastest on Apple Silicon.
* ``transformers``: the reference implementation on PyTorch (MPS when available).

Audar ASR V1 Turbo (family ``qwen3_asr``, a Qwen3-ASR fine-tune):

* ``mlx``: mlx-audio's Qwen3-ASR port, with Audar's own output head and its 30 second
  context. The model card's transformers path needs transformers 4.57, which conflicts
  with Cohere's requirement, so there is no PyTorch fallback for this family.

Qwen3-ASR 1.7B (family ``qwen3_asr``, the base model Audar is built on):

* ``mlx``: the same port. Its output head is tied to the embeddings, so nothing is restored.

Whisper Large v3 Turbo (family ``whisper``):

* ``mlx``: mlx-audio's Whisper port, one 30 second window per call, without timestamps.

Every call into a backend runs on the single worker thread owned by the server
(MLX streams are thread local), so this module does no locking of its own.
"""

from __future__ import annotations

import gc
import json
import logging
import re
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Protocol

import numpy as np

from . import SAMPLE_RATE
from .models import dir_size, resolve_model_dir
from .splitting import is_silent, split_for_model

log = logging.getLogger("navo.asr")

SUPPORTED_LANGUAGES = ("ar", "en", "auto")
LANGUAGE_ALIASES = {
    "automatic": "auto",
    "detect": "auto",
    "arabic": "ar",
    "english": "en",
    "chinese": "zh",
    "mandarin": "zh",
    "cantonese": "yue",
    "french": "fr",
    "german": "de",
    "spanish": "es",
    "portuguese": "pt",
    "italian": "it",
    "russian": "ru",
    "japanese": "ja",
    "korean": "ko",
    "turkish": "tr",
    "hindi": "hi",
    "urdu": "ur",
    "persian": "fa",
    "farsi": "fa",
    "hebrew": "he",
    "iw": "he",  # Hebrew's old code
    "dutch": "nl",
    "indonesian": "id",
    "malay": "ms",
    "filipino": "fil",
    "tagalog": "tl",
    "zh-hk": "yue",  # Hong Kong: Cantonese
}


def normalize_language(value: Optional[str], allowed: tuple[str, ...] = SUPPORTED_LANGUAGES) -> str:
    """Language code for a request value such as "ar", "Arabic", "en-US", "fr-FR" or "auto".

    A regional code (en-US, ar-SA, pt-BR) is taken as its language when the region itself is
    not one the engines know (zh-HK means Cantonese).
    """
    code = (value or "ar").strip().lower().replace("_", "-")
    code = LANGUAGE_ALIASES.get(code, code)
    if code not in allowed and "-" in code:
        base = code.split("-", 1)[0]
        code = LANGUAGE_ALIASES.get(base, base)
    if code not in allowed:
        shown = ", ".join(allowed) if len(allowed) <= 12 else ", ".join(allowed[:12]) + ", ..."
        raise ValueError(f"Unsupported language '{value}'. Use an ISO 639-1 code such as: {shown}")
    return code


SUPPORTED_FORMATS = "WAV, FLAC, MP3, OGG (Vorbis or Opus), AIFF or CAF"

# Non-speech markers the recognizer can emit, such as <hesitation>.
_MARKERS = re.compile(r"<\|?[a-z_]{2,24}\|?>")
_SPACES = re.compile(r"[ \t]{2,}")
_SPACE_BEFORE_PUNCT = re.compile(r"[ \t]+([,.!?;:،؛؟])")


def clean_markers(text: str) -> str:
    """Removes recognizer markers like <hesitation> and tidies the spacing they leave behind."""
    if "<" not in text:
        return text.strip()
    text = _MARKERS.sub(" ", text)
    text = _SPACES.sub(" ", text)
    text = _SPACE_BEFORE_PUNCT.sub(r"\1", text)
    return text.strip()


class AudioDecodeError(ValueError):
    """The uploaded file is not audio this engine can read."""


class EngineNotReady(RuntimeError):
    """The engine is turned off, or its model failed to load."""


@dataclass
class Transcription:
    text: str
    audio_seconds: float


def load_audio(path: str | Path) -> np.ndarray:
    """Read any soundfile-supported file as mono float32 at 16 kHz."""
    import soundfile as sf

    try:
        data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    except Exception as exc:
        raise AudioDecodeError(
            f"Could not read the audio ({str(exc).rstrip('.')}). Send {SUPPORTED_FORMATS}, or convert first, "
            "for example: ffmpeg -i input.m4a -ar 16000 -ac 1 output.wav"
        ) from exc
    if data.size == 0:
        raise AudioDecodeError("The audio file contains no samples")
    audio = data.mean(axis=1) if data.shape[1] > 1 else data[:, 0]
    if sr != SAMPLE_RATE:
        import librosa

        audio = librosa.resample(audio, orig_sr=sr, target_sr=SAMPLE_RATE)
    return np.ascontiguousarray(audio, dtype=np.float32)


class Backend(Protocol):
    name: str

    def transcribe(self, audio: np.ndarray, language: str) -> str: ...


class MLXBackend:
    """Cohere Transcribe Arabic on MLX."""

    name = "mlx"
    device = "Apple GPU (MLX)"
    # Longer audio would be split again inside mlx-audio (above 30 s) with a plainer method,
    # so the service hands it pieces cut at pauses that stay under this.
    max_seconds = 29.5

    def __init__(self, model_dir: Path):
        import mlx.core as mx
        from mlx_audio.stt import load as load_stt

        self._mx = mx
        self._model = load_stt(str(model_dir))

    def warm_up(self) -> None:
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), "en")

    def transcribe(self, audio: np.ndarray, language: str) -> str:
        try:
            result = self._model.generate(audio, language=language, max_tokens=512)
            return (getattr(result, "text", "") or "").strip()
        finally:
            self._mx.clear_cache()


class TransformersBackend:
    name = "transformers"
    max_seconds = 29.5  # the processor splits anything longer on its own

    def __init__(self, model_dir: Path):
        import torch
        from transformers import AutoProcessor

        try:
            from transformers import CohereAsrForConditionalGeneration as model_cls

            extra = {}
        except ImportError:  # older transformers: fall back to the repo's remote code
            from transformers import AutoModelForSpeechSeq2Seq as model_cls

            extra = {"trust_remote_code": True}

        self._torch = torch
        if torch.backends.mps.is_available():
            self.device, dtype = "mps", torch.bfloat16
        else:
            self.device, dtype = "cpu", torch.float32
        self.device_label = "Apple GPU (PyTorch MPS)" if self.device == "mps" else "CPU (PyTorch)"

        self._processor = AutoProcessor.from_pretrained(str(model_dir), **extra)
        self._model = model_cls.from_pretrained(str(model_dir), dtype=dtype, **extra).to(self.device).eval()

    def warm_up(self) -> None:
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), "en")

    def transcribe(self, audio: np.ndarray, language: str) -> str:
        torch = self._torch
        inputs = self._processor(audio, sampling_rate=SAMPLE_RATE, return_tensors="pt", language=language)
        chunk_index = inputs.get("audio_chunk_index")
        inputs = inputs.to(self._model.device, dtype=self._model.dtype)
        with torch.inference_mode():
            outputs = self._model.generate(**inputs, max_new_tokens=512)
        if chunk_index is not None:
            texts = self._processor.decode(
                outputs, skip_special_tokens=True, audio_chunk_index=chunk_index, language=language
            )
            text = texts[0] if isinstance(texts, (list, tuple)) else texts
        else:
            text = self._processor.decode(outputs[0], skip_special_tokens=True)
        if self.device == "mps":
            torch.mps.empty_cache()
        return (text or "").strip()


# Qwen3-ASR prefixes its output with "language <Name><asr_text>"; "language None" marks non-speech.
_QWEN_PREFIX = re.compile(r"language\s*([A-Za-z]+)\s*<asr_text>", re.IGNORECASE)
# A unit of up to 60 characters repeated 10 or more times in a row: a decoding loop, not speech.
_LOOP = re.compile(r"(.{1,60}?)(?:\s*\1){9,}", re.DOTALL)


def collapse_loops(text: str) -> str:
    return _LOOP.sub(r"\1", text)


def clean_qwen3_output(text: str) -> str:
    """Strips the language prefix, drops non-speech segments and collapses decoding loops."""
    parts = _QWEN_PREFIX.split(text or "")
    kept = [parts[0]]
    for language, segment in zip(parts[1::2], parts[2::2]):
        if language.lower() != "none":
            kept.append(segment)
    return collapse_loops(" ".join(p.strip() for p in kept if p.strip())).strip()


def read_tensor(model_dir: Path, names: tuple[str, ...]):
    """One tensor from a safetensors checkpoint (mx.load maps the file lazily, so only it is read)."""
    import mlx.core as mx

    files = sorted(model_dir.glob("*.safetensors"))
    index = model_dir / "model.safetensors.index.json"
    if index.exists():
        weight_map = json.loads(index.read_text()).get("weight_map", {})
        listed = [weight_map[n] for n in names if n in weight_map]
        if listed:
            files = [model_dir / listed[0]]
    for file in files:
        tensors = mx.load(str(file))
        for name in names:
            if name in tensors:
                return tensors[name]
    return None


def load_tokenizer(model_dir: Path):
    """The model's tokenizer from tokenizer.json and tokenizer_config.json only.

    Never reads config.json, so a checkpoint's custom configuration code (Audar's
    configuration_audar_asr.py targets transformers 4.57 and breaks on 5.x) is never run.
    """
    import transformers

    failures = []
    for name in ("Qwen2TokenizerFast", "Qwen2Tokenizer", "PreTrainedTokenizerFast"):
        tokenizer_class = getattr(transformers, name, None)
        if tokenizer_class is None:
            continue
        try:
            return tokenizer_class.from_pretrained(str(model_dir), trust_remote_code=False)
        except Exception as exc:  # try the next class
            failures.append(f"{name}: {exc}")
    raise RuntimeError("Could not load the tokenizer: " + " | ".join(failures))


@contextmanager
def tokenizer_without_remote_code(model_dir: Path):
    """While loading, AutoTokenizer for this model uses load_tokenizer instead of the repo's code.

    mlx-audio's Qwen3-ASR loader calls AutoTokenizer.from_pretrained(path, trust_remote_code=True),
    which makes transformers import the repo's configuration file first. The patch only
    applies to this model folder and is removed as soon as loading ends. Loading happens on
    the engine's single model thread, so nothing else sees it.
    """
    import transformers

    auto = transformers.AutoTokenizer
    own = "from_pretrained" in auto.__dict__
    original = auto.__dict__["from_pretrained"] if own else None
    bound = auto.from_pretrained
    target = Path(model_dir).resolve()

    def from_pretrained(cls, path, *args, **kwargs):
        try:
            same = Path(str(path)).resolve() == target
        except (OSError, RuntimeError):
            same = False
        return load_tokenizer(target) if same else bound(path, *args, **kwargs)

    auto.from_pretrained = classmethod(from_pretrained)
    try:
        yield
    finally:
        if own:
            auto.from_pretrained = original
        else:
            del auto.from_pretrained


class Qwen3MLXBackend:
    """Qwen3-ASR models (Audar ASR V1 Turbo, Qwen3-ASR 1.7B) on MLX through mlx-audio."""

    name = "mlx"
    device = "Apple GPU (MLX)"
    # Audar's context is 30 s: the service hands it pieces cut at pauses that stay under this.
    max_seconds = 28.0
    # The model card's setting: generous for 30 s of speech, and a stop for decoding loops.
    MAX_TOKENS_PER_CHUNK = 256
    # The names Qwen3-ASR's prompt uses (its config's support_languages). "auto" lets the model
    # name the language itself (it writes "language English<asr_text>").
    LANGUAGE_NAMES = {
        "auto": None,
        "ar": "Arabic",
        "en": "English",
        "zh": "Chinese",
        "yue": "Cantonese",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "pt": "Portuguese",
        "id": "Indonesian",
        "it": "Italian",
        "ko": "Korean",
        "ru": "Russian",
        "th": "Thai",
        "vi": "Vietnamese",
        "ja": "Japanese",
        "tr": "Turkish",
        "hi": "Hindi",
        "ms": "Malay",
        "nl": "Dutch",
        "sv": "Swedish",
        "da": "Danish",
        "fi": "Finnish",
        "pl": "Polish",
        "cs": "Czech",
        "fil": "Filipino",
        "fa": "Persian",
        "el": "Greek",
        "hu": "Hungarian",
        "mk": "Macedonian",
        "ro": "Romanian",
    }

    def __init__(self, model_dir: Path):
        import mlx.core as mx
        from mlx_audio.stt import load as load_stt

        self._mx = mx
        with tokenizer_without_remote_code(Path(model_dir)):
            self._model = load_stt(str(model_dir))
        self._restore_output_head(Path(model_dir))

    def _restore_output_head(self, model_dir: Path) -> None:
        """mlx-audio drops lm_head.weight because base Qwen3-ASR ties it to the embeddings.

        Audar ships an untied head (tie_word_embeddings is false), so without this step the
        head would keep its random initial values and the output would be noise.
        """
        inner = getattr(self._model, "_model", self._model)
        head = getattr(inner, "lm_head", None)
        if head is None:
            return
        weight = read_tensor(model_dir, ("thinker.lm_head.weight", "lm_head.weight"))
        if weight is None:
            raise RuntimeError("The checkpoint has no lm_head.weight although the model config asks for one")
        if tuple(weight.shape) != tuple(head.weight.shape):
            raise RuntimeError(f"lm_head.weight has shape {tuple(weight.shape)}, expected {tuple(head.weight.shape)}")
        head.update({"weight": weight})
        self._mx.eval(head.parameters())

    def _generate(self, audio: np.ndarray, language: str, max_tokens: int) -> str:
        result = self._model.generate(
            audio,
            language=self.LANGUAGE_NAMES.get(language, language),  # None: detect
            max_tokens=max_tokens,
            temperature=0.0,
            chunk_duration=60.0,  # already split, never split again
        )
        return getattr(result, "text", "") or ""

    def warm_up(self) -> None:
        try:
            self._generate(np.zeros(SAMPLE_RATE, dtype=np.float32), "en", max_tokens=4)
        finally:
            self._mx.clear_cache()

    def transcribe(self, audio: np.ndarray, language: str) -> str:
        try:
            return clean_qwen3_output(self._generate(audio, language, self.MAX_TOKENS_PER_CHUNK))
        finally:
            self._mx.clear_cache()


class WhisperMLXBackend:
    """Whisper Large v3 Turbo on MLX through mlx-audio."""

    name = "mlx"
    device = "Apple GPU (MLX)"
    # Whisper hears 30 s at a time: the service hands it pieces cut at pauses that stay under
    # this, so every call is one window and nothing is cut in the middle of a word.
    max_seconds = 28.0
    # Tried in turn when a window comes out repetitive or unsure (Whisper's own fallback).
    TEMPERATURES = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)

    def __init__(self, model_dir: Path):
        import mlx.core as mx
        from mlx_audio.stt import load as load_stt

        self._mx = mx
        self._model = load_stt(str(model_dir))
        if getattr(self._model, "_processor", None) is None:
            raise RuntimeError("The Whisper tokenizer files are missing from the model folder")

    def _generate(self, audio: np.ndarray, language: str, temperature=TEMPERATURES) -> str:
        result = self._model.generate(
            audio,
            language=None if language == "auto" else language,  # None: detect
            task="transcribe",
            temperature=temperature,
            condition_on_previous_text=False,  # each piece stands alone: no loops carried over
            return_timestamps=False,
            verbose=None,
        )
        return getattr(result, "text", "") or ""

    def warm_up(self) -> None:
        try:
            self._generate(np.zeros(SAMPLE_RATE, dtype=np.float32), "en", temperature=0.0)
        finally:
            self._mx.clear_cache()

    def transcribe(self, audio: np.ndarray, language: str) -> str:
        try:
            return collapse_loops(self._generate(audio, language)).strip()
        finally:
            self._mx.clear_cache()


BACKENDS: dict[str, Callable[[Path], Backend]] = {
    "mlx": MLXBackend,
    "transformers": TransformersBackend,
}

BACKENDS_BY_FAMILY: dict[str, dict[str, Callable[[Path], Backend]]] = {
    "cohere_asr": BACKENDS,
    "qwen3_asr": {"mlx": Qwen3MLXBackend},
    "whisper": {"mlx": WhisperMLXBackend},
}


def release_memory() -> None:
    """Hands freed model memory back to macOS after an unload."""
    gc.collect()
    if "mlx.core" in sys.modules:
        try:
            sys.modules["mlx.core"].clear_cache()
        except Exception:
            pass
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            if torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception:
            pass


class ASRService:
    """One speech engine: its loaded backend and lifecycle state for /health.

    Status:
    * ``off``: turned off. Never loads, requests are refused.
    * ``asleep``: turned on but not in memory. The next request loads it.
    * ``loading``, ``ready``, or ``error`` (loading failed; ``error`` says why).
    """

    def __init__(
        self,
        model_id: str,
        backend: str = "auto",
        allow_download: bool = False,
        backends: Optional[dict[str, Callable[[Path], Backend]]] = None,
        model_resolver: Callable[[str, bool], Path] = resolve_model_dir,
        engine_id: str = "cohere",
        name: str = "Cohere Transcribe Arabic",
        family: str = "cohere_asr",
        languages: tuple[str, ...] = ("ar", "en"),
    ):
        self.engine_id = engine_id
        self.name = name
        self.family = family
        self.languages = languages
        self.model_id = model_id
        self.backend_preference = backend
        self.allow_download = allow_download
        self._backends = backends or BACKENDS_BY_FAMILY.get(family, BACKENDS)
        self._resolve = model_resolver
        self.backend: Optional[Backend] = None
        self.enabled = False
        self.status = "off"
        self.error: Optional[str] = None
        self.last_used: Optional[float] = None
        self.load_seconds: Optional[float] = None
        self.model_path: Optional[str] = None
        self.model_bytes: Optional[int] = None
        self.transcriptions = 0
        self.last_processing_ms: Optional[int] = None

    @property
    def backend_name(self) -> Optional[str]:
        return self.backend.name if self.backend else None

    @property
    def device(self) -> Optional[str]:
        if self.backend is None:
            return None
        return getattr(self.backend, "device_label", None) or getattr(self.backend, "device", None)

    @property
    def idle_seconds(self) -> Optional[float]:
        """Seconds since the model was last used, while it is in memory."""
        if self.backend is None or self.last_used is None:
            return None
        return round(time.monotonic() - self.last_used, 1)

    def set_enabled(self, enabled: bool) -> None:
        """Turned on means allowed to load on demand. Call unload() first when turning off a loaded engine."""
        self.enabled = enabled
        if not enabled and self.backend is None and self.status != "loading":
            self.status, self.error = "off", None
        elif enabled and self.backend is None and self.status in ("off", "error"):
            # Turning on again also retries an engine whose load failed (for example before its download).
            self.status, self.error = "asleep", None

    @property
    def downloaded(self) -> bool:
        try:
            self._resolve(self.model_id, False)
            return True
        except Exception:
            return False

    def info(self) -> dict:
        return {
            "id": self.engine_id,
            "name": self.name,
            "model": self.model_id,
            "languages": list(self.languages),
            "status": self.status,
            "downloaded": self.status in ("ready", "loading") or self.downloaded,
            "backend": self.backend_name,
            "device": self.device,
            "error": self.error,
            "load_seconds": self.load_seconds,
            "idle_seconds": self.idle_seconds,
            "model_path": self.model_path,
            "model_bytes": self.model_bytes,
            "transcriptions": self.transcriptions,
            "last_processing_ms": self.last_processing_ms,
        }

    def load(self) -> None:
        if self.status == "ready" and self.backend is not None:
            return
        self.status, self.error = "loading", None
        started = time.perf_counter()
        try:
            model_dir = self._resolve(self.model_id, self.allow_download)
        except Exception as exc:
            log.error("Model not available: %s", exc)
            self.status, self.error = "error", str(exc)
            return
        self.model_path = str(model_dir)
        try:
            self.model_bytes = dir_size(Path(model_dir))
        except Exception:
            self.model_bytes = None

        order = list(self._backends) if self.backend_preference == "auto" else [self.backend_preference]
        failures = []
        for name in order:
            factory = self._backends.get(name)
            if factory is None:
                failures.append(f"{name}: unknown backend")
                continue
            try:
                log.info("Loading %s with the %s backend", self.model_id, name)
                candidate = factory(model_dir)
                warm_up = getattr(candidate, "warm_up", None)
                if warm_up is not None:
                    warm_up()
                else:
                    candidate.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), "en")
                self.backend = candidate
                self.status = "ready"
                self.last_used = time.monotonic()
                self.load_seconds = round(time.perf_counter() - started, 2)
                log.info("%s ready on %s in %.1fs", self.name, name, self.load_seconds)
                return
            except Exception as exc:  # try the next backend
                log.exception("Backend %s failed", name)
                failures.append(f"{name}: {exc}")
                candidate = None
                release_memory()

        self.status, self.error = "error", " | ".join(failures) or "No backend available"

    def unload(self) -> None:
        """Frees the model memory. A turned-on engine goes to sleep and loads again on the next request."""
        was_loaded = self.backend is not None
        self.backend = None
        self.status, self.error = ("asleep" if self.enabled else "off"), None
        self.load_seconds = None
        self.last_used = None
        release_memory()
        if was_loaded:
            log.info("%s unloaded, memory freed", self.name)

    def _require_ready(self) -> None:
        if self.backend is None or self.status != "ready":
            detail = f"{self.name} is {self.status}"
            raise EngineNotReady(detail + (f": {self.error}" if self.error else ""))

    def check_language(self, language: str) -> None:
        if language not in self.languages:
            raise ValueError(
                f"{self.name} does not support language '{language}'. Use one of: {', '.join(self.languages)}"
            )

    def transcribe_audio(self, audio: np.ndarray, language: str) -> str:
        """Transcript of 16 kHz mono float32 samples.

        Audio longer than the model takes is cut inside pauses (see splitting.py), and pieces
        with no sound at all are skipped: silence is where recognizers invent text.
        """
        self._require_ready()
        self.check_language(language)
        started = time.perf_counter()
        backend = self.backend
        limit = getattr(backend, "max_seconds", None)
        pieces = split_for_model(audio, limit) if limit else [(audio, 0.0)]
        texts = []
        try:
            for piece, _offset in pieces:
                if is_silent(piece):
                    continue
                text = clean_markers(backend.transcribe(piece, language) or "")
                if text:
                    texts.append(text)
        finally:
            self.last_used = time.monotonic()
        text = " ".join(texts)
        self.transcriptions += 1
        self.last_processing_ms = int((time.perf_counter() - started) * 1000)
        return text

    def transcribe_file(self, path: str | Path, language: str) -> Transcription:
        self._require_ready()
        started = time.perf_counter()
        audio = load_audio(path)
        text = self.transcribe_audio(audio, language)
        self.last_processing_ms = int((time.perf_counter() - started) * 1000)
        return Transcription(text=text, audio_seconds=len(audio) / SAMPLE_RATE)
