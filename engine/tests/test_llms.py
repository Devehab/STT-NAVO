"""The language models (Gemma, Llama) with fake weights: the memory rules and the chat API.

    cd engine && python -m pytest -q tests/test_llms.py
"""

import io
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from navo_engine.asr import ASRService  # noqa: E402
from navo_engine.llm import LLMService, LLMUnavailable, strip_thinking  # noqa: E402
from navo_engine.llms import LLM_PROFILES, MEMORY_LIMIT_BYTES, LanguageModel, PromptTooLong, lookup_llm  # noqa: E402
from navo_engine.server import Engine, create_app  # noqa: E402

from fake_worker import FakeTokenizer, fake_words  # noqa: E402
from test_server import FakeBackend, _MODEL_DIR, wav_bytes  # noqa: E402


def missing(model_id, allow_download):
    raise RuntimeError("not downloaded")


def make_llm(llm_id="gemma", resolver=lambda m, d: _MODEL_DIR, generator=fake_words, context=6144):
    return LanguageModel(
        LLM_PROFILES[llm_id], f"fake/{llm_id}", context_tokens=context,
        loader=lambda path: (llm_id, FakeTokenizer()), generator=generator, model_resolver=resolver,
    )


def make_engine(keep_alive=60.0, **llm_options):
    resolver = lambda m, d: _MODEL_DIR  # noqa: E731
    speech = {
        engine_id: ASRService(f"fake/{engine_id}", backends={"fake": FakeBackend}, model_resolver=resolver, engine_id=engine_id)
        for engine_id in ("cohere", "whisper")
    }
    cleanup = LLMService("fake/cleanup", loader=lambda path: ("cleanup", FakeTokenizer()))
    llms = {llm_id: make_llm(llm_id, **llm_options) for llm_id in LLM_PROFILES}
    engine = Engine(speech, cleanup, default_engine="cohere", enabled=["cohere", "whisper"], llms=llms, keep_alive=keep_alive)
    return TestClient(create_app(engine)), engine


def chat(client, path="/gemma/v1/chat/completions", **body):
    body.setdefault("messages", [{"role": "system", "content": "Summarize."}, {"role": "user", "content": "A long talk."}])
    return client.post(path, json=body)


def transcribe(client, engine_id="cohere"):
    return client.post(f"/{engine_id}/v1/audio/transcriptions", files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")})


def settle(engine):
    engine.worker.submit(lambda: None).result()


def loaded(engine):
    """Everything in memory right now."""
    names = [engine_id for engine_id, service in engine.engines.items() if service.backend is not None]
    names += [llm_id for llm_id, model in engine.llms.items() if model.loaded]
    if engine.llm._model is not None:
        names.append("cleanup")
    return sorted(names)


def test_two_language_models_and_their_names():
    assert list(LLM_PROFILES) == ["gemma", "llama"]
    assert lookup_llm("gemma") == "gemma" and lookup_llm("Gemma-4-E4B-it") == "gemma"
    assert lookup_llm("mlx-community/gemma-4-e4b-it-4bit") == "gemma"
    assert lookup_llm("llama") == "llama" and lookup_llm("llama-3.1-8b") == "llama"
    assert lookup_llm("mlx-community/Meta-Llama-3.1-8B-Instruct-4bit") == "llama"
    assert lookup_llm("my/gemma", {"gemma": "my/gemma"}) == "gemma"
    for other in ("local", "gpt-4o", "qwen3", None, ""):
        assert lookup_llm(other) is None
    assert MEMORY_LIMIT_BYTES == 6 * 1024**3


def test_a_model_loads_writes_and_leaves():
    model = make_llm()
    assert model.status == "asleep" and model.info()["downloaded"] is True
    model.load()
    assert model.status == "ready" and model.loaded
    heard = []
    done = model.generate([{"role": "user", "content": "hello there"}], on_text=heard.append)
    assert done.text == "gemma wrote this answer" and "".join(heard) == done.text
    assert done.finish_reason == "stop" and done.completion_tokens == 4 and done.prompt_tokens == 3
    assert model.status == "ready" and model.requests == 1
    model.unload()
    assert model.status == "asleep" and not model.loaded and model.idle_seconds is None


def test_stop_words_cancel_and_length():
    model = make_llm()
    model.load()
    assert model.generate([{"role": "user", "content": "x"}], stop=[" this"]).text == "gemma wrote"
    stopped = model.generate([{"role": "user", "content": "x"}], cancelled=lambda: True)
    assert stopped.finish_reason == "cancelled" and stopped.text == "gemma"

    def endless(m, tokenizer, prompt, options):
        for index in range(options["max_tokens"]):
            yield "la ", ("length" if index == options["max_tokens"] - 1 else None)

    model = make_llm(generator=endless)
    model.load()
    done = model.generate([{"role": "user", "content": "x"}], max_tokens=7)
    assert done.finish_reason == "length" and done.completion_tokens == 7
    # Never more than the cap, whatever the request asks for.
    assert model.generate([{"role": "user", "content": "x"}], max_tokens=100_000).completion_tokens == 2048


def test_a_prompt_that_does_not_fit_is_refused():
    model = make_llm(context=1024)
    model.load()
    assert model.output_budget(100, None) == 924
    assert model.output_budget(100, 50) == 50
    with pytest.raises(PromptTooLong) as error:
        model.generate([{"role": "user", "content": "word " * 1000}])
    assert "1001 tokens" in str(error.value) and "smaller parts" in str(error.value)


def test_a_model_that_is_not_downloaded_says_so():
    model = make_llm(resolver=missing)
    assert model.info()["downloaded"] is False
    with pytest.raises(LLMUnavailable) as error:
        model.load()
    assert "not downloaded" in str(error.value) and model.status == "asleep"


def test_thinking_is_removed_from_answers():
    assert strip_thinking("<think>hmm</think>Yes.") == "Yes."
    assert strip_thinking("<|channel>thought\nhmm\n<channel|>Yes.") == "Yes."


def test_speech_models_and_language_models_are_never_loaded_together(monkeypatch):
    import navo_engine.llm as llm_module

    monkeypatch.setattr(llm_module, "resolve_model_dir", lambda m, allow_download=False: _MODEL_DIR)
    client, engine = make_engine()
    assert transcribe(client).status_code == 200 and transcribe(client, "whisper").status_code == 200
    engine.worker.submit(engine._preload_cleanup).result()
    assert loaded(engine) == ["cleanup", "cohere", "whisper"]

    r = chat(client)
    assert r.status_code == 200, r.text
    assert loaded(engine) == ["gemma"]  # the speech engines and the cleanup model left first
    states = {e["id"]: e["status"] for e in client.get("/v1/engines").json()["engines"]}
    assert states == {"cohere": "asleep", "whisper": "asleep"}

    assert chat(client, "/llama/v1/chat/completions").status_code == 200
    assert loaded(engine) == ["llama"]  # one language model at a time too

    # A transcription sends the language model away and loads its engine again, with no error.
    r = transcribe(client, "whisper")
    assert r.status_code == 200 and r.json()["text"]
    assert loaded(engine) == ["whisper"]
    assert client.get("/llama/health").json()["status"] == "asleep"

    # The small cleanup model is on the speech side: loading it sends the language model away.
    assert chat(client).status_code == 200 and loaded(engine) == ["gemma"]
    engine.worker.submit(engine._preload_cleanup).result()
    assert loaded(engine) == ["cleanup"]


def test_requests_in_any_order_never_overlap():
    client, engine = make_engine()
    seen = []
    original = engine.llms["gemma"]._generator

    def watching(model, tokenizer, prompt, options):
        seen.append(loaded(engine))
        yield from original(model, tokenizer, prompt, options)

    engine.llms["gemma"]._generator = watching
    for _ in range(3):
        assert transcribe(client).status_code == 200
        assert chat(client).status_code == 200
    assert seen == [["gemma"]] * 3


def test_chat_response_has_the_openai_shape_and_usage():
    client, engine = make_engine()
    body = chat(client, temperature=0.2, max_tokens=200).json()
    assert body["object"] == "chat.completion" and body["id"].startswith("chatcmpl-navo-")
    assert body["model"] == "fake/gemma"
    choice = body["choices"][0]
    assert choice["message"] == {"role": "assistant", "content": "gemma wrote this answer"}
    assert choice["finish_reason"] == "stop"
    assert body["usage"] == {"prompt_tokens": 6, "completion_tokens": 4, "total_tokens": 10}
    assert body["navo"]["llm"] == "gemma" and body["navo"]["seconds"] >= 0
    # The model field picks the language model on the shared URL, by id, alias or Hugging Face id.
    for name in ("llama", "llama-3.1-8b", "fake/llama"):
        r = chat(client, "/v1/chat/completions", model=name)
        assert r.status_code == 200 and r.json()["choices"][0]["message"]["content"].startswith("llama")
    assert chat(client, "/nope/v1/chat/completions").status_code == 404
    assert client.post("/gemma/v1/chat/completions", json={"messages": []}).status_code == 400


def test_streaming_sends_the_answer_piece_by_piece():
    client, engine = make_engine()
    with client.stream("POST", "/gemma/v1/chat/completions", json={
        "messages": [{"role": "user", "content": "hi"}], "stream": True,
    }) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        lines = [line for line in response.iter_lines() if line]
    assert lines[-1] == "data: [DONE]"
    chunks = [json.loads(line[len("data: "):]) for line in lines[:-1]]
    assert all(c["object"] == "chat.completion.chunk" for c in chunks)
    assert chunks[0]["choices"][0]["delta"] == {"role": "assistant", "content": ""}
    text = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
    assert text == "gemma wrote this answer"
    assert chunks[-1]["choices"][0]["finish_reason"] == "stop"
    assert chunks[-1]["usage"]["completion_tokens"] == 4 and chunks[-1]["navo"]["llm"] == "gemma"
    assert sum(1 for c in chunks if c["choices"][0]["delta"].get("content")) == 4  # one event per piece


def test_keep_alive_decides_when_the_model_leaves():
    client, engine = make_engine(keep_alive=60.0)
    assert chat(client).status_code == 200 and loaded(engine) == ["gemma"]  # stays for the next request
    assert chat(client, keep_alive=0).status_code == 200
    settle(engine)
    assert loaded(engine) == []  # 0: leaves at once
    assert chat(client, keep_alive=0.2).status_code == 200 and loaded(engine) == ["gemma"]
    time.sleep(0.6)
    settle(engine)
    assert loaded(engine) == []  # left on its own
    assert client.get("/gemma/health").json()["status"] == "asleep"


def test_load_unload_and_state_endpoints():
    client, engine = make_engine()
    assert transcribe(client).status_code == 200
    info = client.post("/v1/llms/llama/load").json()
    assert info["status"] == "ready" and info["id"] == "llama" and loaded(engine) == ["llama"]
    listing = {m["id"]: m for m in client.get("/v1/llms").json()["llms"]}
    assert listing["llama"]["status"] == "ready" and listing["gemma"]["status"] == "asleep"
    assert listing["llama"]["context_tokens"] == 6144 and listing["llama"]["memory_limit_bytes"] == 6 * 1024**3
    assert listing["llama"]["maker"] == "Meta" and listing["gemma"]["maker"] == "Google"
    health = client.get("/health").json()
    assert [m["id"] for m in health["llms"]] == ["gemma", "llama"]
    assert client.post("/v1/llms/llama/unload").json()["status"] == "asleep"
    assert client.post("/v1/llms/gemma/load").status_code == 200
    assert {m["id"]: m["status"] for m in client.post("/v1/llms/unload").json()["llms"]} == {"gemma": "asleep", "llama": "asleep"}
    assert client.post("/v1/llms/nope/load").status_code == 404


def test_errors_are_clear():
    client, engine = make_engine(resolver=missing)
    assert transcribe(client).status_code == 200
    r = chat(client)
    assert r.status_code == 503 and "not downloaded" in r.json()["detail"]
    assert client.post("/v1/llms/gemma/load").status_code == 503
    client, engine = make_engine(context=1024)
    r = chat(client, messages=[{"role": "user", "content": "word " * 2000}])
    assert r.status_code == 413 and "smaller parts" in r.json()["detail"]
    r = chat(client, messages=[{"role": "user", "content": "word " * 2000}], stream=True)
    assert r.status_code == 413  # a proper status even when a stream was asked for


def test_command_line_options_for_language_models():
    import argparse

    from navo_engine.options import add_model_arguments, llm_overrides

    parser = argparse.ArgumentParser()
    add_model_arguments(parser)
    args = parser.parse_args(["--gemma-model", "/models/gemma", "--llm-context", "4096", "--llm-keep-alive", "0"])
    assert llm_overrides(args) == {"gemma": "/models/gemma", "llama": "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"}
    assert args.llm_context == 4096 and args.llm_keep_alive == 0


def test_a_missing_model_does_not_send_the_speech_models_away():
    client, engine = make_engine(resolver=missing)
    assert transcribe(client).status_code == 200 and loaded(engine) == ["cohere"]
    for path, body in (
        ("/gemma/v1/chat/completions", {"messages": [{"role": "user", "content": "x"}]}),
        ("/v1/chat/completions", {"model": "llama", "messages": [{"role": "user", "content": "x"}]}),
        ("/v1/llms/gemma/load", None),
    ):
        assert client.post(path, json=body).status_code == 503
        assert loaded(engine) == ["cohere"]


def test_a_stop_word_never_shows_up_in_a_stream():
    def pieces(m, tokenizer, prompt, options):
        for index, piece in enumerate(["gemma", " wrote", " this", " answer"]):
            yield piece, ("stop" if index == 3 else None)

    model = make_llm(generator=pieces)
    model.load()
    heard = []
    done = model.generate([{"role": "user", "content": "x"}], stop=[" wrote this"], on_text=heard.append)
    assert done.text == "gemma" and "".join(heard) == "gemma"
    # An end that only looked like the start of a stop word is sent once the answer goes on.
    heard = []
    done = model.generate([{"role": "user", "content": "x"}], stop=[" wrote that"], on_text=heard.append)
    assert done.text == "gemma wrote this answer" and "".join(heard) == done.text


def test_a_stream_nobody_waits_for_does_not_run():
    import threading

    client, engine = make_engine()
    assert transcribe(client).status_code == 200
    # Keep the model thread busy, ask for a stream and leave before its turn comes.
    release = threading.Event()
    engine.worker.submit(release.wait)
    calls = []
    original = engine.llms["gemma"]._generator

    def counting(model, tokenizer, prompt, options):
        calls.append(1)
        yield from original(model, tokenizer, prompt, options)

    engine.llms["gemma"]._generator = counting
    cancel = threading.Event()
    cancel.set()
    # The job as stream_chat queues it, with the client already gone.
    def job():
        if cancel.is_set():
            return
        engine._llm_generate(engine.llms["gemma"], None, [{"role": "user", "content": "x"}], {})

    future = engine.worker.submit(job)
    release.set()
    future.result()
    assert calls == [] and loaded(engine) == ["cohere"]


def test_turning_an_engine_off_wins_over_a_load_in_line():
    client, engine = make_engine()
    assert transcribe(client).status_code == 200
    assert chat(client).status_code == 200 and loaded(engine) == ["gemma"]
    assert client.post("/v1/engines/cohere/disable").json()["status"] == "off"
    assert transcribe(client).status_code == 503
    assert "cohere" not in loaded(engine)


def test_odd_request_values_are_safe():
    client, engine = make_engine()
    assert chat(client, stop=5).status_code == 200
    assert chat(client, stop=["zzz", 7]).status_code == 200
    assert chat(client, keep_alive=1e12).status_code == 200
    assert engine.llms["gemma"].expires_at is not None
    assert client.post("/v1/llms/unload").status_code == 200 and loaded(engine) == []
