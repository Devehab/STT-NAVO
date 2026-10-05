"""The small local language model (MLX) that tidies a dictation's transcript.

The larger models that summarize and rewrite (Gemma, Llama) are in llms.py.
"""

from __future__ import annotations

import gc
import logging
import re
import time
from typing import Any, Callable, Optional

from pathlib import Path

from .models import dir_size, resolve_model_dir

log = logging.getLogger("navo.llm")

_THINK = re.compile(r"<think>.*?</think>|<\|channel>thought.*?<channel\|>", re.DOTALL)
PLACEHOLDER_MODELS = {"", "local", "navo", "default"}


class LLMUnavailable(RuntimeError):
    pass


def message_text(content: Any) -> str:
    """OpenAI messages may carry a string or a list of content parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


def strip_thinking(text: str) -> str:
    text = _THINK.sub("", text)
    if "</think>" in text:  # template opened <think> in the prompt
        text = text.split("</think>", 1)[1]
    return text.strip()


class LLMService:
    def __init__(self, default_model: str, loader: Optional[Callable[[str], Any]] = None):
        self.default_model = default_model
        self._loader = loader
        self.model_id: Optional[str] = None
        self._model = None
        self._tokenizer = None
        self.error: Optional[str] = None
        self._disk: Optional[tuple[str, int]] = None
        self.last_used: Optional[float] = None

    @property
    def idle_seconds(self) -> Optional[float]:
        if self._model is None or self.last_used is None:
            return None
        return round(time.monotonic() - self.last_used, 1)

    def unload(self) -> None:
        """Frees the cleanup model. The next chat request loads it again."""
        if self._model is None:
            return
        self._model = self._tokenizer = None
        self.model_id, self.last_used = None, None
        gc.collect()
        try:
            import mlx.core as mx

            mx.clear_cache()
        except Exception:
            pass
        log.info("LLM unloaded, memory freed")

    def _disk_info(self) -> Optional[tuple[str, int]]:
        if self._disk is None:
            try:
                path = resolve_model_dir(self.default_model, allow_download=False)
                self._disk = (str(path), dir_size(Path(path)))
            except Exception:
                return None
        return self._disk

    def info(self) -> dict:
        disk = self._disk_info()
        return {
            "default_model": self.default_model,
            "loaded_model": self.model_id,
            "available": disk is not None,
            "path": disk[0] if disk else None,
            "size_bytes": disk[1] if disk else None,
            "idle_seconds": self.idle_seconds,
            "error": self.error,
        }

    def preload(self) -> None:
        """Load the default model at startup if it is downloaded, so the first cleanup is fast."""
        try:
            if self._disk_info() is not None:
                self._ensure(self.default_model)
        except Exception as exc:  # reported through /health, never fatal
            log.exception("LLM preload failed")
            self.error = str(exc)

    def _ensure(self, model_id: str) -> None:
        if self.model_id == model_id and self._model is not None:
            return
        try:
            path = resolve_model_dir(model_id, allow_download=False)
        except Exception as exc:
            raise LLMUnavailable(str(exc)) from exc
        if self._loader is not None:
            self._model, self._tokenizer = self._loader(str(path))
        else:
            from mlx_lm import load

            self._model, self._tokenizer = load(str(path))
        self.model_id, self.error = model_id, None
        self.last_used = time.monotonic()
        log.info("LLM ready: %s", model_id)

    def chat(self, messages: list[dict], model: Optional[str] = None, temperature: float = 0.2, max_tokens: int = 1024) -> str:
        model_id = self.default_model if (model or "").strip().lower() in PLACEHOLDER_MODELS else model.strip()
        self._ensure(model_id)

        chat = [{"role": m.get("role", "user"), "content": message_text(m.get("content"))} for m in messages]
        try:
            prompt = self._tokenizer.apply_chat_template(
                chat, add_generation_prompt=True, tokenize=False, enable_thinking=False
            )
        except TypeError:
            prompt = self._tokenizer.apply_chat_template(chat, add_generation_prompt=True, tokenize=False)

        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler
        import mlx.core as mx

        try:
            text = generate(
                self._model,
                self._tokenizer,
                prompt=prompt,
                max_tokens=max(16, min(int(max_tokens), 4096)),
                sampler=make_sampler(temp=max(0.0, float(temperature))),
                verbose=False,
            )
        finally:
            self.last_used = time.monotonic()
            mx.clear_cache()
        return strip_thinking(text)
