"""The local language models (Gemma and Llama) that summarize and rewrite text, on MLX.

They replace any cloud model: the text never leaves the Mac. Three rules keep them light on a
Mac with 16 GB (or 8 GB) of memory, and the server enforces them (see ``server.Engine``):

* **One kind of model in memory at a time.** Before a language model loads, every speech
  engine and the cleanup model leave memory; before a speech engine or the cleanup model
  loads, the language models leave. Everything runs on the server's single model thread, so
  the two can never overlap: a request simply waits for the one before it.
* **At most 6 GB.** Both models are 4 bit builds of about 4.5 GB, and a request may use at
  most ``context_tokens`` tokens (prompt plus answer), which bounds the memory the answer
  needs on top of the weights. Longer prompts are refused with a clear error instead of
  growing past the limit.
* **Asleep unless used.** A model loads for a request and leaves memory ``keep_alive``
  seconds after its last answer (at once when a speech model needs the room).
"""

from __future__ import annotations

import gc
import logging
import time
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from .llm import LLMUnavailable, message_text, strip_thinking
from .models import dir_size, resolve_model_dir

log = logging.getLogger("navo.llms")

GIB = 1024**3
# The most memory a language model may use: weights plus the working memory of one request.
MEMORY_LIMIT_BYTES = 6 * GIB
# Prompt plus answer, in tokens. With the larger model (Llama 3.1 8B, 4.5 GB of weights) this
# many tokens need about 0.8 GB more, which stays under the limit.
DEFAULT_CONTEXT_TOKENS = 6144
# Seconds a model stays in memory after its last answer, so a second request is quick.
DEFAULT_KEEP_ALIVE = 60.0
DEFAULT_MAX_TOKENS = 1024
MAX_OUTPUT_TOKENS = 2048
# Room always left for the answer.
MIN_OUTPUT_TOKENS = 128


@dataclass(frozen=True)
class LLMProfile:
    id: str
    name: str
    model_id: str
    maker: str
    license: str
    aliases: tuple[str, ...] = field(default_factory=tuple)


GEMMA = LLMProfile(
    id="gemma",
    name="Gemma 4 E4B",
    model_id="mlx-community/gemma-4-e4b-it-4bit",
    maker="Google",
    license="Apache 2.0",
    aliases=("gemma-4", "gemma4", "gemma-4-e4b", "gemma-4-e4b-it", "gemma-4-e4b-it-gguf"),
)

LLAMA = LLMProfile(
    id="llama",
    name="Llama 3.1 8B",
    model_id="mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
    maker="Meta",
    license="Llama 3.1 Community License",
    aliases=("llama-3.1", "llama3.1", "llama-3.1-8b", "llama-3.1-8b-instruct", "meta-llama-3.1-8b-instruct"),
)

LLM_PROFILES: dict[str, LLMProfile] = {p.id: p for p in (GEMMA, LLAMA)}


def lookup_llm(value: Optional[str], model_ids: Optional[dict[str, str]] = None) -> Optional[str]:
    """Language model id for an API ``model`` value such as "gemma", "llama-3.1-8b" or a Hugging Face id.

    None when the value names no language model (then ``/v1/chat/completions`` uses the cleanup model).
    """
    if not value:
        return None
    key = value.strip().lower()
    for profile in LLM_PROFILES.values():
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


class PromptTooLong(ValueError):
    """The prompt does not fit the context that keeps the model under its memory limit."""


class _Cancelled(Exception):
    """The client went away while the model was still reading the prompt."""


@dataclass
class Completion:
    text: str
    prompt_tokens: int
    completion_tokens: int
    finish_reason: str  # "stop", "length" or "cancelled"
    seconds: float
    tokens_per_second: float
    peak_memory_bytes: Optional[int]

    def usage(self) -> dict:
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.prompt_tokens + self.completion_tokens,
        }

    def stats(self) -> dict:
        return {
            "seconds": round(self.seconds, 2),
            "tokens_per_second": round(self.tokens_per_second, 1),
            "peak_memory_bytes": self.peak_memory_bytes,
        }


# (model, tokenizer, prompt ids, options) -> pieces of text, each with the finish reason
# (None until the last piece).
Generator = Callable[[Any, Any, list[int], dict], Iterator[tuple[str, Optional[str]]]]


def mlx_generate(model: Any, tokenizer: Any, prompt: list[int], options: dict) -> Iterator[tuple[str, Optional[str]]]:
    """Text from mlx-lm, piece by piece."""
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_logits_processors, make_sampler

    temperature = max(0.0, float(options.get("temperature", 0.0)))
    sampler = make_sampler(
        temp=temperature,
        top_p=float(options.get("top_p") or 0.0) if temperature > 0 else 0.0,
        top_k=int(options.get("top_k") or 0) if temperature > 0 else 0,
    )
    penalty = options.get("repetition_penalty")
    processors = make_logits_processors(repetition_penalty=float(penalty)) if penalty and float(penalty) != 1.0 else None
    cancelled = options.get("cancelled")

    def reading(done: int, total: int) -> None:
        # Reading a long prompt takes a while: stop here too when the client has left.
        if cancelled is not None and cancelled():
            raise _Cancelled()

    for response in stream_generate(
        model,
        tokenizer,
        prompt,
        max_tokens=int(options["max_tokens"]),
        sampler=sampler,
        logits_processors=processors,
        prompt_progress_callback=reading,
    ):
        yield response.text, response.finish_reason


def _mlx():
    try:
        import mlx.core as mx

        return mx
    except Exception:  # tests with a fake loader run without MLX
        return None


def _held_back(text: str, stops: list[str]) -> int:
    """Length of the longest end of ``text`` that is the start of a stop word."""
    longest = 0
    for stop in stops:
        for size in range(min(len(stop) - 1, len(text)), longest, -1):
            if text.endswith(stop[:size]):
                longest = size
                break
    return longest


class LanguageModel:
    """One language model: its weights while loaded, and its state for /health.

    Status: ``asleep`` (not in memory, the next request loads it), ``loading``, ``ready``,
    ``writing``, or ``error`` (loading failed; ``error`` says why).
    Every method that touches the model runs on the server's model thread.
    """

    def __init__(
        self,
        profile: LLMProfile,
        model_id: Optional[str] = None,
        context_tokens: int = DEFAULT_CONTEXT_TOKENS,
        memory_limit: int = MEMORY_LIMIT_BYTES,
        loader: Optional[Callable[[str], tuple[Any, Any]]] = None,
        generator: Optional[Generator] = None,
        model_resolver: Callable[[str, bool], Path] = resolve_model_dir,
    ):
        self.llm_id = profile.id
        self.name = profile.name
        self.maker = profile.maker
        self.license = profile.license
        self.model_id = model_id or profile.model_id
        self.context_tokens = max(1024, int(context_tokens))
        self.memory_limit = int(memory_limit)
        self._loader = loader
        self._generator = generator or mlx_generate
        self._resolve = model_resolver
        self._model: Any = None
        self._tokenizer: Any = None
        self._previous_limit: Optional[int] = None
        self.status = "asleep"
        self.error: Optional[str] = None
        self.load_seconds: Optional[float] = None
        self.last_used: Optional[float] = None
        self.expires_at: Optional[float] = None  # monotonic time it leaves memory, None: stays
        self.model_path: Optional[str] = None
        self.model_bytes: Optional[int] = None
        self.requests = 0
        self.last: Optional[Completion] = None
        self.peak_memory_bytes: Optional[int] = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    @property
    def idle_seconds(self) -> Optional[float]:
        if self._model is None or self.last_used is None:
            return None
        return round(time.monotonic() - self.last_used, 1)

    @property
    def downloaded(self) -> bool:
        try:
            self._resolve(self.model_id, False)
            return True
        except Exception:
            return False

    def info(self) -> dict:
        last = self.last
        return {
            "id": self.llm_id,
            "name": self.name,
            "maker": self.maker,
            "license": self.license,
            "model": self.model_id,
            "status": self.status,
            "downloaded": self.loaded or self.downloaded,
            "error": self.error,
            "load_seconds": self.load_seconds,
            "idle_seconds": self.idle_seconds,
            "model_path": self.model_path,
            "model_bytes": self.model_bytes,
            "context_tokens": self.context_tokens,
            "memory_limit_bytes": self.memory_limit,
            "peak_memory_bytes": self.peak_memory_bytes,
            "requests": self.requests,
            "last_tokens_per_second": round(last.tokens_per_second, 1) if last else None,
        }

    # Loading

    def load(self) -> None:
        """Loads the weights. The caller has already freed every other model."""
        if self._model is not None:
            return
        try:
            path = self._resolve(self.model_id, False)
        except Exception as exc:
            raise LLMUnavailable(
                f"{self.name} is not downloaded yet. Download it in Navo > Settings > AI writing, or run: "
                f"python -m navo_engine.download --model {self.model_id}"
            ) from exc
        self.status, self.error = "loading", None
        started = time.perf_counter()
        mx = _mlx() if self._loader is None else None
        try:
            if mx is not None:
                # A ceiling for MLX's own allocator, and no large pool of spare buffers.
                self._previous_limit = mx.set_memory_limit(self.memory_limit)
                mx.reset_peak_memory()
            if self._loader is not None:
                self._model, self._tokenizer = self._loader(str(path))
            else:
                from mlx_lm import load

                self._model, self._tokenizer = load(str(path))
        except Exception as exc:
            log.exception("%s failed to load", self.name)
            self._model = self._tokenizer = None
            self._restore_limit()
            reason = str(exc)
            if "not supported" in reason.lower():
                # An engine installed before this model existed: its mlx-lm is too old.
                reason += ". Update the engine: Navo > Settings > Speech engines > Reinstall / update."
            self.status, self.error = "error", reason
            raise LLMUnavailable(f"{self.name} failed to load: {reason}") from exc
        self.model_path = str(path)
        try:
            self.model_bytes = dir_size(Path(path))
        except Exception:
            self.model_bytes = None
        self.status = "ready"
        self.load_seconds = round(time.perf_counter() - started, 2)
        self.last_used = time.monotonic()
        log.info("%s ready in %.1fs", self.name, self.load_seconds)

    def unload(self) -> None:
        """Frees the weights. The next request loads them again."""
        was_loaded = self._model is not None
        self._model = self._tokenizer = None
        self.load_seconds, self.last_used, self.expires_at = None, None, None
        if self.status != "error" or was_loaded:
            self.status, self.error = "asleep", None
        if was_loaded:
            gc.collect()
            mx = _mlx()
            if mx is not None:
                try:
                    mx.clear_cache()
                except Exception:
                    pass
            self._restore_limit()
            log.info("%s unloaded, memory freed", self.name)

    def _restore_limit(self) -> None:
        mx = _mlx()
        if mx is not None and self._previous_limit:
            try:
                mx.set_memory_limit(self._previous_limit)
            except Exception:
                pass
        self._previous_limit = None

    # Requests

    def prompt_ids(self, messages: list[dict]) -> list[int]:
        """The request as tokens, through the model's own chat template."""
        if self._tokenizer is None:
            raise LLMUnavailable(f"{self.name} is not loaded")
        chat = []
        for message in messages:
            role = str(message.get("role") or "user").lower()
            role = {"developer": "system"}.get(role, role)
            if role not in ("system", "user", "assistant"):
                role = "user"
            chat.append({"role": role, "content": message_text(message.get("content"))})
        # Llama's template writes today's date in the system header; Gemma's ignores it.
        extra = {"date_string": date.today().strftime("%d %b %Y")}
        try:
            text = self._tokenizer.apply_chat_template(
                chat, add_generation_prompt=True, tokenize=False, enable_thinking=False, **extra
            )
        except TypeError:
            text = self._tokenizer.apply_chat_template(chat, add_generation_prompt=True, tokenize=False)
        bos = getattr(self._tokenizer, "bos_token", None)
        add_special = bos is None or not text.startswith(bos)
        return list(self._tokenizer.encode(text, add_special_tokens=add_special))

    def output_budget(self, prompt_tokens: int, max_tokens: Optional[int]) -> int:
        """Tokens the answer may use. Raises PromptTooLong when the prompt leaves no room."""
        room = self.context_tokens - prompt_tokens
        if room < MIN_OUTPUT_TOKENS:
            raise PromptTooLong(
                f"The prompt is {prompt_tokens} tokens, and {self.name} takes at most "
                f"{self.context_tokens - MIN_OUTPUT_TOKENS} here (a context of {self.context_tokens} tokens keeps it "
                f"under {self.memory_limit / GIB:g} GB of memory). Send the text in smaller parts."
            )
        wanted = DEFAULT_MAX_TOKENS if max_tokens is None else int(max_tokens)
        return max(1, min(wanted, MAX_OUTPUT_TOKENS, room))

    def generate(
        self,
        messages: list[dict],
        temperature: float = 0.3,
        top_p: float = 0.95,
        top_k: int = 0,
        max_tokens: Optional[int] = None,
        repetition_penalty: Optional[float] = None,
        stop: Optional[list[str]] = None,
        on_text: Optional[Callable[[str], None]] = None,
        cancelled: Optional[Callable[[], bool]] = None,
    ) -> Completion:
        """Writes the answer. ``on_text`` hears each new piece; ``cancelled`` stops it early."""
        prompt = self.prompt_ids(messages)
        budget = self.output_budget(len(prompt), max_tokens)
        options = {
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k,
            "max_tokens": budget,
            "repetition_penalty": repetition_penalty,
            "cancelled": cancelled,
        }
        stops = [s for s in (stop or []) if s]
        mx = _mlx() if self._loader is None else None
        if mx is not None:
            mx.reset_peak_memory()
        self.status = "writing"
        started = time.perf_counter()
        text, sent, pieces, reason = "", 0, 0, None
        try:
            for piece, finish in self._generator(self._model, self._tokenizer, prompt, options):
                pieces += 1
                text += piece or ""
                reason = finish or reason
                cut = min((text.find(s) for s in stops if s in text), default=-1)
                if cut >= 0:
                    text, reason = text[:cut], "stop"
                # While the answer goes on, hold back an end that may be the start of a stop word.
                ready = len(text) if cut >= 0 or finish else len(text) - _held_back(text, stops)
                if on_text is not None and ready > sent:
                    on_text(text[sent:ready])
                    sent = ready
                if cut >= 0 or finish:
                    break
                if cancelled is not None and cancelled():
                    reason = "cancelled"
                    break
        except _Cancelled:
            reason = "cancelled"
        finally:
            self.status = "ready" if self._model is not None else "asleep"
            self.last_used = time.monotonic()
            peak = None
            if mx is not None:
                try:
                    peak = int(mx.get_peak_memory()) or None
                    mx.clear_cache()
                except Exception:
                    peak = None
        seconds = time.perf_counter() - started
        completion = Completion(
            text=strip_thinking(text),
            prompt_tokens=len(prompt),
            completion_tokens=pieces,
            finish_reason=reason or "stop",
            seconds=seconds,
            tokens_per_second=pieces / seconds if seconds > 0 else 0.0,
            peak_memory_bytes=peak,
        )
        self.requests += 1
        self.last = completion
        if peak:
            self.peak_memory_bytes = max(peak, self.peak_memory_bytes or 0)
        return completion
