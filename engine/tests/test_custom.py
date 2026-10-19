"""Language models added from a folder (no model is loaded here)."""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from navo_engine import custom  # noqa: E402
from navo_engine.llms import LLM_PROFILES  # noqa: E402


def test_parse_keeps_only_usable_entries(tmp_path):
    value = json.dumps([
        {"id": "custom-a1", "name": "Bonsai", "path": str(tmp_path), "format": "mlx"},
        {"id": "gemma", "path": str(tmp_path)},  # not a custom id
        {"id": "custom-b2", "path": str(tmp_path), "format": "onnx"},  # unknown format
        {"name": "no id or path"},
    ])
    models = custom.parse(value)
    assert [m.id for m in models] == ["custom-a1"]
    assert custom.parse("not json") == []
    assert custom.parse(None) == []


def test_main_gguf_skips_the_vision_projector(tmp_path):
    (tmp_path / "mmproj-model-BF16.gguf").write_bytes(b"x" * 300)
    (tmp_path / "model-Q4_0.gguf").write_bytes(b"x" * 200)
    (tmp_path / "README.md").write_text("hi")
    assert custom.main_gguf(tmp_path).name == "model-Q4_0.gguf"
    assert custom.main_gguf(tmp_path / "model-Q4_0.gguf").name == "model-Q4_0.gguf"
    assert custom.main_gguf(tmp_path / "README.md") is None


def test_registered_models_are_language_models(tmp_path):
    gguf = tmp_path / "gguf"
    gguf.mkdir()
    (gguf / "m.gguf").write_bytes(b"x")
    mlx = tmp_path / "mlx"
    mlx.mkdir()
    (mlx / "config.json").write_text("{}")
    (mlx / "model.safetensors").write_bytes(b"x")
    empty = tmp_path / "empty"
    empty.mkdir()
    custom.register(custom.parse(json.dumps([
        {"id": "custom-g", "name": "G", "path": str(gguf), "format": "gguf"},
        {"id": "custom-m", "name": "M", "path": str(mlx), "format": "mlx"},
        {"id": "custom-e", "name": "E", "path": str(empty), "format": "mlx"},
    ])))
    try:
        assert LLM_PROFILES["custom-g"].model_id == str(gguf)
        assert custom.is_available("custom-g", str(gguf))
        assert custom.is_available("custom-m", str(mlx))
        assert not custom.is_available("custom-e", str(empty))
    finally:
        for key in ("custom-g", "custom-m", "custom-e"):
            LLM_PROFILES.pop(key, None)
            custom.CUSTOM.pop(key, None)


def test_memory_limit_follows_the_model_size(tmp_path):
    small = tmp_path / "small.gguf"
    small.write_bytes(b"x" * 10)
    assert custom.memory_limit_for(small) >= custom.MEMORY_LIMIT_BYTES
    assert custom.memory_limit_for(small) <= custom.total_memory()
