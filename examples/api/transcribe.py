#!/usr/bin/env python3
"""Transcribe an audio file with the local Navo engine. Standard library only.

    python3 transcribe.py recording.wav                   # the engine Navo uses for dictation
    python3 transcribe.py recording.wav --engine audar    # Audar ASR V1 Turbo
    python3 transcribe.py meeting.mp3 --engine whisper --language en --json
    python3 transcribe.py interview.wav --engine qwen3 --language fr
    NAVO_URL=http://127.0.0.1:7861 python3 transcribe.py note.ogg
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

ENGINES = ("cohere", "audar", "whisper", "qwen3")


def post_form(url: str, fields: dict, path: str, timeout: float = 600) -> dict:
    """POST multipart/form-data with text fields and one audio file, return the JSON reply."""
    file = Path(path)
    boundary = f"navo-{uuid.uuid4().hex}"
    mime = mimetypes.guess_type(file.name)[0] or "application/octet-stream"
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode()
        for name, value in fields.items()
    ]
    parts += [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file.name}\"\r\n"
        f"Content-Type: {mime}\r\n\r\n".encode(),
        file.read_bytes(),
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    request = urllib.request.Request(
        url,
        data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("detail", detail)
        except ValueError:
            pass
        raise RuntimeError(f"HTTP {error.code}: {detail}") from None


def transcribe(
    path: str,
    language: str = "ar",
    engine: str | None = None,
    base_url: str = "http://127.0.0.1:7861",
    timeout: float = 600,
) -> dict:
    """Returns {"text", "language", "duration", "engine", "model", "backend", "processing_ms"}.

    engine: "cohere", "audar", "whisper", "qwen3", or None for the engine Navo uses for dictation.
    language: "ar", "en", "auto" (not Cohere), or another code the engine lists in /v1/engines.
    """
    root = base_url.rstrip("/") + (f"/{engine}" if engine else "")
    return post_form(f"{root}/v1/audio/transcriptions", {"language": language}, path, timeout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--engine", choices=ENGINES, help="default: the engine Navo uses for dictation")
    parser.add_argument("--language", default="ar", help="ar (default), en, auto, or another code the engine takes")
    parser.add_argument("--url", default=os.environ.get("NAVO_URL", "http://127.0.0.1:7861"))
    parser.add_argument("--json", action="store_true", help="print the full JSON response")
    args = parser.parse_args()
    if not Path(args.file).is_file():
        print(f"error: file not found: {args.file}", file=sys.stderr)
        return 2
    try:
        result = transcribe(args.file, args.language, args.engine, args.url)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"error: cannot reach {args.url} ({error.reason}). Is Navo running?", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else result["text"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
