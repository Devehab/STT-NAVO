"""The gateway: sleeps with no worker, wakes on requests, frees memory when idle (fake models).

    cd engine && python -m pytest -q tests/test_gateway.py
"""

import argparse
import io
import os
import sys
import time
from pathlib import Path

import pytest

ENGINE_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE_DIR))

from fastapi.testclient import TestClient  # noqa: E402

from navo_engine.gateway import Gateway, create_gateway_app  # noqa: E402
from navo_engine.options import add_model_arguments  # noqa: E402

from test_server import wav_bytes  # noqa: E402

FAKE_WORKER = str(Path(__file__).with_name("fake_worker.py"))


def fake_command(gateway, preload_all):
    return [
        sys.executable, FAKE_WORKER,
        "--uds", gateway.socket_path,
        "--engines", ",".join(gateway.enabled) or "none",
        "--default-engine", gateway.default_engine,
        "--preload", ",".join(gateway.enabled) if preload_all else "none",
        "--llm-keep-alive", str(gateway.args.llm_keep_alive),
        "--parent-pid", str(os.getpid()),
    ]


def make_gateway(idle_minutes=10.0, engines="cohere", extra=()):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7861)
    add_model_arguments(parser)
    args = parser.parse_args(["--engines", engines, "--llm-model", "fake/llm", *extra])
    return Gateway(args, idle_minutes=idle_minutes, command=fake_command, check_interval=0.1, settle_seconds=0.3)


def post_audio(client, path, **data):
    return client.post(path, files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")}, data=data)


def wait_for(predicate, seconds=10.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


@pytest.fixture
def pythonpath(monkeypatch):
    monkeypatch.setenv("PYTHONPATH", str(ENGINE_DIR))


def test_starts_asleep_without_a_worker(pythonpath):
    gateway = make_gateway()
    with TestClient(create_gateway_app(gateway)) as client:
        health = client.get("/health").json()
        assert health["sleeping"] is True and health["worker_pid"] is None
        assert health["pid"] == os.getpid()
        states = {e["id"]: e["status"] for e in health["engines"]}
        assert states == {"cohere": "asleep", "audar": "off", "whisper": "off", "qwen3": "off"}
        assert health["status"] == "asleep"
        assert client.get("/").status_code == 404  # a stray read does not start the models
        assert gateway.process is None


def test_request_wakes_the_worker_and_idle_frees_it(pythonpath):
    gateway = make_gateway(idle_minutes=0.01)  # 0.6 s
    with TestClient(create_gateway_app(gateway)) as client:
        r = post_audio(client, "/cohere/v1/audio/transcriptions")
        assert r.status_code == 200, r.text
        assert r.json()["text"] == "cohere text"
        worker = gateway.process
        assert worker is not None and worker.poll() is None
        health = client.get("/health").json()
        assert health["sleeping"] is False and health["worker_pid"] == worker.pid
        assert {e["id"]: e["status"] for e in health["engines"]}["cohere"] == "ready"

        assert wait_for(lambda: gateway.process is None), "worker should stop once idle"
        assert worker.poll() is not None
        health = client.get("/health").json()
        assert health["sleeping"] is True
        cohere = next(e for e in health["engines"] if e["id"] == "cohere")
        assert cohere["status"] == "asleep" and cohere["transcriptions"] == 1

        # And it wakes again.
        assert post_audio(client, "/v1/audio/transcriptions").json()["text"] == "cohere text"
        assert client.get("/health").json()["transcriptions"] == 2


def test_turned_off_engine_never_starts_the_worker(pythonpath):
    gateway = make_gateway()
    with TestClient(create_gateway_app(gateway)) as client:
        r = post_audio(client, "/audar/v1/audio/transcriptions")
        assert r.status_code == 503 and "turned off" in r.json()["detail"]
        assert gateway.process is None


def test_enable_while_asleep_then_use(pythonpath):
    gateway = make_gateway()
    with TestClient(create_gateway_app(gateway)) as client:
        r = client.post("/v1/engines/audar/enable")
        assert r.json()["status"] == "asleep"
        assert gateway.process is None
        assert post_audio(client, "/audar/v1/audio/transcriptions").json()["text"] == "audar text"
        body = post_audio(client, "/v1/audio/compare").json()
        assert {x["engine"]: x["text"] for x in body["results"]} == {"cohere": "cohere text", "audar": "audar text"}
        r = client.post("/v1/engines/audar/disable")
        assert r.json()["status"] == "off"
        assert post_audio(client, "/audar/v1/audio/transcriptions").status_code == 503


def test_wake_and_sleep_now(pythonpath):
    gateway = make_gateway()
    with TestClient(create_gateway_app(gateway)) as client:
        r = client.post("/v1/wake", params={"engine": "cohere", "cleanup": "true"})
        assert r.status_code == 200, r.text
        assert wait_for(lambda: client.get("/cohere/health").json()["status"] == "ready")
        r = client.post("/v1/sleep/now")
        assert r.status_code == 200 and r.json()["worker"] == "sleeping"
        assert gateway.process is None


def test_sleep_setting(pythonpath):
    gateway = make_gateway()
    with TestClient(create_gateway_app(gateway)) as client:
        assert client.post("/v1/sleep", json={"idle_minutes": 30}).json()["idle_minutes"] == 30
        assert client.get("/health").json()["idle_minutes"] == 30
        assert client.post("/v1/sleep", json={"minutes": "x"}).status_code == 400


def test_zero_keeps_models_loaded(pythonpath):
    gateway = make_gateway(idle_minutes=0)
    with TestClient(create_gateway_app(gateway)) as client:
        assert gateway.process is not None  # started with the gateway
        assert wait_for(lambda: client.get("/cohere/health").json()["status"] == "ready")
        time.sleep(0.5)
        assert gateway.process is not None and gateway.process.poll() is None


def test_only_two_engines_can_be_on(pythonpath):
    gateway = make_gateway(engines="cohere,audar")
    with TestClient(create_gateway_app(gateway)) as client:
        for action in ("enable", "load"):
            r = client.post(f"/v1/engines/whisper/{action}")
            assert r.status_code == 409, r.text
            assert "Only 2 speech engines" in r.json()["detail"]
        assert gateway.enabled == ["cohere", "audar"] and gateway.process is None
        # An engine that is already on can always be enabled again.
        assert client.post("/v1/engines/audar/enable").status_code == 200
        assert client.post("/v1/engines/audar/disable").status_code == 200
        r = client.post("/v1/engines/whisper/enable")
        assert r.status_code == 200 and r.json()["status"] == "asleep"
        states = {e["id"]: e["status"] for e in client.get("/health").json()["engines"]}
        assert states == {"cohere": "asleep", "audar": "off", "whisper": "asleep", "qwen3": "off"}


def test_worker_command_passes_every_model():
    from navo_engine.gateway import default_worker_command

    gateway = make_gateway(engines="whisper,qwen3")
    command = default_worker_command(gateway, preload_all=False)
    flags = dict(zip(command, command[1:]))
    assert flags["--engines"] == "whisper,qwen3"
    assert flags["--whisper-model"] == "mlx-community/whisper-large-v3-turbo-asr-fp16"
    assert flags["--qwen3-model"] == "mlx-community/Qwen3-ASR-1.7B-bf16"
    assert flags["--audar-model"] == "audarai/Audar-ASR-V1-Turbo"


def test_more_than_two_engines_on_the_command_line_is_refused():
    from navo_engine import gateway as gateway_module
    from navo_engine import server as server_module

    for main in (gateway_module.main, server_module.main):
        with pytest.raises(SystemExit):
            main(["--engines", "cohere,audar,whisper"])


@pytest.fixture
def gemma_folder(tmp_path):
    """A folder that looks like a downloaded model, so the gateway reports Gemma as downloaded."""
    (tmp_path / "config.json").write_text("{}")
    (tmp_path / "model.safetensors").write_bytes(b"x")
    return str(tmp_path)


def test_language_models_sleep_and_wake_through_the_gateway(pythonpath, gemma_folder):
    gateway = make_gateway(idle_minutes=0.01, extra=["--gemma-model", gemma_folder, "--llm-keep-alive", "0.3"])
    with TestClient(create_gateway_app(gateway)) as client:
        models = {m["id"]: m for m in client.get("/v1/llms").json()["llms"]}
        assert models["gemma"]["status"] == "asleep" and models["gemma"]["downloaded"] is True
        assert models["llama"]["downloaded"] is False
        assert models["gemma"]["memory_limit_bytes"] == 6 * 1024**3
        assert client.get("/gemma/health").json()["id"] == "gemma"
        assert [m["id"] for m in client.get("/health").json()["llms"]] == ["gemma", "llama"]
        assert gateway.process is None  # reading never wakes the models

        # A model that is not downloaded answers at once, and the worker stays asleep.
        r = client.post("/llama/v1/chat/completions", json={"messages": [{"role": "user", "content": "hi"}]})
        assert r.status_code == 503 and "not downloaded" in r.json()["detail"]
        assert client.post("/v1/llms/llama/load").status_code == 503
        assert client.post("/v1/llms/gemma/unload").json()["status"] == "asleep"
        assert gateway.process is None

        assert client.post("/nope/v1/chat/completions", json={"messages": []}).status_code == 404
        assert gateway.process is None and gateway.in_flight == 0

        # A chat request wakes the worker, which loads the model and answers.
        r = client.post("/gemma/v1/chat/completions", json={
            "messages": [{"role": "system", "content": "Summarize."}, {"role": "user", "content": "hello"}],
        })
        assert r.status_code == 200, r.text
        assert r.json()["choices"][0]["message"]["content"] == "gemma wrote this answer"
        assert gateway.process is not None and gateway.process.poll() is None
        assert {m["id"]: m["status"] for m in client.get("/v1/llms").json()["llms"]}["gemma"] == "ready"

        # It leaves memory after its keep alive time, and then the worker goes too.
        assert wait_for(lambda: gateway.process is None), "the worker did not stop after the model left"
        assert client.get("/gemma/health").json()["status"] == "asleep"


def test_streamed_answers_pass_through_the_gateway(pythonpath, gemma_folder):
    import json

    gateway = make_gateway(extra=["--gemma-model", gemma_folder])
    with TestClient(create_gateway_app(gateway)) as client:
        with client.stream("POST", "/v1/chat/completions", json={
            "model": "gemma", "stream": True, "messages": [{"role": "user", "content": "hello"}],
        }) as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            lines = [line for line in response.iter_lines() if line]
        assert lines[-1] == "data: [DONE]"
        chunks = [json.loads(line[len("data: "):]) for line in lines[:-1]]
        assert "".join(c["choices"][0]["delta"].get("content", "") for c in chunks) == "gemma wrote this answer"
        assert chunks[-1]["usage"]["completion_tokens"] == 4
        assert gateway.in_flight == 0
        # The speech engine still answers afterwards: the worker swaps the models itself.
        r = post_audio(client, "/cohere/v1/audio/transcriptions")
        assert r.status_code == 200 and r.json()["text"] == "cohere text"
        assert client.get("/gemma/health").json()["status"] == "asleep"


def test_worker_command_passes_the_language_models():
    from navo_engine.gateway import default_worker_command

    gateway = make_gateway(extra=["--llm-context", "4096", "--llm-keep-alive", "15"])
    command = default_worker_command(gateway, preload_all=False)
    flags = dict(zip(command, command[1:]))
    assert flags["--gemma-model"] == "mlx-community/gemma-4-e4b-it-4bit"
    assert flags["--llama-model"] == "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"
    assert flags["--llm-context"] == "4096" and flags["--llm-keep-alive"] == "15.0"
