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

# Plain HTTP downloads write growing *.incomplete files we can measure for progress.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


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
    from huggingface_hub.errors import GatedRepoError, HfHubHTTPError, RepositoryNotFoundError

    from .engines import ignore_patterns_for

    token = (os.environ.get("HF_TOKEN") or "").strip() or None
    if check_access(args.model, token) != 0:
        return 3
    ignore = ignore_patterns_for(args.model)
    span = args.progress_end - args.progress_start
    total = expected_size(args.model, token, ignore)
    blobs = repo_cache_dir(args.model) / "blobs"
    baseline = dir_size(blobs)
    emit(args.progress_start, f"{args.label} ({args.model})")

    done = threading.Event()
    failure: list[BaseException] = []
    result: list[str] = []

    def worker() -> None:
        try:
            result.append(snapshot_download(args.model, token=token, ignore_patterns=ignore))
        except BaseException as exc:  # reported on the main thread
            failure.append(exc)
        finally:
            done.set()

    threading.Thread(target=worker, daemon=True).start()
    started = time.time()
    while not done.wait(2.0):
        current = dir_size(blobs)
        elapsed = int(time.time() - started)
        if total:
            frac = min(current / total, 0.999)
            emit(args.progress_start + span * frac, f"{args.label} {gb(current)} / {gb(total)} GB")
        else:
            emit(args.progress_start, f"{args.label} {gb(max(0, current - baseline))} GB ({elapsed}s)")

    if failure:
        exc = failure[0]
        if isinstance(exc, (GatedRepoError, RepositoryNotFoundError)) or (
            isinstance(exc, HfHubHTTPError) and getattr(exc.response, "status_code", 0) in (401, 403)
        ):
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
        print(f"ERROR: download failed: {exc}", file=sys.stderr, flush=True)
        return 4

    emit(args.progress_end, f"{args.label} done")
    print(f"NAVO_MODEL_PATH {result[0]}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
