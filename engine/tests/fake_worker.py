"""A model worker with fake models, started by the gateway tests instead of navo_engine.server."""

import argparse
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import uvicorn  # noqa: E402

from navo_engine.asr import ASRService  # noqa: E402
from navo_engine.llm import LLMService  # noqa: E402
from navo_engine.llms import LLM_PROFILES, LanguageModel  # noqa: E402
from navo_engine.options import engine_list_arg, watch_parent  # noqa: E402
from navo_engine.server import Engine, create_app  # noqa: E402

MODEL_DIR = Path(tempfile.mkdtemp(prefix="navo-fake-model-"))
(MODEL_DIR / "model.safetensors").write_bytes(b"x" * 2048)


class FakeBackend:
    name = "fake"

    def __init__(self, model_dir, text):
        self.text = text

    def transcribe(self, audio, language):
        return self.text


def service(engine_id, text):
    return ASRService(
        f"fake/{engine_id}",
        backends={"fake": lambda d: FakeBackend(d, text)},
        model_resolver=lambda m, d: MODEL_DIR,
        engine_id=engine_id,
        name=engine_id.title(),
    )


class FakeTokenizer:
    bos_token = None

    def apply_chat_template(self, chat, add_generation_prompt=True, tokenize=False, **kwargs):
        return " ".join(f"{m['role']}: {m['content']}" for m in chat)

    def encode(self, text, add_special_tokens=True):
        return list(range(len(text.split())))


def fake_words(model, tokenizer, prompt, options):
    """Writes "<name> wrote this answer", a word at a time, slowly enough to watch it stream."""
    import time

    words = f"{model} wrote this answer".split()
    for index, word in enumerate(words):
        time.sleep(0.02)
        yield ("" if index == 0 else " ") + word, ("stop" if index == len(words) - 1 else None)


def language_model(llm_id):
    return LanguageModel(
        LLM_PROFILES[llm_id],
        f"fake/{llm_id}",
        loader=lambda path: (llm_id, FakeTokenizer()),
        generator=fake_words,
        model_resolver=lambda m, d: MODEL_DIR,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uds", required=True)
    parser.add_argument("--engines", type=engine_list_arg, default=["cohere"])
    parser.add_argument("--default-engine", default="cohere")
    parser.add_argument("--preload", type=engine_list_arg, default=[])
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--llm-keep-alive", type=float, default=60.0)
    args, _ = parser.parse_known_args()
    if args.parent_pid:
        watch_parent(args.parent_pid)
    engine = Engine(
        {"cohere": service("cohere", "cohere text"), "audar": service("audar", "audar text")},
        LLMService("fake/llm"),
        default_engine=args.default_engine,
        enabled=args.engines,
        llms={llm_id: language_model(llm_id) for llm_id in LLM_PROFILES},
        keep_alive=args.llm_keep_alive,
    )
    engine.start_loading([e for e in args.preload if e in args.engines], preload_llm=False)
    uvicorn.run(create_app(engine), uds=args.uds, log_level="warning")


if __name__ == "__main__":
    main()
