"""Download a model into the Hugging Face cache with progress lines the Navo app can parse.

Progress lines look like:  NAVO_PROGRESS 0.42 Downloading speech model 1.8 / 4.3 GB
Exit codes: 0 ok, 3 access denied (gated model / bad token), 4 other download error.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from pathlib import Path

# Most models are stored with Hugging Face's Xet storage now. Its own transfer (hf_xet) fetches
# many chunks at once and runs at full speed; the plain-HTTP route to the same files assembles
# each one on the fly and can wait 20 seconds or more before its first byte, then crawl, so a
# 5 GB file failed again and again with "The read operation timed out". Xet comes first, plain
# HTTP is the fallback when it fails (see fetch_with_retries). Both write a growing file in the
# model's blobs folder, which is what the progress is measured on.
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
# Each model keeps its own files (not a store shared between models): the progress is measured in
# its folder, and Delete in Navo frees the space by removing that folder.
os.environ.setdefault("HF_HUB_DISABLE_SHARED_BLOBS", "1")
# Seconds without data before a connection counts as failed (the library's default is 10).
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "60")
os.environ.setdefault("HF_HUB_ETAG_TIMEOUT", "30")

# Tries before giving up. A failed file starts again (the library drops a partial file), files
# that finished are kept.
ATTEMPTS = 6
# No new byte for this long: the download is stuck, and it is stopped with an error.
STALL_SECONDS = 600


def emit(fraction: float, label: str) -> None:
    print(f"NAVO_PROGRESS {max(0.0, min(1.0, fraction)):.3f} {label}", flush=True)


def repo_cache_dir(repo_id: str) -> Path:
    from huggingface_hub import constants

    return Path(constants.HF_HUB_CACHE) / ("models--" + repo_id.replace("/", "--"))


def dir_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                fp = Path(root) / name
                if not fp.is_symlink():
                    total += fp.stat().st_size
            except OSError:
                pass
    return total


def expected_size(repo_id: str, token: str | None, ignore: list[str]) -> int:
    """Bytes the download will fetch (only the files that are not ignored)."""
    try:
        from huggingface_hub import HfApi
        from huggingface_hub.utils import filter_repo_objects

        info = HfApi().model_info(repo_id, files_metadata=True, token=token)
        wanted = filter_repo_objects(info.siblings or [], ignore_patterns=ignore, key=lambda s: s.rfilename)
        return sum((s.size or 0) for s in wanted)
    except Exception:
        return 0


def gb(n: int) -> str:
    return f"{n / 1e9:.2f}"


# Room left over after a download: a Mac with a full disk stops saving files, apps and recordings.
SPARE_BYTES = 1_000_000_000


def free_bytes(path: Path) -> int | None:
    """Free space on the volume that holds `path` (or its nearest existing parent)."""
    import shutil

    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        return shutil.disk_usage(probe).free
    except OSError:
        return None


def space_problem(total: int, have: int, free: int | None) -> str | None:
    """Why a download of `total` bytes, `have` of them already on disk, can't fit; None when it can."""
    if not total or free is None:
        return None  # sizes unknown: try, as before
    needed = max(0, total - have) + SPARE_BYTES
    if free >= needed:
        return None
    return (
        f"Not enough free space: this download needs {gb(needed - SPARE_BYTES)} GB more and the Mac has "
        f"{gb(free)} GB free (Navo keeps 1 GB spare). Free some space, for example in Downloads or the "
        "Trash, then click Download again."
    )


def is_access_error(exc: BaseException) -> bool:
    from huggingface_hub.errors import GatedRepoError, HfHubHTTPError, RepositoryNotFoundError

    return isinstance(exc, (GatedRepoError, RepositoryNotFoundError)) or (
        isinstance(exc, HfHubHTTPError) and getattr(getattr(exc, "response", None), "status_code", 0) in (401, 403)
    )


def set_route(xet: bool) -> None:
    """Xet's own transfer, or plain HTTP, for the downloads that start after this."""
    from huggingface_hub import constants

    constants.HF_HUB_DISABLE_XET = not xet


def xet_available() -> bool:
    from importlib.util import find_spec

    return os.environ.get("HF_HUB_DISABLE_XET", "").lower() not in ("1", "true", "yes", "on") and find_spec("hf_xet") is not None


def fetch_with_retries(fetch, measure, report, *, attempts: int = ATTEMPTS, stall_seconds: float = STALL_SECONDS,
                       sleep=time.sleep, poll: float = 2.0, use_xet: bool | None = None):
    """Runs `fetch()` until it succeeds: (result, None), or (None, the last error).

    `measure()` gives the bytes on disk so far, `report(bytes)` shows them. Between tries it waits a
    little longer each time and changes route (Xet, then plain HTTP, then Xet again): when one way
    to Hugging Face is slow or failing from where the Mac is, the other often is not. Access errors
    (gated model, bad token) are not tried again.
    """
    # Without hf_xet (or with it turned off) every try is plain HTTP.
    can_switch = xet_available() if use_xet is None else True
    xet = can_switch if use_xet is None else use_xet
    last: BaseException | None = None
    for attempt in range(1, attempts + 1):
        set_route(xet)
        done = threading.Event()
        box: dict = {}

        def worker() -> None:
            try:
                box["result"] = fetch()
            except BaseException as exc:  # reported on the main thread
                box["error"] = exc
            finally:
                done.set()

        threading.Thread(target=worker, daemon=True).start()
        seen, moved = measure(), time.monotonic()
        while not done.wait(poll):
            now = measure()
            report(now)
            if now != seen:
                seen, moved = now, time.monotonic()
            elif time.monotonic() - moved > stall_seconds:
                box["error"] = TimeoutError(f"no data for {int(stall_seconds / 60)} minutes")
                break
        if "error" not in box:
            return box.get("result"), None
        last = box["error"]
        if is_access_error(last) or attempt == attempts:
            break
        if isinstance(last, TimeoutError) and not done.is_set():
            break  # stuck inside the library: this process can't stop that thread, so it ends here
        wait = min(10 * attempt, 60)
        if can_switch:
            xet = not xet
        route = "Xet" if xet else "plain HTTP"
        reason = str(last).splitlines()[0][:200] if str(last) else type(last).__name__
        print(f"Download interrupted ({reason}). Trying again in {wait} s through {route}, "
              f"try {attempt + 1} of {attempts}: the files that finished are kept.", flush=True)
        sleep(wait)
    return None, last


def fail(message: str) -> int:
    print(f"ERROR: {message}", file=sys.stderr, flush=True)
    return 3


def check_access(repo_id: str, token: str | None) -> int:
    """Explain exactly why a gated model cannot be downloaded, before downloading. 0 means go ahead."""
    from huggingface_hub import HfApi, get_token
    from huggingface_hub.errors import GatedRepoError, HfHubHTTPError, RepositoryNotFoundError

    api = HfApi()
    effective = token or get_token()
    account = None
    if effective:
        shown = f"{effective[:5]}...{effective[-4:]}" if len(effective) > 12 else "(too short)"
        print(f"Token received: {shown} ({len(effective)} characters)", flush=True)
        if not effective.startswith("hf_") or any(c in effective for c in "*…• "):
            return fail(
                "That does not look like a full Hugging Face token (it should start with hf_ and contain no dots or stars). "
                "Hugging Face shows a token only once: use 'Invalidate and refresh' on it, or create a new one, "
                "and copy the full value right away."
            )
        try:
            info = api.whoami(token=effective)
            account = info.get("name")
            role = ((info.get("auth") or {}).get("accessToken") or {}).get("role")
            print(f"Hugging Face account: {account} (token type: {role or 'unknown'})", flush=True)
        except HfHubHTTPError as exc:
            if getattr(getattr(exc, "response", None), "status_code", 0) == 401:
                return fail(
                    "The Hugging Face token was rejected: it is invalid, revoked or was pasted incompletely. "
                    "Create a new Read token at https://huggingface.co/settings/tokens"
                )
            print(f"warning: could not verify the token: {exc}", flush=True)
        except Exception as exc:  # offline or proxy: let the download report it
            print(f"warning: could not verify the token: {exc}", flush=True)
    else:
        print("No Hugging Face token given (public models do not need one).", flush=True)

    try:
        api.auth_check(repo_id, token=effective or None)
        return 0
    except GatedRepoError:
        if not effective:
            return fail(
                f"{repo_id} is gated and no Hugging Face token was given. Paste your token in "
                "Navo > Settings > Hugging Face token before Install, or run scripts/run.sh (it asks for it)."
            )
        who = account or "your account"
        return fail(
            f"Account '{who}' has not been given access to {repo_id}. "
            f"Sign in to huggingface.co as '{who}', open https://huggingface.co/{repo_id} and click "
            "'Agree and access repository'. With a fine-grained token, also enable "
            "'Read access to contents of all public gated repos you can access'."
        )
    except RepositoryNotFoundError:
        if not effective:
            return fail(f"{repo_id} needs a Hugging Face token. Paste it in Navo > Settings before Install.")
        return fail(
            f"The token for '{account or 'your account'}' cannot read {repo_id}. "
            "Check that the token type is Read (or fine-grained with gated repo access)."
        )
    except Exception as exc:
        print(f"warning: could not check access to {repo_id}: {exc}", flush=True)
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--label", default="Downloading model")
    parser.add_argument("--progress-start", type=float, default=0.0)
    parser.add_argument("--progress-end", type=float, default=1.0)
    args = parser.parse_args(argv)

    from huggingface_hub import snapshot_download

    from .engines import ignore_patterns_for

    token = (os.environ.get("HF_TOKEN") or "").strip() or None
    if check_access(args.model, token) != 0:
        return 3
    ignore = ignore_patterns_for(args.model)
    span = args.progress_end - args.progress_start
    total = expected_size(args.model, token, ignore)
    blobs = repo_cache_dir(args.model) / "blobs"
    baseline = dir_size(blobs)
    problem = space_problem(total, baseline, free_bytes(blobs))
    if problem:
        print(f"ERROR: {problem}", file=sys.stderr, flush=True)
        return 4
    emit(args.progress_start, f"{args.label} ({args.model})")
    started = time.time()

    def report(current: int) -> None:
        if total:
            frac = min(current / total, 0.999)
            emit(args.progress_start + span * frac, f"{args.label} {gb(current)} / {gb(total)} GB")
        else:
            elapsed = int(time.time() - started)
            emit(args.progress_start, f"{args.label} {gb(max(0, current - baseline))} GB ({elapsed}s)")

    _, exc = fetch_with_retries(
        lambda: snapshot_download(args.model, token=token, ignore_patterns=ignore),
        lambda: dir_size(blobs),
        report,
    )
    if exc is not None:
        if is_access_error(exc):
            print(
                "ERROR: Hugging Face refused access to "
                f"{args.model}.\n"
                f"1) Open https://huggingface.co/{args.model} and accept the model terms with your account.\n"
                "2) Create a Read token at https://huggingface.co/settings/tokens and paste it in "
                "Navo > Settings > Speech engines > Hugging Face token (or run `hf auth login`).",
                file=sys.stderr,
                flush=True,
            )
            return 3
        print(
            f"ERROR: download failed: {exc}. Check the internet connection, then click Download again: "
            "the files that finished are kept.",
            file=sys.stderr,
            flush=True,
        )
        return 4

    # Say "done" only when the engine will find the model: the same check it makes before loading.
    from .models import cached_snapshot

    found = cached_snapshot(args.model)
    if found is None:
        print(
            f"ERROR: the download of {args.model} finished, but its files are incomplete in {repo_cache_dir(args.model)}. "
            "Click Download again: the files that finished are kept. If it keeps failing, check the free disk space.",
            file=sys.stderr,
            flush=True,
        )
        return 4
    emit(args.progress_end, f"{args.label} done")
    print(f"NAVO_MODEL_PATH {found}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
