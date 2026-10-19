"""Finding downloaded models in the Hugging Face cache (no network)."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import huggingface_hub  # noqa: E402

from navo_engine.models import ModelNotDownloaded, cached_snapshot, resolve_model_dir  # noqa: E402

REPO = "audarai/Audar-ASR-V1-Turbo"
COMMIT = "371428bea487c7aec82b27dc21f8d4324002e98e"


def fake_cache(root: Path, files: dict[str, bytes]) -> Path:
    """A cache folder laid out like huggingface_hub's: snapshot entries are symlinks into blobs/."""
    repo = root / ("models--" + REPO.replace("/", "--"))
    snapshot = repo / "snapshots" / COMMIT
    (repo / "blobs").mkdir(parents=True)
    snapshot.mkdir(parents=True)
    (repo / "refs").mkdir()
    (repo / "refs" / "main").write_text(COMMIT)
    for index, (name, data) in enumerate(files.items()):
        blob = repo / "blobs" / f"blob{index}"
        blob.write_bytes(data)
        (snapshot / name).symlink_to(Path("../../blobs") / blob.name)
    return snapshot


@pytest.fixture
def cache(tmp_path, monkeypatch):
    monkeypatch.setenv("HF_HUB_CACHE", str(tmp_path))
    return tmp_path


def test_downloaded_model_resolves_without_asking_huggingface_hub(cache, monkeypatch):
    # huggingface_hub 2 calls a snapshot incomplete when the files Navo skips (GGUF, vLLM) are absent.
    def incomplete(*args, **kwargs):
        raise RuntimeError("The cached snapshot is incomplete: 21 file(s) are missing (Audar-ASR-V1-Turbo.gguf, ...)")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", incomplete)
    snapshot = fake_cache(cache, {"config.json": b"{}", "model.safetensors": b"weights"})
    assert cached_snapshot(REPO) == snapshot
    assert resolve_model_dir(REPO) == snapshot


def test_interrupted_download_is_not_downloaded(cache, monkeypatch):
    def offline(*args, **kwargs):
        raise RuntimeError("not in the cache")

    monkeypatch.setattr(huggingface_hub, "snapshot_download", offline)
    fake_cache(cache, {"config.json": b"{}"})  # the weights never arrived
    assert cached_snapshot(REPO) is None
    with pytest.raises(ModelNotDownloaded):
        resolve_model_dir(REPO)
