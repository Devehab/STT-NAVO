# Jais-ASR engine

Speech to text with **Jais-ASR** (`IFM/Jais-ASR-MLX-8bit`), IFM's model for Arabic as it is spoken: Modern Standard Arabic and the dialects of 19 Arab countries, Levantine included, with English, French, Spanish and Italian mixed in. It runs on your Mac inside the Navo engine. Audio never leaves the Mac.

For what the engines share (running the engine, turning engines on and off, the limit of two engines on at once, comparing them, the cleanup LLM, using the engine from agents) see [API.md](API.md). The other engines are documented in [API-Cohere.md](API-Cohere.md), [API-Audar.md](API-Audar.md), [API-Whisper.md](API-Whisper.md) and [API-Qwen3.md](API-Qwen3.md).

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:7861/jais` |
| OpenAI SDK `base_url` | `http://127.0.0.1:7861/jais/v1` |
| Transcription endpoint | `POST http://127.0.0.1:7861/jais/v1/audio/transcriptions` |
| Engine status | `GET http://127.0.0.1:7861/jais/health` |
| Engine id | `jais` |
| Runs on | Apple GPU through MLX (mlx-vlm with IFM's Jais-ASR patch, which Navo adds to the engine when Jais is downloaded) |
| Languages | `ar`, `en`, `fr`, `es`, `it` and `auto`, see [Languages](API.md#languages). Strongest in Arabic dialects |
| Authentication | None. The engine listens on 127.0.0.1 only |

## The model

| | |
| --- | --- |
| Hugging Face | [IFM/Jais-ASR-MLX-8bit](https://huggingface.co/IFM/Jais-ASR-MLX-8bit), IFM's MLX build of [IFM/Jais-ASR](https://huggingface.co/IFM/Jais-ASR) |
| Architecture | Qwen3-Omni's audio encoder, a projector and a Jais-3 (K2-Horizon) decoder, 5.7B parameters |
| Weights used | 8-bit decoder, full-precision audio encoder, about 7 GB. The most accurate of IFM's Mac builds: on the Open Universal Arabic ASR leaderboard's six test sets it scores 22.76% WER and 8.30% CER, a hair better than the full-size model (22.85%, 11.5 GB) and the 4-bit build (22.94%, 4.5 GB) |
| Access | **Public**, no Hugging Face token needed |
| License | Apache 2.0 |
| Languages | MSA and the dialects of 19 countries (EG, SA, MA, IQ, JO, SY, QA, DZ, LB, OM, YE, TN, MR, KW, SD, LY, AE, PS, BH), English, French, Spanish and Italian. It names the dialect itself |
| Memory | About 8 GB while it is loaded, none while it is asleep. It leaves memory after the idle time, 10 minutes by default. Best on a Mac with 16 GB or more |
| Download | In Navo > Settings > Speech engines, **Download** next to Jais-ASR. Navo first adds mlx-vlm with IFM's Jais-ASR patch to the engine (about 30 MB, once), then downloads the model |

## How Navo runs it

- **Language.** `ar` holds the model to Arabic and lets it choose the dialect (all 20 Arabic tags stay allowed); `en`, `fr`, `es` and `it` hold it to that language. This is IFM's language pin: it only restricts which language tag the model writes, so the model can still say there is no speech. With `auto` nothing is pinned.
- **English stays in English letters.** Navo asks for code-switching (`[Code-switch]`), so English, French, Spanish and Italian words are written as spoken, in their own script, next to the Arabic ("بدي اعمل deploy عالـ server") instead of in Arabic letters.
- **The dialect tag is removed.** Every answer starts with a tag such as `[SY]` or `[msa]`; Navo keeps only the text. When the model answers `[IFM-NoTranscript]` (no speech it can transcribe), the piece adds nothing.
- **Pieces of up to 28 seconds.** The model takes up to 5 minutes at once, but its published scores are on short pieces and a long piece needs a long answer in one go. Audio longer than 28 seconds is cut into pieces of at most 28 seconds, each cut inside a pause (see [How long audio is cut](API.md#how-long-audio-is-cut)), and the texts are joined with a space.
- **Greedy decoding, the model card's settings.** Temperature 0, repetition penalty 1.05, up to 320 tokens per piece. Deterministic output, and a phrase repeated ten or more times in a row is collapsed to one.

## Before you call it

The engine must be **on**, and **at most two engines are on at once**. After you download Jais-ASR, Navo turns it on if there is room; otherwise turn off one of the two engines that are on first (see [Two engines at a time](API.md#two-engines-at-a-time)). It does not have to be loaded: an engine that is asleep loads for the request. Check it:

```bash
curl -s http://127.0.0.1:7861/jais/health
```

```json
{
  "id": "jais",
  "name": "Jais-ASR",
  "model": "IFM/Jais-ASR-MLX-8bit",
  "languages": ["ar", "en", "auto", "fr", "es", "it"],
  "status": "ready",
  "downloaded": true,
  "backend": "mlx",
  "device": "Apple GPU (MLX)",
  "error": null,
  "load_seconds": 9.5,
  "model_path": "/Users/you/.cache/huggingface/hub/models--IFM--Jais-ASR-MLX-8bit/snapshots/...",
  "model_bytes": 7030000000,
  "transcriptions": 5,
  "last_processing_ms": 910,
  "default": false
}
```

The values are illustrative. `status` is one of:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `ready` | Loaded, requests are answered | Send audio |
| `loading` | Loading into memory, a few seconds | Poll `/jais/health` every second |
| `asleep` | On, but out of memory after being idle | Send audio anyway: it loads first, so that request takes a few seconds more |
| `off` | Turned off, it never loads | Turn it on in Navo > Settings > Speech engines, or `curl -X POST http://127.0.0.1:7861/v1/engines/jais/enable` (`409` while two others are on) |
| `error` | Loading failed. `error` says why, and `downloaded: false` means the model is not on this Mac yet | Download it in Settings, or read `~/Library/Application Support/Navo/Logs/engine.log` |

## POST /jais/v1/audio/transcriptions

Send one audio file as `multipart/form-data`. The response is the transcript. The request and response have the same shape as the other engines, so a client written for one works with another by changing the URL.

### Request fields

| Field | Required | Default | Values |
| --- | --- | --- | --- |
| `file` | yes | | The audio file |
| `language` | no | `ar` | `ar` (any Arabic dialect, the model picks it), `en`, `fr`, `es`, `it` or `auto`. Regional codes such as `ar-SA` and names such as `arabic` work too |
| `response_format` | no | `json` | `json` or `text` |
| `model` | no | | Accepted for OpenAI compatibility and ignored: the URL already picks this engine |

The default is `ar` for every engine, so **send `language=en` for English** (or `auto`). For Arabic mixed with English send `ar`: the English words stay in English letters either way.

### Audio

| | |
| --- | --- |
| Formats | WAV, FLAC, MP3, OGG (Vorbis or Opus), AIFF, CAF |
| Not supported | M4A/AAC, WebM, MP4 video. Convert first: `ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav` |
| Sample rate and channels | Any. Audio is resampled to 16 kHz and stereo is mixed to mono automatically |
| Length | No fixed limit. Audio longer than 28 seconds is cut inside pauses into pieces of up to 28 seconds, processed one after the other |
| Size | Up to 200 MB per request |
| Best input | 16 kHz mono WAV, which is what Navo itself sends |

There are no timestamps or speaker labels in the response.

### Response: `response_format=json` (default)

```json
{
  "text": "خلينا نأجل الإطلاق لـ Thursday ونبعت الـ draft للفريق الليلة",
  "language": "ar",
  "duration": 4.92,
  "engine": "jais",
  "model": "IFM/Jais-ASR-MLX-8bit",
  "backend": "mlx",
  "processing_ms": 1650
}
```

| Field | Meaning |
| --- | --- |
| `text` | The transcript, without the dialect tag. Empty when the audio holds no speech. It is the recognizer output before any LLM cleanup |
| `language` | The language code that was asked for (`auto` stays `auto`) |
| `duration` | Audio length in seconds |
| `engine` | Always `jais` here |
| `model`, `backend` | Model id, and `mlx` |
| `processing_ms` | Time spent on this request, queue wait included |

### Response: `response_format=text`

`Content-Type: text/plain`, the transcript only.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | A `language` Jais-ASR does not take (for example `de`, which Whisper and Qwen3 take), or an empty file |
| `413` | File larger than 200 MB |
| `415` | The file is not audio the engine can read. `detail` lists the supported formats |
| `422` | The `file` field is missing |
| `503` | The engine is off or failed to load. `detail` says which and how to fix it (for example "Jais-ASR support is missing": click **Add Jais support** next to Jais-ASR in Settings). A sleeping engine does not return `503`: it loads and answers |
| `500` | Unexpected failure during transcription. See `~/Library/Application Support/Navo/Logs/engine.log` |

## Examples

**curl**

```bash
curl -s -F file=@meeting.mp3 -F language=ar http://127.0.0.1:7861/jais/v1/audio/transcriptions

# Language detected, plain text
curl -s -F file=@note.wav -F language=auto -F response_format=text \
  http://127.0.0.1:7861/jais/v1/audio/transcriptions
```

**Python (standard library)**: [`examples/api/transcribe.py`](../examples/api/transcribe.py)

```bash
python3 examples/api/transcribe.py interview.wav --engine jais --language ar
```

```python
from transcribe import transcribe

result = transcribe("interview.wav", language="ar", engine="jais")
print(result["text"], result["processing_ms"])
```

**Python (requests)**

```python
import requests

with open("meeting.mp3", "rb") as audio:
    r = requests.post(
        "http://127.0.0.1:7861/jais/v1/audio/transcriptions",
        files={"file": audio},
        data={"language": "ar"},
        timeout=600,
    )
r.raise_for_status()
print(r.json()["text"])
```

**JavaScript (Node 18+ or the browser)**: [`examples/api/transcribe.mjs`](../examples/api/transcribe.mjs)

```bash
node examples/api/transcribe.mjs talk.wav ar jais
```

```js
const form = new FormData();
form.append("language", "ar");
form.append("file", audioBlob, "talk.wav");
const res = await fetch("http://127.0.0.1:7861/jais/v1/audio/transcriptions", { method: "POST", body: form });
const { text } = await res.json();
```

**OpenAI SDK**: [`examples/api/openai_client.py`](../examples/api/openai_client.py)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:7861/jais/v1", api_key="local")
with open("meeting.mp3", "rb") as audio:
    print(client.audio.transcriptions.create(model="jais", file=audio, language="ar").text)
```

## Older URL

`POST http://127.0.0.1:7861/v1/audio/transcriptions` with `model=jais` (or `jais-asr`, `jais-asr-mlx-8bit`, or `IFM/Jais-ASR-MLX-8bit`) also reaches this engine. Without a recognized `model` it goes to the engine Navo uses for dictation.
