#!/usr/bin/env python3
"""Ask a local language model of the Navo engine (Gemma or Llama) to work on a text.
Standard library only. Nothing leaves this Mac.

    python3 chat.py "Summarize in three points." notes.txt
    python3 chat.py "Rewrite as a short, friendly email." notes.txt --model llama
    echo "بدي اشرح الفكرة بطريقة بسيطة" | python3 chat.py "Fix the punctuation only."
    python3 chat.py "Summarize." notes.txt --no-stream --json     # the full JSON response

The first argument is the system prompt (what to do), the file or standard input is the text
(what to do it on). The model is asleep until a request needs it: the first answer takes a
few seconds longer while it loads, and the speech models leave memory to make room.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Iterator

MODELS = ("gemma", "llama")


def request(base_url: str, model: str, body: dict, timeout: float) -> urllib.request.Request:
    return urllib.request.Request(
        f"{base_url.rstrip('/')}/{model}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )


def explain(error: urllib.error.HTTPError) -> RuntimeError:
    detail = error.read().decode("utf-8", "replace")
    try:
        detail = json.loads(detail).get("detail", detail)
    except ValueError:
        pass
    return RuntimeError(f"HTTP {error.code}: {detail}")


def chat(
    system: str,
    text: str,
    model: str = "gemma",
    base_url: str = "http://127.0.0.1:7861",
    temperature: float = 0.3,
    max_tokens: int = 1024,
    timeout: float = 600,
) -> dict:
    """One request, the whole answer at once. Returns the OpenAI style response:
    result["choices"][0]["message"]["content"] is the text, result["usage"] the token counts and
    result["navo"] the speed and the memory used."""
    body = {
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": text}],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }
    try:
        with urllib.request.urlopen(request(base_url, model, body, timeout), timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise explain(error) from None


def stream(
    system: str,
    text: str,
    model: str = "gemma",
    base_url: str = "http://127.0.0.1:7861",
    temperature: float = 0.3,
    max_tokens: int = 1024,
    timeout: float = 600,
) -> Iterator[str]:
    """The answer piece by piece, as the model writes it."""
    body = {
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": text}],
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": True,
    }
    try:
        with urllib.request.urlopen(request(base_url, model, body, timeout), timeout=timeout) as response:
            for raw in response:
                line = raw.decode("utf-8").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    return
                event = json.loads(payload)
                if "error" in event:
                    raise RuntimeError(event["error"].get("message", "the model stopped with an error"))
                piece = event["choices"][0]["delta"].get("content")
                if piece:
                    yield piece
    except urllib.error.HTTPError as error:
        raise explain(error) from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("system", help="the system prompt: what the model should do")
    parser.add_argument("file", nargs="?", help="a text file to work on (default: standard input)")
    parser.add_argument("--model", choices=MODELS, default="gemma")
    parser.add_argument("--temperature", type=float, default=0.3)
    parser.add_argument("--max-tokens", type=int, default=1024)
    parser.add_argument("--url", default=os.environ.get("NAVO_URL", "http://127.0.0.1:7861"))
    parser.add_argument("--no-stream", action="store_true", help="wait for the whole answer")
    parser.add_argument("--json", action="store_true", help="with --no-stream: print the full JSON response")
    args = parser.parse_args()
    if args.file:
        try:
            with open(args.file, encoding="utf-8") as handle:
                text = handle.read()
        except OSError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()
    if not text.strip():
        print("error: no text to work on", file=sys.stderr)
        return 2
    options = dict(model=args.model, base_url=args.url, temperature=args.temperature, max_tokens=args.max_tokens)
    try:
        if args.no_stream:
            result = chat(args.system, text, **options)
            print(json.dumps(result, ensure_ascii=False, indent=2) if args.json else result["choices"][0]["message"]["content"])
        else:
            for piece in stream(args.system, text, **options):
                print(piece, end="", flush=True)
            print()
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except urllib.error.URLError as error:
        print(f"error: cannot reach {args.url} ({error.reason}). Is Navo running?", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
