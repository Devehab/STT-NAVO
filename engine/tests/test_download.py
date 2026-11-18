"""Access diagnostics before downloading a gated model (network mocked)."""

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import huggingface_hub  # noqa: E402
from huggingface_hub import HfApi  # noqa: E402
from huggingface_hub.errors import GatedRepoError, HfHubHTTPError  # noqa: E402

from navo_engine.download import check_access  # noqa: E402

REPO = "CohereLabs/cohere-transcribe-arabic-07-2026"


def http_error(cls, status):
    response = SimpleNamespace(status_code=status, headers={}, url="https://huggingface.co", request=None, text="")
    try:
        return cls("boom", response=response)
    except TypeError:
        err = cls("boom")
        err.response = response
        return err


@pytest.fixture
def no_saved_login(monkeypatch):
    monkeypatch.setattr(huggingface_hub, "get_token", lambda: None)


def test_no_token_on_gated_repo(monkeypatch, no_saved_login, capsys):
    monkeypatch.setattr(HfApi, "auth_check", lambda self, repo, token=None: (_ for _ in ()).throw(http_error(GatedRepoError, 401)))
    assert check_access(REPO, None) == 3
    assert "no Hugging Face token" in capsys.readouterr().err


def test_bad_token(monkeypatch, no_saved_login, capsys):
    monkeypatch.setattr(HfApi, "whoami", lambda self, token=None: (_ for _ in ()).throw(http_error(HfHubHTTPError, 401)))
    assert check_access(REPO, "hf_bad") == 3
    assert "rejected" in capsys.readouterr().err


def test_terms_not_accepted(monkeypatch, no_saved_login, capsys):
    monkeypatch.setattr(HfApi, "whoami", lambda self, token=None: {"name": "ehab", "auth": {"accessToken": {"role": "read"}}})
    monkeypatch.setattr(HfApi, "auth_check", lambda self, repo, token=None: (_ for _ in ()).throw(http_error(GatedRepoError, 403)))
    assert check_access(REPO, "hf_ok") == 3
    out = capsys.readouterr()
    assert "Hugging Face account: ehab (token type: read)" in out.out
    assert "Account 'ehab' has not been given access" in out.err


def test_access_ok(monkeypatch, no_saved_login):
    monkeypatch.setattr(HfApi, "whoami", lambda self, token=None: {"name": "ehab"})
    monkeypatch.setattr(HfApi, "auth_check", lambda self, repo, token=None: None)
    assert check_access(REPO, "hf_ok") == 0


def test_masked_token_is_caught_locally(no_saved_login, capsys):
    assert check_access(REPO, "hf_abc•••••••••XYZ1") == 3
    out = capsys.readouterr()
    assert "Token received: hf_ab...XYZ1" in out.out
    assert "does not look like a full Hugging Face token" in out.err


def test_expected_size_skips_ignored_files(monkeypatch):
    from navo_engine.download import expected_size
    from navo_engine.engines import ignore_patterns_for

    files = {
        "config.json": 6_000,
        "model.safetensors": 4_698_521_568,
        "tokenizer.json": 11_000_000,
        "Audar-ASR-V1-Turbo.gguf": 4_069_674_848,
        "mmproj-Audar-ASR-V1-Turbo.gguf": 641_773_856,
        "vllm-w4a16/model.safetensors": 2_606_663_048,
        "vllm-w4a16/config.json": 7_193,
    }
    siblings = [SimpleNamespace(rfilename=name, size=size) for name, size in files.items()]
    monkeypatch.setattr(HfApi, "model_info", lambda self, repo, files_metadata=True, token=None: SimpleNamespace(siblings=siblings))
    total = expected_size("audarai/Audar-ASR-V1-Turbo", None, ignore_patterns_for("audarai/Audar-ASR-V1-Turbo"))
    assert total == 6_000 + 4_698_521_568 + 11_000_000


def test_a_download_that_does_not_fit_is_refused_before_it_starts():
    from navo_engine.download import SPARE_BYTES, space_problem

    gb = 1_000_000_000
    # Jais-ASR (7 GB) on a Mac with 3 GB free: refused, with the numbers.
    problem = space_problem(7 * gb, 0, 3 * gb)
    assert problem and "7.00 GB more" in problem and "3.00 GB free" in problem
    # Enough room, with 1 GB spare.
    assert space_problem(7 * gb, 0, 8 * gb + SPARE_BYTES) is None
    # A download that stopped halfway only needs the rest.
    assert space_problem(7 * gb, 5 * gb, 3 * gb + SPARE_BYTES) is None
    # Sizes unknown: no guess, the download is tried as before.
    assert space_problem(0, 0, 1) is None
    assert space_problem(7 * gb, 0, None) is None


def test_free_space_is_measured_on_the_nearest_folder_that_exists(tmp_path):
    from navo_engine.download import free_bytes

    assert free_bytes(tmp_path / "models--x--y" / "blobs") > 0


def test_a_failed_download_is_tried_again_through_the_other_route(monkeypatch, capsys):
    from huggingface_hub import constants

    from navo_engine import download

    routes, waits = [], []

    def fetch():
        routes.append("http" if constants.HF_HUB_DISABLE_XET else "xet")
        if len(routes) < 3:
            raise TimeoutError("The read operation timed out")
        return "/snapshot"

    result, error = download.fetch_with_retries(fetch, lambda: 0, lambda _: None, sleep=waits.append,
                                                poll=0.01, use_xet=True)
    assert (result, error) == ("/snapshot", None)
    assert routes == ["xet", "http", "xet"]
    assert waits == [10, 20]
    out = capsys.readouterr().out
    assert "Trying again in 10 s through plain HTTP, try 2 of 6" in out
    assert "the files that finished are kept" in out


def test_access_errors_are_not_tried_again():
    from huggingface_hub.errors import GatedRepoError

    from navo_engine import download

    calls = []

    def fetch():
        calls.append(1)
        raise http_error(GatedRepoError, 403)

    result, error = download.fetch_with_retries(fetch, lambda: 0, lambda _: None, sleep=lambda _: None,
                                                poll=0.01, use_xet=True)
    assert result is None and download.is_access_error(error) and len(calls) == 1


def test_it_gives_up_after_the_last_try():
    from navo_engine import download

    calls = []

    def fetch():
        calls.append(1)
        raise ConnectionError("no network")

    result, error = download.fetch_with_retries(fetch, lambda: 0, lambda _: None, attempts=3,
                                                sleep=lambda _: None, poll=0.01, use_xet=False)
    assert result is None and isinstance(error, ConnectionError) and len(calls) == 3


def test_a_stuck_download_is_stopped():
    import threading

    from navo_engine import download

    never = threading.Event()
    result, error = download.fetch_with_retries(lambda: never.wait(5), lambda: 123, lambda _: None,
                                                stall_seconds=0.2, sleep=lambda _: None, poll=0.05, use_xet=True)
    never.set()
    assert result is None and isinstance(error, TimeoutError) and "no data" in str(error)


def test_downloads_use_their_own_folder_and_wait_longer():
    from navo_engine import download  # noqa: F401  (sets the environment on import)
    import os

    assert os.environ["HF_HUB_DISABLE_SHARED_BLOBS"] == "1"
    assert int(os.environ["HF_HUB_DOWNLOAD_TIMEOUT"]) >= 60
