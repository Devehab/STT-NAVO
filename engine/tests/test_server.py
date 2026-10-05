"""Server tests with fake backends (no MLX / model needed).

    cd engine && python -m pytest -q
"""

import io
import struct
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from navo_engine.asr import ASRService, normalize_language  # noqa: E402
from navo_engine.llm import LLMService, strip_thinking  # noqa: E402
from navo_engine.server import Engine, create_app  # noqa: E402


def wav_bytes(seconds: float = 1.0, sr: int = 16000) -> bytes:
    n = int(seconds * sr)
    samples = (np.sin(np.linspace(0, 440 * 2 * np.pi * seconds, n)) * 8000).astype("<i2").tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(samples)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sr, sr * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(samples))
    return header + samples


class FakeBackend:
    name = "fake"

    def __init__(self, model_dir):
        self.calls = []

    def transcribe(self, audio, language):
        self.calls.append((len(audio), language))
        return "  مرحبا hello  " if language == "ar" else "hello"


class BrokenBackend:
    name = "broken"

    def __init__(self, model_dir):
        raise RuntimeError("no metal")


_MODEL_DIR = Path(__import__("tempfile").mkdtemp(prefix="navo-model-"))
(_MODEL_DIR / "model.safetensors").write_bytes(b"x" * 1024)


def make_client(backends, resolver=lambda m, d: _MODEL_DIR):
    asr = ASRService("fake/model", backends=backends, model_resolver=resolver)
    llm = LLMService("fake/llm")
    engine = Engine(asr, llm)
    engine.worker.submit(asr.load).result()
    return TestClient(create_app(engine)), asr


def test_health_and_transcribe():
    client, asr = make_client({"fake": FakeBackend})
    health = client.get("/health").json()
    assert health["status"] == "ready"
    assert health["backend"] == "fake"

    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")},
        data={"language": "ar", "model": "whatever"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["text"] == "مرحبا hello"
    assert body["language"] == "ar"
    health = client.get("/health").json()
    assert health["transcriptions"] == 1
    assert health["model_bytes"] == 1024
    assert health["pid"] > 0
    assert health["host"] == "127.0.0.1"
    # 1 s warm-up at load + the real request, both at 16 kHz
    assert asr.backend.calls[-1] == (16000, "ar")


def test_resamples_to_16k():
    client, asr = make_client({"fake": FakeBackend})
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes(1.0, 48000)), "audio/wav")},
        data={"language": "en"},
    )
    assert r.status_code == 200
    assert asr.backend.calls[-1] == (16000, "en")


def test_fallback_to_next_backend():
    client, asr = make_client({"mlx": BrokenBackend, "transformers": FakeBackend})
    assert asr.status == "ready"
    assert asr.backend_name == "fake"


def test_all_backends_fail_reports_error():
    client, asr = make_client({"mlx": BrokenBackend})
    health = client.get("/health").json()
    assert health["status"] == "error"
    assert "no metal" in health["error"]
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")},
    )
    assert r.status_code == 503


def test_missing_model_reports_error():
    def resolver(model_id, allow):
        raise RuntimeError("Model 'x' is not downloaded yet")

    client, asr = make_client({"fake": FakeBackend}, resolver)
    assert client.get("/health").json()["status"] == "error"


def test_bad_language_and_empty_file():
    client, _ = make_client({"fake": FakeBackend})
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")},
        data={"language": "fr"},
    )
    assert r.status_code == 400
    r = client.post("/v1/audio/transcriptions", files={"file": ("a.wav", io.BytesIO(b""), "audio/wav")})
    assert r.status_code == 400


def test_chat_unavailable_is_503():
    client, _ = make_client({"fake": FakeBackend})
    r = client.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "hi"}]})
    assert r.status_code == 503


def test_language_normalization():
    assert normalize_language("Arabic") == "ar"
    assert normalize_language("en_US") == "en"
    assert normalize_language(None) == "ar"
    with pytest.raises(ValueError):
        normalize_language("de")


def test_strip_thinking():
    assert strip_thinking("<think>x</think>\nمرحبا") == "مرحبا"
    assert strip_thinking("reasoning</think> done") == "done"


def test_duration_and_text_format():
    client, _ = make_client({"fake": FakeBackend})
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes(2.0)), "audio/wav")},
        data={"language": "ar"},
    )
    assert r.json()["duration"] == 2.0
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")},
        data={"language": "ar", "response_format": "text"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert r.text == "مرحبا hello"


def test_unreadable_audio_is_415():
    client, _ = make_client({"fake": FakeBackend})
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": ("a.m4a", io.BytesIO(b"not really audio" * 100), "audio/mp4")},
    )
    assert r.status_code == 415
    assert "ffmpeg" in r.json()["detail"]


@pytest.mark.parametrize("ext,args", [
    ("mp3", ["-c:a", "libmp3lame"]),
    ("ogg", ["-c:a", "libopus"]),
    ("flac", []),
])
def test_compressed_formats(tmp_path, ext, args):
    import shutil
    import subprocess

    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg not installed")
    src = tmp_path / "in.wav"
    src.write_bytes(wav_bytes(1.5, 48000))
    out = tmp_path / f"out.{ext}"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), *args, str(out)], check=True)
    client, asr = make_client({"fake": FakeBackend})
    r = client.post(
        "/v1/audio/transcriptions",
        files={"file": (out.name, io.BytesIO(out.read_bytes()), "application/octet-stream")},
        data={"language": "en"},
    )
    assert r.status_code == 200, r.text
    assert abs(r.json()["duration"] - 1.5) < 0.1


def test_markers_are_removed():
    from navo_engine.asr import clean_markers

    assert clean_markers("ركز كتير <hesitation> نفس الشي <hesitation>، وخلص") == "ركز كتير نفس الشي، وخلص"
    assert clean_markers("hello <unk> world") == "hello world"
    assert clean_markers("a < b and c > d") == "a < b and c > d"


# Two engines ----------------------------------------------------------------


class OtherBackend:
    name = "other"

    def __init__(self, model_dir):
        pass

    def transcribe(self, audio, language):
        return "audar says hi"


def make_two(default="cohere", load=("cohere", "audar"), enabled=("cohere", "audar")):
    resolver = lambda m, d: _MODEL_DIR  # noqa: E731
    cohere = ASRService("fake/cohere", backends={"fake": FakeBackend}, model_resolver=resolver,
                        engine_id="cohere", name="Cohere Transcribe Arabic")
    audar = ASRService("fake/audar", backends={"other": OtherBackend}, model_resolver=resolver,
                       engine_id="audar", name="Audar ASR V1 Turbo", family="qwen3_asr")
    engine = Engine({"cohere": cohere, "audar": audar}, LLMService("fake/llm"), default_engine=default,
                    enabled=list(enabled))
    for engine_id in load:
        engine.worker.submit(engine.engines[engine_id].load).result()
    return TestClient(create_app(engine)), engine


def post(client, path, **data):
    return client.post(path, files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")}, data=data)


def test_engine_paths_and_model_routing():
    client, engine = make_two()
    assert post(client, "/audar/v1/audio/transcriptions").json()["text"] == "audar says hi"
    assert post(client, "/cohere/v1/audio/transcriptions", language="en").json()["text"] == "hello"
    body = post(client, "/v1/audio/transcriptions", model="audarai/Audar-ASR-V1-Turbo").json()
    assert body["engine"] == "audar" and body["text"] == "audar says hi"
    assert post(client, "/v1/audio/transcriptions", model="audar-asr-v1-turbo").json()["engine"] == "audar"
    # A model name that is not an engine (OpenAI clients send whisper-1) goes to the default engine.
    assert post(client, "/v1/audio/transcriptions", model="whisper-1").json()["engine"] == "cohere"
    assert post(client, "/nope/v1/audio/transcriptions").status_code == 404


def test_default_engine_can_change():
    client, engine = make_two()
    r = client.post("/v1/engines/audar/default")
    assert r.json()["default_engine"] == "audar"
    assert post(client, "/v1/audio/transcriptions").json()["engine"] == "audar"
    health = client.get("/health").json()
    assert health["default_engine"] == "audar"
    assert [e["id"] for e in health["engines"]] == ["cohere", "audar"]
    assert [e["default"] for e in health["engines"]] == [False, True]


def test_unload_puts_an_engine_to_sleep_and_a_request_wakes_it():
    client, engine = make_two()
    r = client.post("/v1/engines/audar/unload")
    assert r.json()["status"] == "asleep"
    assert engine.engines["audar"].backend is None
    # The next request loads it again, then answers.
    r = post(client, "/audar/v1/audio/transcriptions")
    assert r.status_code == 200 and r.json()["text"] == "audar says hi"
    assert client.get("/audar/health").json()["status"] == "ready"
    assert client.get("/audar/health").json()["idle_seconds"] is not None


def test_disable_turns_an_engine_off():
    client, engine = make_two()
    r = client.post("/v1/engines/audar/disable")
    assert r.json()["status"] == "off" and engine.engines["audar"].backend is None
    r = post(client, "/audar/v1/audio/transcriptions")
    assert r.status_code == 503 and "turned off" in r.json()["detail"]
    assert post(client, "/cohere/v1/audio/transcriptions").status_code == 200  # Cohere is unaffected
    assert client.post("/v1/engines/audar/enable").json()["status"] == "asleep"
    r = client.post("/v1/engines/audar/load")
    assert r.json()["status"] in ("loading", "ready")
    engine.worker.submit(lambda: None).result()  # wait for the queued load
    assert client.get("/audar/health").json()["status"] == "ready"


def test_engine_states_at_start():
    client, engine = make_two(load=("cohere",), enabled=("cohere",))
    engines = {e["id"]: e for e in client.get("/v1/engines").json()["engines"]}
    assert engines["cohere"]["status"] == "ready"
    assert engines["audar"]["status"] == "off"
    assert engines["audar"]["downloaded"] is True
    client, engine = make_two(load=("cohere",))
    engines = {e["id"]: e for e in client.get("/v1/engines").json()["engines"]}
    assert engines["audar"]["status"] == "asleep"


def test_wake_starts_loading_and_returns_at_once():
    client, engine = make_two(load=())
    r = client.post("/v1/wake", params={"engine": "audar"})
    assert r.status_code == 200 and r.json()["engine"]["status"] in ("loading", "ready")
    engine.worker.submit(lambda: None).result()
    assert client.get("/audar/health").json()["status"] == "ready"
    assert client.post("/v1/wake", params={"engine": "nope"}).status_code == 404


def test_compare_runs_every_engine_that_is_on():
    client, engine = make_two()
    r = post(client, "/v1/audio/compare", language="ar")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["duration"] == 1.0
    results = {x["engine"]: x for x in body["results"]}
    assert results["cohere"]["text"] == "مرحبا hello"
    assert results["audar"]["text"] == "audar says hi"
    assert all(x["processing_ms"] is not None and x["error"] is None for x in body["results"])


def test_compare_wakes_sleeping_engines_and_reports_off_ones():
    client, engine = make_two(load=("cohere",))
    body = post(client, "/v1/audio/compare").json()
    assert {x["engine"]: x["text"] for x in body["results"]} == {"cohere": "مرحبا hello", "audar": "audar says hi"}
    client, engine = make_two(load=("cohere",), enabled=("cohere",))
    body = post(client, "/v1/audio/compare", engines="cohere,audar").json()
    results = {x["engine"]: x for x in body["results"]}
    assert results["cohere"]["text"]
    assert results["audar"]["text"] is None and "off" in results["audar"]["error"]
    # Without a list, only engines that are on take part.
    body = post(client, "/v1/audio/compare").json()
    assert [x["engine"] for x in body["results"]] == ["cohere"]
    assert post(client, "/v1/audio/compare", engines="nope").status_code == 404


def test_cleanup_model_unloads(monkeypatch):
    import navo_engine.llm as llm_module

    monkeypatch.setattr(llm_module, "resolve_model_dir", lambda m, allow_download=False: _MODEL_DIR)
    llm = LLMService("fake/llm", loader=lambda path: ("model", "tokenizer"))
    llm.preload()
    assert llm.info()["loaded_model"] == "fake/llm" and llm.info()["idle_seconds"] is not None
    llm.unload()
    assert llm.info()["loaded_model"] is None and llm.info()["idle_seconds"] is None


def test_engine_lookup():
    from navo_engine.engines import ignore_patterns_for, lookup

    assert lookup("audar") == "audar"
    assert lookup("Audar-ASR-V1-Turbo") == "audar"
    assert lookup("CohereLabs/cohere-transcribe-arabic-07-2026") == "cohere"
    assert lookup("cohere-transcribe-arabic-07-2026") == "cohere"
    assert lookup("whisper-1") is None
    assert lookup(None) is None
    assert lookup("whisper") == "whisper"
    assert lookup("whisper-large-v3-turbo") == "whisper"
    assert lookup("mlx-community/whisper-large-v3-turbo-asr-fp16") == "whisper"
    assert lookup("qwen3") == "qwen3"
    assert lookup("Qwen3-ASR-1.7B") == "qwen3"
    assert lookup("mlx-community/Qwen3-ASR-1.7B-bf16") == "qwen3"
    assert lookup("my/own-whisper", {"whisper": "my/own-whisper"}) == "whisper"
    assert lookup("/Users/me/models/my-audar", {"audar": "/Users/me/models/my-audar"}) == "audar"
    assert "vllm-*/*" in ignore_patterns_for("audarai/Audar-ASR-V1-Turbo")


def test_qwen3_output_cleanup():
    from navo_engine.asr import clean_qwen3_output, collapse_loops

    assert clean_qwen3_output("language Arabic<asr_text>مرحبا كيفك") == "مرحبا كيفك"
    assert clean_qwen3_output("language None<asr_text>") == ""
    assert clean_qwen3_output("بدون بادئة") == "بدون بادئة"
    looped = "شكرا " + "على المشاهدة " * 30
    assert collapse_loops(looped).count("المشاهدة") == 1
    assert collapse_loops("لا لا لا، ما بدي") == "لا لا لا، ما بدي"
    assert collapse_loops("0791234567") == "0791234567"


def test_incomplete_download_is_not_a_model(tmp_path):
    from navo_engine.models import is_complete

    (tmp_path / "config.json").write_text("{}")
    assert not is_complete(tmp_path)
    (tmp_path / "model.safetensors").symlink_to(tmp_path / "missing-blob")
    assert not is_complete(tmp_path)
    (tmp_path / "missing-blob").write_bytes(b"x")
    assert is_complete(tmp_path)


def test_enable_retries_an_engine_that_failed_to_load():
    client, asr = make_client({"mlx": BrokenBackend})
    assert client.get("/health").json()["status"] == "error"
    r = client.post(f"/v1/engines/{asr.engine_id}/enable")
    assert r.json()["status"] == "asleep" and r.json()["error"] is None


# Languages, splitting, silence -----------------------------------------------


def test_auto_language_only_where_the_engine_supports_it():
    client, engine = make_two()
    engine.engines["audar"].languages = ("ar", "en", "auto")
    r = post(client, "/audar/v1/audio/transcriptions", language="auto")
    assert r.status_code == 200 and r.json()["language"] == "auto"
    r = post(client, "/cohere/v1/audio/transcriptions", language="auto")
    assert r.status_code == 400 and "does not support" in r.json()["detail"]
    assert post(client, "/cohere/v1/audio/transcriptions", language="klingon").status_code == 400
    body = client.post("/v1/audio/compare", files={"file": ("a.wav", io.BytesIO(wav_bytes()), "audio/wav")},
                       data={"language": "auto"}).json()
    results = {r["engine"]: r for r in body["results"]}
    assert results["audar"]["text"] == "audar says hi"
    assert "does not support" in results["cohere"]["error"]
    languages = {e["id"]: e["languages"] for e in client.get("/v1/engines").json()["engines"]}
    assert languages == {"cohere": ["ar", "en"], "audar": ["ar", "en", "auto"]}


class ShortBackend:
    """A model that takes at most 5 seconds at a time."""

    name = "short"
    max_seconds = 5.0

    def __init__(self, model_dir):
        self.calls = []

    def transcribe(self, audio, language):
        assert len(audio) <= 5 * 16000
        self.calls.append(len(audio))
        return f"piece{len(self.calls)}"


def test_long_audio_is_split_for_the_model_and_silence_is_skipped():
    service = ASRService("fake/short", backends={"short": ShortBackend}, model_resolver=lambda m, d: _MODEL_DIR)
    service.set_enabled(True)
    service.load()
    backend = service.backend
    backend.calls.clear()
    rng = np.random.default_rng(0)
    speech = (0.1 * rng.standard_normal(16000 * 12)).astype(np.float32)
    assert service.transcribe_audio(speech, "ar") == "piece1 piece2 piece3"
    assert sum(backend.calls) == len(speech)
    backend.calls.clear()
    assert service.transcribe_audio(np.zeros(16000 * 12, dtype=np.float32), "ar") == ""
    assert backend.calls == []
    with pytest.raises(ValueError):
        service.transcribe_audio(speech, "auto")


def test_four_engines_and_their_languages():
    from navo_engine.asr import Qwen3MLXBackend
    from navo_engine.engines import ALL_LANGUAGES, MAX_ENABLED_ENGINES, PROFILES

    assert list(PROFILES) == ["cohere", "audar", "whisper", "qwen3"]
    assert MAX_ENABLED_ENGINES == 2
    assert PROFILES["whisper"].family == "whisper" and not PROFILES["whisper"].gated
    assert PROFILES["qwen3"].family == "qwen3_asr" and not PROFILES["qwen3"].gated
    whisper, qwen3 = PROFILES["whisper"].languages, PROFILES["qwen3"].languages
    assert len(whisper) == len(set(whisper)) == 101  # 100 languages and auto
    assert len(qwen3) == len(set(qwen3)) == 31  # 30 languages and auto
    assert {"ar", "en", "auto", "fr", "zh", "yue"} <= set(whisper) & set(qwen3)
    # Every Qwen3 code has the name Qwen3-ASR's prompt uses.
    assert set(qwen3) == set(Qwen3MLXBackend.LANGUAGE_NAMES)
    assert set(ALL_LANGUAGES) == set(whisper) | set(qwen3) | {"ar", "en", "auto"}


def test_regional_and_named_languages():
    from navo_engine.engines import ALL_LANGUAGES

    assert normalize_language("fr-FR", ALL_LANGUAGES) == "fr"
    assert normalize_language("pt_BR", ALL_LANGUAGES) == "pt"
    assert normalize_language("ar-SA") == "ar"
    assert normalize_language("en-GB") == "en"
    assert normalize_language("zh-HK", ALL_LANGUAGES) == "yue"
    assert normalize_language("German", ALL_LANGUAGES) == "de"
    with pytest.raises(ValueError):
        normalize_language("xx", ALL_LANGUAGES)
    with pytest.raises(ValueError):
        normalize_language("fr")  # not in the default (Arabic and English) set


def make_three(enabled=("cohere", "audar")):
    resolver = lambda m, d: _MODEL_DIR  # noqa: E731
    from navo_engine.engines import PROFILES

    services = {
        engine_id: ASRService(
            f"fake/{engine_id}", backends={"fake": FakeBackend}, model_resolver=resolver, engine_id=engine_id,
            name=PROFILES[engine_id].name, family=PROFILES[engine_id].family, languages=PROFILES[engine_id].languages,
        )
        for engine_id in ("cohere", "audar", "whisper")
    }
    engine = Engine(services, LLMService("fake/llm"), default_engine="cohere", enabled=list(enabled))
    return TestClient(create_app(engine)), engine


def test_a_third_engine_waits_until_one_is_turned_off():
    client, engine = make_three()
    for action in ("enable", "load"):
        r = client.post(f"/v1/engines/whisper/{action}")
        assert r.status_code == 409 and "Only 2 speech engines" in r.json()["detail"]
    assert engine.enabled_ids == ["cohere", "audar"]
    assert client.post("/v1/engines/audar/load").status_code == 200  # already on: fine
    engine.worker.submit(lambda: None).result()
    assert client.post("/v1/engines/audar/disable").json()["status"] == "off"
    r = client.post("/v1/engines/whisper/load")
    assert r.status_code == 200
    engine.worker.submit(lambda: None).result()
    assert engine.enabled_ids == ["cohere", "whisper"]
    assert client.get("/whisper/health").json()["status"] == "ready"


def test_each_engine_takes_only_its_own_languages():
    client, engine = make_three(enabled=("cohere", "whisper"))
    r = post(client, "/whisper/v1/audio/transcriptions", language="fr")
    assert r.status_code == 200 and r.json()["language"] == "fr"
    r = post(client, "/whisper/v1/audio/transcriptions", language="auto")
    assert r.status_code == 200
    r = post(client, "/cohere/v1/audio/transcriptions", language="fr")
    assert r.status_code == 400 and "does not support" in r.json()["detail"]
    r = post(client, "/v1/audio/transcriptions", model="whisper-large-v3-turbo", language="de-DE")
    assert r.status_code == 200 and r.json()["engine"] == "whisper" and r.json()["language"] == "de"
    assert post(client, "/whisper/v1/audio/transcriptions", language="klingon").status_code == 400


def test_model_overrides_from_the_command_line():
    import argparse

    from navo_engine.options import add_model_arguments, model_overrides

    parser = argparse.ArgumentParser()
    add_model_arguments(parser)
    models = model_overrides(parser.parse_args(["--whisper-model", "/models/whisper", "--asr-model", "my/cohere"]))
    assert models == {
        "cohere": "my/cohere",
        "audar": "audarai/Audar-ASR-V1-Turbo",
        "whisper": "/models/whisper",
        "qwen3": "mlx-community/Qwen3-ASR-1.7B-bf16",
    }
