"""Command line options and helpers shared by the gateway and the model worker.

Kept free of heavy imports: the gateway must stay small in memory.
"""

from __future__ import annotations

import argparse
import logging
import os
import threading
import time

from . import DEFAULT_LLM_MODEL
from .engines import MAX_ENABLED_ENGINES, PROFILES
from .llms import DEFAULT_CONTEXT_TOKENS, DEFAULT_KEEP_ALIVE, LLM_PROFILES

log = logging.getLogger("navo.engine")


def engine_list_arg(value: str) -> list[str]:
    names = [n.strip().lower() for n in (value or "").split(",") if n.strip() and n.strip().lower() != "none"]
    unknown = [name for name in names if name not in PROFILES]
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown engine(s): {', '.join(unknown)}. Use: {', '.join(PROFILES)}")
    return names


def add_model_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--engines",
        type=engine_list_arg,
        default=["cohere"],
        help=(
            f"Speech engines that are on, comma separated, at most {MAX_ENABLED_ENGINES}: "
            f"{', '.join(PROFILES)}. The others are off."
        ),
    )
    parser.add_argument("--default-engine", default=None, help="Engine for requests that do not name one")
    parser.add_argument("--asr-model", "--cohere-model", dest="asr_model", default=None, help="Cohere model id or folder")
    parser.add_argument("--audar-model", default=None, help="Audar model id or folder")
    parser.add_argument("--whisper-model", default=None, help="Whisper model id or folder")
    parser.add_argument("--qwen3-model", default=None, help="Qwen3-ASR model id or folder")
    parser.add_argument("--llm-model", default=DEFAULT_LLM_MODEL, help="The small cleanup model")
    parser.add_argument("--gemma-model", default=None, help="Gemma model id or folder (language model)")
    parser.add_argument("--llama-model", default=None, help="Llama model id or folder (language model)")
    parser.add_argument(
        "--llm-context",
        type=int,
        default=DEFAULT_CONTEXT_TOKENS,
        help="Most tokens a language model request may use, prompt plus answer. It bounds the memory of a request",
    )
    parser.add_argument(
        "--llm-keep-alive",
        type=float,
        default=DEFAULT_KEEP_ALIVE,
        help="Seconds a language model stays in memory after its last answer (0: leave at once)",
    )
    parser.add_argument("--backend", choices=["auto", "mlx", "transformers"], default="auto", help="Cohere backend")
    parser.add_argument("--allow-download", action="store_true", help="Download a model if it is missing")
    parser.add_argument("--no-preload-llm", action="store_true", help="Load the cleanup LLM on first use")
    parser.add_argument("--parent-pid", type=int, default=0)


# The option that sets each engine's model.
MODEL_OPTIONS = {"cohere": "asr_model", "audar": "audar_model", "whisper": "whisper_model", "qwen3": "qwen3_model"}


def model_overrides(args: argparse.Namespace) -> dict[str, str]:
    """Each engine's model: the one given on the command line, else its default."""
    return {
        engine_id: getattr(args, MODEL_OPTIONS.get(engine_id, ""), None) or profile.model_id
        for engine_id, profile in PROFILES.items()
    }


def llm_overrides(args: argparse.Namespace) -> dict[str, str]:
    """Each language model's weights: the ones given on the command line, else its default."""
    return {
        llm_id: getattr(args, f"{llm_id}_model", None) or profile.model_id
        for llm_id, profile in LLM_PROFILES.items()
    }


def check_engine_limit(parser: argparse.ArgumentParser, engines: list[str]) -> None:
    if len(set(engines)) > MAX_ENABLED_ENGINES:
        parser.error(
            f"--engines lists {len(set(engines))} engines, but at most {MAX_ENABLED_ENGINES} can be on at once"
        )


def watch_parent(parent_pid: int) -> None:
    """Exit when the process that launched us goes away, so no orphan keeps the port or the memory."""

    def loop() -> None:
        while True:
            time.sleep(2)
            try:
                os.kill(parent_pid, 0)
            except ProcessLookupError:
                log.info("Parent process %d exited; shutting down", parent_pid)
                os._exit(0)
            except PermissionError:
                pass

    threading.Thread(target=loop, name="navo-parent-watch", daemon=True).start()
