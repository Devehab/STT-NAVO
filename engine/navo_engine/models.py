"""Locating model snapshots in the Hugging Face cache."""

from __future__ import annotations

import json
import os
from pathlib import Path


class ModelNotDownloaded(RuntimeError):
    """Raised when a model is not in the local cache and downloading is not allowed."""


def is_complete(path: Path) -> bool:
    """True when a snapshot has its config and every weight file (an interrupted download has not)."""
    if not (path / "config.json").exists():
        return False
    index = path / "model.safetensors.index.json"
    if index.exists():
        try:
            shards = set(json.loads(index.read_text())["weight_map"].values())
        except (OSError, ValueError, KeyError, TypeError):
            return False
        return bool(shards) and all((path / shard).exists() for shard in shards)
    # Snapshot entries are symlinks into blobs/: exists() is false until the blob is complete.
    return any(p.exists() for p in path.glob("*.safetensors"))


def hub_cache_dir() -> Path:
    """The Hugging Face cache folder, found the same way huggingface_hub finds it."""
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"]).expanduser()
    if os.environ.get("HF_HOME"):
        return Path(os.environ["HF_HOME"]).expanduser() / "hub"
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = Path(xdg).expanduser() if xdg else Path.home() / ".cache"
    return base / "huggingface" / "hub"


def cached_snapshot(model_id: str) -> Path | None:
    """A complete local copy of the model, checked with the file system only (no imports, no network).

    The gateway uses this to report downloads while the model worker is not running.
    """
    local = Path(model_id).expanduser()
    if local.exists():
        return local if is_complete(local) else None
    repo = hub_cache_dir() / ("models--" + model_id.replace("/", "--"))
    snapshots = repo / "snapshots"
    candidates = []
    ref = repo / "refs" / "main"
    try:
        if ref.exists():
            candidates.append(snapshots / ref.read_text().strip())
        if snapshots.is_dir():
            candidates.extend(sorted(snapshots.iterdir()))
    except OSError:
        return None
    for candidate in candidates:
        if candidate.is_dir() and is_complete(candidate):
            return candidate
    return None


def resolve_model_dir(model_id: str, allow_download: bool = False) -> Path:
    """Return a local directory for ``model_id``.

    ``model_id`` may be a local path or a Hugging Face repo id. Cached snapshots are
    used without touching the network; a download only happens when
    ``allow_download`` is true.
    """
    local = Path(model_id).expanduser()
    if local.exists():
        return local

    from huggingface_hub import snapshot_download

    from .engines import ignore_patterns_for

    try:
        path = Path(snapshot_download(model_id, local_files_only=True))
        if is_complete(path):
            return path
        missing = ModelNotDownloaded(
            f"The download of '{model_id}' is incomplete. Download it again in Navo > Settings > Speech engines."
        )
    except Exception as exc:  # LocalEntryNotFoundError and friends
        missing = ModelNotDownloaded(
            f"Model '{model_id}' is not downloaded yet. Download it in Navo > Settings > Speech engines."
        )
        missing.__cause__ = exc
    if not allow_download:
        raise missing

    token = os.environ.get("HF_TOKEN") or None
    return Path(snapshot_download(model_id, token=token, ignore_patterns=ignore_patterns_for(model_id)))


def dir_size(path: Path) -> int:
    """Bytes on disk for a model snapshot (Hugging Face snapshots are symlinks into blobs/)."""
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.stat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def is_cached(model_id: str) -> bool:
    try:
        resolve_model_dir(model_id, allow_download=False)
        return True
    except Exception:
        return False
