#!/usr/bin/env python3
"""Send one audio file to the speech engines that are on and print their transcripts side by side.
Standard library only.

    python3 compare.py recording.wav
    python3 compare.py meeting.mp3 --language en
    python3 compare.py note.wav --engines whisper,qwen3   # these two (turned off ones are reported)
    python3 compare.py note.wav --json                    # the full response
    python3 compare.py note.wav --separate                # one request per engine instead of /v1/audio/compare

At most two engines are on at once. An engine you name that is off is reported, not skipped silently.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from transcribe import post_form, transcribe


def engines_on(base_url: str = "http://127.0.0.1:7861") -> list[str]:
    """The engines that are on (asleep engines count: they load for the request)."""
    with urllib.request.urlopen(f"{base_url.rstrip('/')}/v1/engines", timeout=10) as response:
        return [e["id"] for e in json.load(response)["engines"] if e["status"] != "off"]


def compare(path: str, language: str = "ar", engines=None, base_url: str = "http://127.0.0.1:7861") -> dict:
    """One request: the engine decodes the audio once and runs each engine in turn.
    engines: ids to run, or None for every engine that is on.

    Returns {"language", "duration", "results": [{"engine", "name", "model", "backend", "text",
    "processing_ms", "error"}, ...]}.
    """
    fields = {"language": language}
    if engines:
        fields["engines"] = ",".join(engines)
    return post_form(f"{base_url.rstrip('/')}/v1/audio/compare", fields, path, timeout=1200)


def compare_separately(path: str, language: str = "ar", engines=None, base_url: str = "http://127.0.0.1:7861") -> dict:
    """Same result shape, built from one /{engine}/v1/audio/transcriptions request per engine."""
    results, duration = [], None
    for engine in engines or engines_on(base_url):
        started = time.perf_counter()
        try:
            body = transcribe(path, language, engine, base_url)
            duration = body.get("duration", duration)
            results.append({"engine": engine, "text": body["text"], "processing_ms": body["processing_ms"],
                            "backend": body.get("backend"), "model": body.get("model"), "error": None})
        except RuntimeError as error:
            results.append({"engine": engine, "text": None, "error": str(error),
                            "processing_ms": int((time.perf_counter() - started) * 1000)})
    return {"language": language, "duration": duration, "results": results}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("file")
    parser.add_argument("--language", default="ar", help="ar (default), en, or auto (engines without auto report an error)")
    parser.add_argument("--engines", default="", help="comma separated, default: every engine that is on")
    parser.add_argument("--url", default=os.environ.get("NAVO_URL", "http://127.0.0.1:7861"))
    parser.add_argument("--separate", action="store_true", help="one request per engine")
    parser.add_argument("--json", action="store_true", help="print the full JSON response")
    args = parser.parse_args()
    if not Path(args.file).is_file():
        print(f"error: file not found: {args.file}", file=sys.stderr)
        return 2
    engines = [e.strip() for e in args.engines.split(",") if e.strip()] or None
    run = compare_separately if args.separate else compare
    try:
        result = run(args.file, args.language, engines, args.url)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"error: cannot reach {args.url} ({error.reason}). Is Navo running?", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    print(f"{args.file}, {result.get('duration')} s, language {result.get('language')}\n")
    for entry in result["results"]:
        if entry.get("text") is None:
            print(f"[{entry['engine']}] not available: {entry.get('error')}\n")
            continue
        print(f"[{entry['engine']}] {(entry.get('processing_ms') or 0) / 1000:.1f} s")
        print(entry["text"] or "(no speech recognized)")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
