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
import json
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
# A model's own context length below this is taken for a mistake in its config and ignored.
MIN_MODEL_CONTEXT = 512
# Where a model's config.json keeps the longest context it was made for.
CONTEXT_KEYS = ("max_position_embeddings", "max_sequence_length", "max_seq_len", "seq_length", "n_positions", "n_ctx")


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


def trained_context(model: Any, path: Optional[str]) -> tuple[Optional[int], Optional[str]]:
    """The longest context the model was made for (its own limit, before Navo's), or None and why.

    llama.cpp knows it (``n_ctx_train``); an MLX model has it in its config.json, at the top or
    under ``text_config`` for models that also see images. Never raises: an unknown length is a
    figure missing from the measurements, not a failed answer.
    """
    try:
        # llama.cpp: the Llama object, or its inner model, knows it; the GGUF metadata says it too.
        for owner in (model, getattr(model, "_model", None)):
            n_ctx_train = getattr(owner, "n_ctx_train", None)
            if callable(n_ctx_train):
                value = int(n_ctx_train())
                if value > 0:
                    return value, None
        metadata = getattr(model, "metadata", None)
        if isinstance(metadata, dict):
            for key, value in metadata.items():
                if str(key).endswith(".context_length") and str(value).isdigit() and int(value) > 0:
                    return int(value), None
        if not path:
            return None, "the model has no folder to read its context length from"
        folder = Path(path)
        config = folder / "config.json" if folder.is_dir() else folder.parent / "config.json"
        if not config.is_file():
            return None, f"no config.json in {config.parent}, so its context length is unknown"
        data = json.loads(config.read_text(encoding="utf-8"))
        sections = [data] + [data.get(key) for key in ("text_config", "llm_config", "language_config")]
        for section in sections:
            if not isinstance(section, dict):
                continue
            for key in CONTEXT_KEYS:
                value = section.get(key)
                if isinstance(value, int) and not isinstance(value, bool) and value > 0:
                    return value, None
        return None, f"{config.name} does not say its context length ({', '.join(CONTEXT_KEYS[:3])}…)"
    except Exception as exc:  # a broken config.json, an odd llama.cpp build
        return None, f"could not read its context length: {exc}"


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
    # Seconds until the first piece of the answer: mostly reading the prompt.
    first_token_seconds: Optional[float] = None
    # The context of this request (prompt plus answer, Navo's limit or the model's if smaller),
    # the longest one the model was made for, and the room the answer had.
    context_tokens: Optional[int] = None
    model_context_tokens: Optional[int] = None
    max_output_tokens: Optional[int] = None
    # Sizes in characters: every message, the answer, and the user's text alone with its tokens
    # (characters a token: how well the tokenizer knows the language).
    input_chars: Optional[int] = None
    output_chars: Optional[int] = None
    text_chars: Optional[int] = None
    text_tokens: Optional[int] = None
    # Figures that could not be measured, and why (the app keeps them in its problems log).
    problems: list[str] = field(default_factory=list)

    def usage(self) -> dict:
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.prompt_tokens + self.completion_tokens,
        }

    def stats(self) -> dict:
        """The figures of this answer. Never raises: what cannot be measured is left out and said in ``problems``."""
        try:
            first = self.first_token_seconds
            writing = self.seconds - first if first is not None else None
            stats = {
                "seconds": round(self.seconds, 2),
                "tokens_per_second": round(self.tokens_per_second, 1),
                "peak_memory_bytes": self.peak_memory_bytes,
                # Time to the first token, then the writing speed after it, and the reading speed of the prompt.
                "first_token_ms": int(first * 1000) if first is not None else None,
                "decode_tokens_per_second": (
                    round((self.completion_tokens - 1) / writing, 1)
                    if writing and writing > 0 and self.completion_tokens > 1
                    else None
                ),
                "prompt_tokens_per_second": round(self.prompt_tokens / first, 1) if first else None,
                "context_tokens": self.context_tokens,
                "model_context_tokens": self.model_context_tokens,
                "max_output_tokens": self.max_output_tokens,
                "input_chars": self.input_chars,
                "output_chars": self.output_chars,
                "text_chars": self.text_chars,
                "text_tokens": self.text_tokens,
            }
        except Exception as exc:
            log.exception("Could not measure an answer")
            return {"problems": [*self.problems, f"could not measure the answer: {exc}"]}
        if self.problems:
            stats["problems"] = list(self.problems)
        return stats


# (model, tokenizer, prompt ids, options) -> pieces of text, each with the finish reason
# (None until the last piece). A piece is usually one token; a generator whose pieces can hold
# several (llama.cpp joins the tokens of one Arabic letter) puts the true count in
# options["tally"]["tokens"] when it ends.
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

    between = options.get("between")

    def reading(done: int, total: int) -> None:
        # Reading a long prompt takes a while: stop here too when the client has left, and let
        # transcriptions waiting beside it run.
        if cancelled is not None and cancelled():
            raise _Cancelled()
        if between is not None:
            between()

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
        custom: bool = False,
    ):
        self.llm_id = profile.id
        # Added from a folder on this Mac (LM Studio, for example), not downloaded by Navo.
        self.custom = custom
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
        # Memory on top of the limit while speech models stay loaded beside this one (set by the engine).
        self.memory_extra = 0
        self.status = "asleep"
        self.error: Optional[str] = None
        self.load_seconds: Optional[float] = None
        self.last_used: Optional[float] = None
        self.expires_at: Optional[float] = None  # monotonic time it leaves memory, None: stays
        self.model_path: Optional[str] = None
        self.model_bytes: Optional[int] = None
        # The longest context the model was made for, known once it loaded (None: unknown, and why).
        self.model_context: Optional[int] = None
        self.context_problem: Optional[str] = None
        self.requests = 0
        self.last: Optional[Completion] = None
        self.peak_memory_bytes: Optional[int] = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    @property
    def window(self) -> int:
        """Tokens one request may use, prompt plus answer: Navo's limit, or the model's own when it is smaller."""
        if self.model_context and self.model_context >= MIN_MODEL_CONTEXT:
            return min(self.context_tokens, self.model_context)
        return self.context_tokens

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
            "model_context_tokens": self.model_context,
            "window_tokens": self.window,
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
            if self.custom:
                raise LLMUnavailable(
                    f"{self.name} is not at {self.model_id} any more. Was it moved or deleted? "
                    "Remove it in Navo > Settings > Cleanup and AI and add it again."
                ) from exc
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
                self._previous_limit = mx.set_memory_limit(self.memory_limit + max(0, int(self.memory_extra)))
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
            self.model_bytes = dir_size(Path(path)) if Path(path).is_dir() else Path(path).stat().st_size
        except Exception:
            self.model_bytes = None
        self.model_context, self.context_problem = trained_context(self._model, str(path))
        if self.context_problem:
            log.warning("%s: %s", self.name, self.context_problem)
        elif self.model_context and self.model_context < self.context_tokens:
            log.info("%s was made for %d tokens: requests stay within that", self.name, self.model_context)
        self.status = "ready"
        self.load_seconds = round(time.perf_counter() - started, 2)
        self.last_used = time.monotonic()
        log.info("%s ready in %.1fs", self.name, self.load_seconds)

    def unload(self) -> None:
        """Frees the weights. The next request loads them again."""
        was_loaded = self._model is not None
        close = getattr(self._model, "close", None)  # llama.cpp frees its memory here
        if callable(close):
            try:
                close()
            except Exception:
                pass
        self._model = self._tokenizer = None
        self.load_seconds, self.last_used, self.expires_at = None, None, None
        self.model_context, self.context_problem = None, None
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

    def count_tokens(self, text: str) -> Optional[int]:
        """Tokens of a text alone, without the chat template around it."""
        if not text or self._tokenizer is None:
            return None
        try:
            return len(self._tokenizer.encode(text, add_special_tokens=False))
        except TypeError:
            return len(self._tokenizer.encode(text))

    def output_budget(self, prompt_tokens: int, max_tokens: Optional[int]) -> int:
        """Tokens the answer may use. Raises PromptTooLong when the prompt leaves no room."""
        window = self.window
        room = window - prompt_tokens
        if room < MIN_OUTPUT_TOKENS:
            why = (
                f"the most {self.name} was made for"
                if window < self.context_tokens
                else f"which keeps it under {self.memory_limit / GIB:g} GB of memory"
            )
            raise PromptTooLong(
                f"The prompt is {prompt_tokens} tokens, and {self.name} takes at most "
                f"{window - MIN_OUTPUT_TOKENS} here (a context of {window} tokens, {why}). Send the text in smaller parts."
            )
        wanted = DEFAULT_MAX_TOKENS if max_tokens is None else int(max_tokens)
        return max(1, min(wanted, MAX_OUTPUT_TOKENS, room))

    def _sizes(self, messages: list[dict]) -> dict:
        """The request's size in characters, and the user's text in tokens. Never raises."""
        sizes: dict = {"problems": []}
        try:
            sizes["input_chars"] = sum(len(message_text(m.get("content"))) for m in messages)
            users = [m for m in messages if str(m.get("role") or "user").lower() == "user"]
            text = message_text(users[-1].get("content")) if users else ""
            if text:
                sizes["text_chars"] = len(text)
                sizes["text_tokens"] = self.count_tokens(text)
        except Exception as exc:
            log.warning("%s: could not count the request's tokens: %s", self.name, exc)
            sizes["problems"].append(f"{self.name}: could not count the text's tokens: {exc}")
        return sizes

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
        between: Optional[Callable[[], None]] = None,
    ) -> Completion:
        """Writes the answer. ``on_text`` hears each new piece; ``cancelled`` stops it early;
        ``between`` runs after each piece (the engine's transcriptions waiting beside it)."""
        prompt = self.prompt_ids(messages)
        budget = self.output_budget(len(prompt), max_tokens)
        sizes = self._sizes(messages)
        options = {
            "temperature": temperature,
            "top_p": top_p,
            "top_k": top_k,
            "max_tokens": budget,
            "repetition_penalty": repetition_penalty,
            "cancelled": cancelled,
            "between": between,
            "tally": {},
        }
        stops = [s for s in (stop or []) if s]
        mx = _mlx() if self._loader is None else None
        if mx is not None:
            mx.reset_peak_memory()
        self.status = "writing"
        started = time.perf_counter()
        text, sent, pieces, reason = "", 0, 0, None
        first: Optional[float] = None
        stream = self._generator(self._model, self._tokenizer, prompt, options)
        try:
            for piece, finish in stream:
                pieces += 1
                if first is None:
                    first = time.perf_counter() - started
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
                if between is not None:
                    between()
        except _Cancelled:
            reason = "cancelled"
        finally:
            close = getattr(stream, "close", None)
            if callable(close):
                try:
                    close()  # lets the generator count its tokens now
                except Exception:
                    pass
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
        counted = options["tally"].get("tokens")
        tokens = counted if isinstance(counted, int) and counted >= 0 else pieces
        completion = Completion(
            text=strip_thinking(text),
            prompt_tokens=len(prompt),
            completion_tokens=tokens,
            finish_reason=reason or "stop",
            seconds=seconds,
            tokens_per_second=tokens / seconds if seconds > 0 else 0.0,
            peak_memory_bytes=peak,
            first_token_seconds=first,
            context_tokens=self.window,
            model_context_tokens=self.model_context,
            max_output_tokens=budget,
            **sizes,
        )
        completion.output_chars = len(completion.text)
        if self.context_problem:
            completion.problems.append(f"{self.name}: {self.context_problem}")
        self.requests += 1
        self.last = completion
        if peak:
            self.peak_memory_bytes = max(peak, self.peak_memory_bytes or 0)
        return completion
