"""Language models you already have on this Mac, used from their own folder (nothing is copied).

Navo can use a model that another app downloaded, for example LM Studio
(~/.lmstudio/models/<publisher>/<model>), for summaries and rewrites:

* **MLX** folders (config.json and *.safetensors) run on mlx-lm, like Gemma and Llama.
* **GGUF** files run on llama.cpp with Metal (the llama-cpp-python package, a ready-made
  build that Navo adds to its engine the first time, see add-gguf.sh).

The app passes the list with ``--custom-llms '[{"id": "custom-…", "name": …, "path": …,
"format": "mlx" | "gguf"}]'``. Each one becomes a language model like Gemma, with its own API
at /<id>/v1/chat/completions. This module stays light: llama.cpp is imported only to load a model.
"""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator, Optional

from .llms import LLM_PROFILES, MEMORY_LIMIT_BYTES, LLMProfile
from .models import cached_snapshot, dir_size, is_complete

log = logging.getLogger("navo.custom")

GIB = 1024**3
FORMATS = ("mlx", "gguf")


@dataclass(frozen=True)
class CustomModel:
    id: str
    name: str
    path: str
    format: str  # "mlx" or "gguf"


# The models of this process, by id.
CUSTOM: dict[str, CustomModel] = {}


def parse(value: Optional[str]) -> list[CustomModel]:
    """The --custom-llms JSON. Entries that are not usable are skipped with a warning."""
    if not value:
        return []
    try:
        items = json.loads(value)
    except ValueError as exc:
        log.warning("Ignoring --custom-llms: %s", exc)
        return []
    models = []
    for item in items if isinstance(items, list) else []:
        try:
            model = CustomModel(
                id=str(item["id"]).strip().lower(),
                name=str(item.get("name") or item["id"]).strip(),
                path=os.path.expanduser(str(item["path"]).strip()),
                format=str(item.get("format") or "mlx").strip().lower(),
            )
        except (KeyError, TypeError, AttributeError):
            log.warning("Ignoring a custom model without an id and a path: %r", item)
            continue
        if not model.id.startswith("custom-") or model.format not in FORMATS:
            log.warning("Ignoring custom model %r: the id must start with custom- and the format be mlx or gguf", item)
            continue
        models.append(model)
    return models


def register(models: list[CustomModel]) -> None:
    """Makes each model a language model of this process, next to Gemma and Llama."""
    for model in models:
        CUSTOM[model.id] = model
        LLM_PROFILES[model.id] = LLMProfile(
            id=model.id,
            name=model.name,
            model_id=model.path,
            maker="Added from a folder",
            license="Its own license",
        )


def main_gguf(path: str | Path) -> Optional[Path]:
    """The model file of a GGUF folder: the largest .gguf that is not a vision projector (mmproj)."""
    path = Path(path).expanduser()
    if path.is_file():
        return path if path.suffix.lower() == ".gguf" else None
    if not path.is_dir():
        return None
    files = [p for p in path.glob("*.gguf") if p.is_file() and not p.name.lower().startswith("mmproj")]
    if not files:
        return None
    return max(files, key=lambda p: p.stat().st_size)


def is_available(llm_id: str, model: str) -> bool:
    """The model's files are on this Mac (a custom model's folder, or a download in the cache)."""
    custom = CUSTOM.get(llm_id)
    if custom is None:
        return cached_snapshot(model) is not None
    if custom.format == "gguf":
        return main_gguf(custom.path) is not None
    folder = Path(custom.path)
    return folder.is_dir() and is_complete(folder)


def model_bytes(path: str | Path) -> int:
    path = Path(path).expanduser()
    if path.is_file():
        return path.stat().st_size
    return dir_size(path)


def total_memory() -> int:
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (ValueError, OSError, AttributeError):
        return 16 * GIB


def memory_limit_for(path: str | Path) -> int:
    """Room for an MLX model: its weights plus a working margin, never less than the built-in
    models get, and never more than most of the Mac's memory."""
    try:
        weights = model_bytes(path)
    except OSError:
        weights = 0
    wanted = max(MEMORY_LIMIT_BYTES, int(weights * 1.15) + GIB)
    return min(wanted, int(total_memory() * 0.85))


# GGUF on llama.cpp


def gguf_runtime_version() -> Optional[str]:
    from . import package_version

    return package_version("llama-cpp-python")


class GGUFTokenizer:
    """What LanguageModel needs from a tokenizer, on top of a llama.cpp model: the chat template
    stored in the GGUF file, and its tokens."""

    def __init__(self, llm: Any):
        self.llm = llm
        meta = getattr(llm, "metadata", None) or {}
        self.template = meta.get("tokenizer.chat_template")
        self.bos_token = self._token_text(llm.token_bos()) if llm.token_bos() >= 0 else None
        self.eos_token = self._token_text(llm.token_eos()) if llm.token_eos() >= 0 else ""

    def _token_text(self, token: int) -> str:
        try:
            return self.llm.detokenize([token], special=True).decode("utf-8", errors="ignore")
        except TypeError:  # older llama-cpp-python without special=
            return self.llm.detokenize([token]).decode("utf-8", errors="ignore")

    def apply_chat_template(self, chat: list[dict], add_generation_prompt: bool = True, tokenize: bool = False, **extra) -> str:
        if not self.template:
            # No template in the file: the common ChatML layout.
            text = "".join(f"<|im_start|>{m['role']}\n{m['content']}<|im_end|>\n" for m in chat)
            return text + ("<|im_start|>assistant\n" if add_generation_prompt else "")
        from jinja2.ext import loopcontrols
        from jinja2.sandbox import ImmutableSandboxedEnvironment

        def raise_exception(message: str) -> None:
            raise ValueError(message)

        environment = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=[loopcontrols])
        return environment.from_string(self.template).render(
            messages=chat,
            bos_token=self.bos_token or "",
            eos_token=self.eos_token or "",
            add_generation_prompt=add_generation_prompt,
            raise_exception=raise_exception,
            strftime_now=lambda fmt: datetime.now().strftime(fmt),
            **extra,
        )

    def encode(self, text: str, add_special_tokens: bool = True) -> list[int]:
        return list(self.llm.tokenize(text.encode("utf-8"), add_bos=add_special_tokens, special=True))


def gguf_loader(context_tokens: int):
    """Loads a GGUF file with llama.cpp, every layer on the Mac's GPU (Metal)."""

    def load(path: str) -> tuple[Any, Any]:
        try:
            from llama_cpp import Llama
        except ImportError as exc:
            raise RuntimeError(
                "GGUF models need llama.cpp in Navo's engine. Add it in Navo > Settings > Cleanup and AI > Add a model"
            ) from exc
        file = main_gguf(path)
        if file is None:
            raise RuntimeError(f"No .gguf model file in {path}")
        log.info("Loading %s with llama.cpp", file)
        llm = Llama(model_path=str(file), n_ctx=int(context_tokens), n_gpu_layers=-1, verbose=False)
        return llm, GGUFTokenizer(llm)

    return load


def gguf_generate(model: Any, tokenizer: Any, prompt: list[int], options: dict) -> Iterator[tuple[str, Optional[str]]]:
    """Text from llama.cpp, piece by piece (the same contract as llms.mlx_generate)."""
    temperature = max(0.0, float(options.get("temperature", 0.0)))
    penalty = options.get("repetition_penalty")
    stream = model.create_completion(
        prompt=prompt,
        max_tokens=int(options["max_tokens"]),
        temperature=temperature,
        top_p=float(options.get("top_p") or 1.0) if temperature > 0 else 1.0,
        top_k=int(options.get("top_k") or 0) if temperature > 0 else 1,
        repeat_penalty=float(penalty) if penalty else 1.0,
        stream=True,
    )
    tally = options.get("tally")
    reason = None
    try:
        for chunk in stream:
            choice = (chunk.get("choices") or [{}])[0]
            reason = choice.get("finish_reason") or reason
            yield choice.get("text") or "", choice.get("finish_reason")
    finally:
        # A piece can hold several tokens, and the last one is empty: count from llama.cpp's own
        # position instead. The last token is evaluated only when more were to come, so add it
        # back when the answer stopped at its length limit.
        if isinstance(tally, dict):
            try:
                written = int(model.n_tokens) - len(prompt) + (1 if reason == "length" else 0)
                if written >= 0:
                    tally["tokens"] = written
            except Exception:
                pass
