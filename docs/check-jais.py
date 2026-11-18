#!/usr/bin/env python3
"""Checks Jais-ASR in a running Navo engine, end to end, through the API. Standard library only.

    python3 check-jais.py                      # the engine on this Mac (Navo running)
    python3 check-jais.py --compare            # also the other engines that are on, side by side
    python3 check-jais.py --url http://127.0.0.1:7861 --samples docs/audio --markdown report.md

On a Mac with Navo, the one line that runs it with Navo's own Python:

    curl -fsSL https://devehab.github.io/STT-NAVO/check-jais.sh | bash

What it checks:
 1. The engine answers, knows Jais-ASR, has Jais-ASR support (mlx-vlm with IFM's patch) and the model.
 2. Jais loads, and how long that takes and how much memory it uses.
 3. Four short recordings with known text (two Levantine Arabic with English words in them, two
    English) through /jais/v1/audio/transcriptions: word and character error rates, no dialect tag
    left in the text, English words in English letters, time per recording.
 4. Language detection (auto), silence (no invented text), the OpenAI-style route with model=jais
    and plain-text answers, and a language Jais does not take (refused with 400).
Exit code: 0 everything passed, 1 something failed, 2 the engine or Jais is not ready to check.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import struct
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path

SAMPLES_URL = "https://devehab.github.io/STT-NAVO/audio/"
# The recordings on Navo's website, with what is said in them.
SAMPLES = [
    ("ar-samer.mp3", "ar", "مرحبا سامر، خلصت مراجعة العرض وبعتلك الملاحظات على الإيميل."),
    ("ar-build.mp3", "ar", "يا شباب، الـ build الجديد جاهز على الـ staging، جربوه قبل ما نعمل release."),
    ("en-sara.mp3", "en", "Hi Sara, thanks for sending the draft. Could we move the pricing table up, right after the introduction?"),
    ("en-lake.mp3", "en", "Leave early on Saturday, stop at the lake for breakfast, then take the coast road."),
]
# Most errors allowed on these clean recordings: characters for Arabic (spelling of dialect words
# varies), words for English.
MAX_ARABIC_CER = 0.20
MAX_ENGLISH_WER = 0.20


# ---------------------------------------------------------------- HTTP

def request(method: str, url: str, data: bytes | None = None, headers: dict | None = None, timeout: float = 900):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as err:
        return err.code, err.read(), err.headers.get("Content-Type", "") if err.headers else ""


def get_json(url: str, timeout: float = 30):
    status, body, _ = request("GET", url, timeout=timeout)
    return status, json.loads(body or b"{}")


def post_form(url: str, fields: dict, filename: str, audio: bytes, timeout: float = 900):
    boundary = f"navo-{uuid.uuid4().hex}"
    out = io.BytesIO()
    for name, value in fields.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    mime = "audio/mpeg" if filename.endswith(".mp3") else "audio/wav"
    out.write(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n".encode()
    )
    out.write(audio)
    out.write(f"\r\n--{boundary}--\r\n".encode())
    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    started = time.time()
    status, body, ctype = request("POST", url, out.getvalue(), headers, timeout)
    seconds = time.time() - started
    if "json" in ctype:
        try:
            return status, json.loads(body), seconds
        except ValueError:
            pass
    return status, body.decode("utf-8", "replace"), seconds


# ---------------------------------------------------------------- scoring

_DIACRITICS = re.compile("[ؐ-ًؚ-ٰٟۖ-ۭ]")


def normalize(text: str) -> str:
    """Lower case, no punctuation or Arabic vowel marks, one spelling for alef, ya and ta marbuta."""
    t = unicodedata.normalize("NFKC", text or "").lower()
    t = _DIACRITICS.sub("", t).replace("ـ", "")  # tatweel: "الـ build"
    t = re.sub("[إأآٱ]", "ا", t).replace("ى", "ي").replace("ة", "ه").replace("ؤ", "و").replace("ئ", "ي")
    t = re.sub(r"[^\w\s]", " ", t)
    t = re.sub(r"(?<!\w)ال\s+", "ال", t)  # "ال build" and "البuild" are one word
    return re.sub(r"\s+", " ", t).strip()


def distance(a, b) -> int:
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def wer(ref: str, hyp: str) -> float:
    r, h = normalize(ref).split(), normalize(hyp).split()
    return distance(r, h) / max(1, len(r))


def cer(ref: str, hyp: str) -> float:
    r, h = normalize(ref).replace(" ", ""), normalize(hyp).replace(" ", "")
    return distance(r, h) / max(1, len(r))


def cell(text: str, limit: int = 160) -> str:
    """One table cell: one line, no column breaks, not too long."""
    text = re.sub(r"\s+", " ", (text or "").replace("|", "/")).strip()
    return text if len(text) <= limit else text[:limit] + "…"


def latin_words(text: str) -> set[str]:
    return {w.lower() for w in re.findall(r"[A-Za-z]{3,}", text or "")}


# ---------------------------------------------------------------- audio

def silence_wav(seconds: float = 3.0, rate: int = 16000) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(seconds * rate))
    return out.getvalue()


def load_sample(name: str, folder: Path | None) -> bytes:
    if folder and (folder / name).exists():
        return (folder / name).read_bytes()
    status, body, _ = request("GET", SAMPLES_URL + name, timeout=60)
    if status != 200:
        raise RuntimeError(f"could not download the sample {name} from {SAMPLES_URL} (HTTP {status})")
    return body


def rss_mb(pid) -> float | None:
    """The process's memory in MB: its footprint (GPU memory included, what Activity Monitor
    shows), else its resident size (which leaves out the model's GPU memory)."""
    if not pid:
        return None
    try:
        out = subprocess.run(["/usr/bin/footprint", str(int(pid))], capture_output=True, text=True, timeout=30)
        found = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", out.stdout)
        if found:
            value, unit = float(found.group(1)), found.group(2)
            return round(value / 1024 if unit == "KB" else value * 1024 if unit == "GB" else value, 0)
    except Exception:
        pass
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(int(pid))], capture_output=True, text=True, timeout=5)
        return round(int(out.stdout.strip()) / 1024, 0)
    except Exception:
        return None


# ---------------------------------------------------------------- the check

class Report:
    def __init__(self):
        self.lines: list[str] = []
        self.failures: list[str] = []

    def say(self, text: str = "") -> None:
        print(text, flush=True)
        self.lines.append(text)

    def check(self, ok: bool, what: str, detail: str = "") -> bool:
        mark = "PASS" if ok else "FAIL"
        self.say(f"- {mark}  {what}" + (f": {detail}" if detail else ""))
        if not ok:
            self.failures.append(what + (f" ({detail})" if detail else ""))
        return ok


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("NAVO_URL", "http://127.0.0.1:7861"))
    parser.add_argument("--engine", default="jais", help="engine id to check (default: jais)")
    parser.add_argument("--samples", type=Path, default=None, help="folder with the sample recordings (default: download them)")
    parser.add_argument("--compare", action="store_true", help="also run the other engines that are on, side by side")
    parser.add_argument("--enable", action="store_true", help="turn Jais on in the engine if it is off")
    parser.add_argument("--markdown", type=Path, default=None, help="also write the report to this file")
    parser.add_argument("--json", type=Path, default=None, help="write the measurements as JSON")
    args = parser.parse_args(argv)
    base = args.url.rstrip("/")
    engine = args.engine
    folder = args.samples
    if folder is None:
        here = Path(__file__).resolve().parent / "audio"
        folder = here if here.exists() else None
    rep = Report()
    data: dict = {"engine": engine, "samples": []}

    rep.say(f"# Navo: checking {engine} at {base}")
    rep.say()
    # 1. The engine and Jais.
    try:
        status, health = get_json(f"{base}/health")
    except Exception as exc:
        rep.say(f"The Navo engine does not answer at {base} ({exc}). Open Navo and start the engine in Settings > Speech engines.")
        return 2
    entry = next((e for e in health.get("engines") or [] if e.get("id") == engine), None)
    rep.say(f"Engine {health.get('version')}, Jais-ASR support: {health.get('jais_runtime') or 'not added'}")
    data["engine_version"] = health.get("version")
    data["jais_runtime"] = health.get("jais_runtime")
    if entry is None:
        rep.say(f"This engine does not know '{engine}': update Navo to a version with Jais-ASR (0.23 or newer).")
        return 2
    if not entry.get("downloaded"):
        rep.say("Jais-ASR is not downloaded yet: Navo > Settings > Speech engines > Download next to Jais-ASR.")
        return 2
    if engine == "jais" and not health.get("jais_runtime"):
        rep.say("Jais-ASR support is missing: Navo > Settings > Speech engines > Add Jais support.")
        return 2
    if entry.get("status") == "off":
        if not args.enable:
            rep.say("Jais-ASR is off. Turn it on in Navo > Settings > Speech engines, or run this again with --enable.")
            return 2
        status, body, _ = request("POST", f"{base}/v1/engines/{engine}/enable")
        if status != 200:
            rep.say(f"Could not turn Jais-ASR on (HTTP {status}): {body.decode('utf-8', 'replace')}")
            return 2

    rep.say()
    rep.say("## Loading")
    started = time.time()
    status, body, _ = request("POST", f"{base}/v1/engines/{engine}/load", timeout=120)
    info: dict = {}
    # The load is queued: wait until the model is in memory (or failed).
    while status == 200 and time.time() - started < 1800:
        try:
            _, info = get_json(f"{base}/{engine}/health")
        except Exception:
            info = {}
        if info.get("status") in ("ready", "error"):
            break
        time.sleep(1)
    load_wall = time.time() - started
    rep.check(status == 200 and info.get("status") == "ready", "Jais-ASR loads",
              f"{info.get('status')}, {load_wall:.1f} s" + (f", {info.get('error')}" if info.get("error") else ""))
    if info.get("status") != "ready":
        rep.say(body.decode("utf-8", "replace")[:600])
        return 1
    _, health = get_json(f"{base}/health")
    memory = rss_mb(health.get("worker_pid"))
    model_gb = (info.get("model_bytes") or 0) / 1e9
    rep.say(f"- Model: {info.get('model')}, {model_gb:.2f} GB on disk, on {info.get('device')}")
    if memory:
        rep.say(f"- Memory of the models process: {memory / 1024:.1f} GB")
    data.update(load_seconds=round(load_wall, 1), model=info.get("model"), model_gb=round(model_gb, 2),
                device=info.get("device"), memory_mb=memory)

    # 3. The recordings.
    rep.say()
    rep.say("## Recordings")
    rep.say()
    rep.say("| Recording | Language | Expected | Jais-ASR | WER | CER | Seconds |")
    rep.say("| --- | --- | --- | --- | ---: | ---: | ---: |")
    results = []
    for name, language, expected in SAMPLES:
        audio = load_sample(name, folder)
        status, answer, seconds = post_form(f"{base}/{engine}/v1/audio/transcriptions", {"language": language}, name, audio)
        text = answer.get("text", "") if isinstance(answer, dict) else ""
        row = {"sample": name, "language": language, "expected": expected, "text": text, "status": status,
               "wer": round(wer(expected, text), 3), "cer": round(cer(expected, text), 3), "seconds": round(seconds, 2),
               "duration": answer.get("duration") if isinstance(answer, dict) else None}
        results.append(row)
        rep.say(f"| {name} | {language} | {expected} | {cell(text) or '(empty)'} | {row['wer']:.0%} | {row['cer']:.0%} | {seconds:.1f} |")
    data["samples"] = results
    rep.say()
    for row in results:
        name, language = row["sample"], row["language"]
        if row["status"] != 200:
            rep.check(False, f"{name} is transcribed", f"HTTP {row['status']}")
            continue
        if language == "ar":
            rep.check(row["cer"] <= MAX_ARABIC_CER, f"{name}: Arabic character error rate", f"{row['cer']:.0%} (at most {MAX_ARABIC_CER:.0%})")
        else:
            rep.check(row["wer"] <= MAX_ENGLISH_WER, f"{name}: English word error rate", f"{row['wer']:.0%} (at most {MAX_ENGLISH_WER:.0%})")
        rep.check(not re.match(r"\s*\[", row["text"]) and "<|ifm" not in row["text"] and "[IFM" not in row["text"],
                  f"{name}: no dialect tag or model token in the text")
    build = next(r for r in results if r["sample"] == "ar-build.mp3")
    english = latin_words(build["text"]) & {"build", "staging", "release"}
    rep.check(len(english) >= 2, "English words inside Arabic stay in English letters (code-switching)",
              ", ".join(sorted(english)) or "none of build, staging, release")

    # 4. Detection, silence, the OpenAI route, a language it does not take.
    rep.say()
    rep.say("## API")
    for name, expected_language in (("en-lake.mp3", "en"), ("ar-samer.mp3", "ar")):
        status, answer, _ = post_form(f"{base}/{engine}/v1/audio/transcriptions", {"language": "auto"}, name, load_sample(name, folder))
        text = answer.get("text", "") if isinstance(answer, dict) else ""
        ref = next(s[2] for s in SAMPLES if s[0] == name)
        score = wer(ref, text) if expected_language == "en" else cer(ref, text)
        rep.check(status == 200 and score <= 0.25, f"language=auto on {name}", f"{score:.0%} errors: {cell(text, 80)}")
    status, answer, _ = post_form(f"{base}/{engine}/v1/audio/transcriptions", {"language": "ar"}, "silence.wav", silence_wav())
    text = answer.get("text", None) if isinstance(answer, dict) else None
    rep.check(status == 200 and text == "", "3 seconds of silence give no text", repr(text))
    status, answer, _ = post_form(f"{base}/v1/audio/transcriptions",
                                  {"model": engine, "language": "ar", "response_format": "text"},
                                  "ar-samer.mp3", load_sample("ar-samer.mp3", folder))
    rep.check(status == 200 and isinstance(answer, str) and cer(SAMPLES[0][2], answer) <= MAX_ARABIC_CER,
              f"OpenAI route /v1/audio/transcriptions with model={engine}, plain text", cell(answer if isinstance(answer, str) else str(answer), 80))
    status, answer, _ = post_form(f"{base}/{engine}/v1/audio/transcriptions", {"language": "de"}, "silence.wav", silence_wav(1))
    rep.check(status == 400, "a language Jais does not take is refused", f"HTTP {status}")
    _, info = get_json(f"{base}/{engine}/health")
    rep.check(info.get("status") == "ready" and not info.get("error"), "Jais-ASR is still ready after the checks", info.get("status") or "")

    # Side by side with the other engines that are on.
    if args.compare:
        rep.say()
        rep.say("## Side by side (the engines that are on)")
        rep.say()
        compare = {}
        for name, language, expected in SAMPLES:
            status, answer, _ = post_form(f"{base}/v1/audio/compare", {"language": language}, name, load_sample(name, folder))
            if status != 200 or not isinstance(answer, dict):
                rep.say(f"- {name}: compare failed (HTTP {status})")
                continue
            for item in answer.get("results") or []:
                eid = item.get("engine")
                if item.get("text") is None:
                    continue
                score = cer(expected, item["text"]) if language == "ar" else wer(expected, item["text"])
                compare.setdefault(eid, []).append(score)
                rep.say(f"- {name} {eid}: {score:.0%} ({'CER' if language == 'ar' else 'WER'}) {cell(item['text'], 90)}")
        for eid, scores in compare.items():
            rep.say(f"- **{eid}**: average {sum(scores) / len(scores):.1%} errors on {len(scores)} recordings")
        data["compare"] = compare

    rep.say()
    if rep.failures:
        rep.say(f"**{len(rep.failures)} check(s) failed:** " + "; ".join(rep.failures))
    else:
        rep.say("**Every check passed.** Jais-ASR works in this Navo engine.")
    data["failures"] = rep.failures
    if args.markdown:
        args.markdown.write_text("\n".join(rep.lines) + "\n", encoding="utf-8")
    if args.json:
        args.json.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    return 1 if rep.failures else 0


if __name__ == "__main__":
    sys.exit(main())
