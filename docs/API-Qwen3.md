# Qwen3-ASR 1.7B engine

Speech to text with **Qwen3-ASR 1.7B** (`mlx-community/Qwen3-ASR-1.7B-bf16`), running on your Mac inside the Navo engine. Audio never leaves the Mac.

For what the engines share (running the engine, turning engines on and off, the limit of two engines on at once, comparing them, the cleanup LLM, using the engine from agents) see [API.md](API.md). The other engines are documented in [API-Cohere.md](API-Cohere.md), [API-Audar.md](API-Audar.md) and [API-Whisper.md](API-Whisper.md).

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:7861/qwen3` |
| OpenAI SDK `base_url` | `http://127.0.0.1:7861/qwen3/v1` |
| Transcription endpoint | `POST http://127.0.0.1:7861/qwen3/v1/audio/transcriptions` |
| Engine status | `GET http://127.0.0.1:7861/qwen3/health` |
| Engine id | `qwen3` |
| Runs on | Apple GPU through MLX (mlx-audio's Qwen3-ASR port, the same one Audar uses) |
| Languages | `auto` and 30 languages, see [Languages](API.md#languages). Strongest in English and Chinese |
| Authentication | None. The engine listens on 127.0.0.1 only |

## The model

| | |
| --- | --- |
| Hugging Face | [mlx-community/Qwen3-ASR-1.7B-bf16](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-bf16), converted for MLX from [Qwen/Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) |
| Architecture | Qwen3-ASR (audio encoder plus Qwen3 decoder) from Alibaba's Qwen team. Audar ASR V1 Turbo is a fine-tune of the same design |
| Weights used | BF16 `model.safetensors`, about 4.1 GB. 16 bit, the precision the model was published in: there is no FP16 build for MLX, and BF16 is the same size and the reference quality |
| Access | **Public**, no Hugging Face token needed |
| License | Apache 2.0 |
| Languages | 30 languages, and 22 Chinese dialects (send `zh` for those). It can also name the language itself |
| Memory | About 4.1 GB while it is loaded, none while it is asleep. It leaves memory after the idle time, 10 minutes by default |
| Download | In Navo > Settings > Speech engines, **Download** next to Qwen3 |

## How Navo runs it

- **Language.** With a language code the decoder is started with `language French<asr_text>` (the model's own name for it), so the model never guesses the language. With `auto` nothing is set and the model names the language itself; Navo removes that label from the text.
- **Pieces of up to 28 seconds.** Audio longer than 28 seconds is cut into pieces of at most 28 seconds, each cut inside a pause (see [How long audio is cut](API.md#how-long-audio-is-cut)), each piece is transcribed, and the texts are joined with a space. Short pieces keep memory use and decoding time even, as with Audar.
- **Greedy decoding, 256 tokens per piece.** Deterministic output, and a hard stop if the model starts repeating itself.
- **Non-speech.** Pieces with no sound at all are not sent to the model. A piece the model marks as `language None` (music, noise) adds nothing to the transcript, and a phrase repeated ten or more times in a row is collapsed to one.
- **Output layer.** This model's output layer is tied to its embeddings, which is what mlx-audio expects, so it loads as published (Audar needs its own layer restored; this one does not).

## Before you call it

The engine must be **on**, and **at most two engines are on at once**. After you download Qwen3, Navo turns it on if there is room; otherwise turn off one of the two engines that are on first (see [Two engines at a time](API.md#two-engines-at-a-time)). It does not have to be loaded: an engine that is asleep loads for the request. Check it:

```bash
curl -s http://127.0.0.1:7861/qwen3/health
```

```json
{
  "id": "qwen3",
  "name": "Qwen3-ASR 1.7B",
  "model": "mlx-community/Qwen3-ASR-1.7B-bf16",
  "languages": ["ar", "en", "auto", "zh", "yue", "de", "..."],
  "status": "ready",
  "downloaded": true,
  "backend": "mlx",
  "device": "Apple GPU (MLX)",
  "error": null,
  "load_seconds": 4.2,
  "model_path": "/Users/you/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/...",
  "model_bytes": 4080000000,
  "transcriptions": 5,
  "last_processing_ms": 910,
  "default": false
}
```

The values are illustrative and `languages` is shortened. `status` is one of:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `ready` | Loaded, requests are answered | Send audio |
| `loading` | Loading into memory, a few seconds | Poll `/qwen3/health` every second |
| `asleep` | On, but out of memory after being idle | Send audio anyway: it loads first, so that request takes a few seconds more |
| `off` | Turned off, it never loads | Turn it on in Navo > Settings > Speech engines, or `curl -X POST http://127.0.0.1:7861/v1/engines/qwen3/enable` (`409` while two others are on) |
| `error` | Loading failed. `error` says why, and `downloaded: false` means the model is not on this Mac yet | Download it in Settings, or read `~/Library/Application Support/Navo/Logs/engine.log` |

## POST /qwen3/v1/audio/transcriptions

Send one audio file as `multipart/form-data`. The response is the transcript. The request and response have the same shape as the other engines, so a client written for one works with another by changing the URL.

### Request fields

| Field | Required | Default | Values |
| --- | --- | --- | --- |
| `file` | yes | | The audio file |
| `language` | no | `ar` | `auto`, or one of: `ar`, `en`, `zh`, `yue`, `de`, `fr`, `es`, `pt`, `id`, `it`, `ko`, `ru`, `th`, `vi`, `ja`, `tr`, `hi`, `ms`, `nl`, `sv`, `da`, `fi`, `pl`, `cs`, `fil`, `fa`, `el`, `hu`, `mk`, `ro`. Regional codes such as `en-US` (and `zh-HK` for Cantonese) and names such as `english` work too |
| `response_format` | no | `json` | `json` or `text` |
| `model` | no | | Accepted for OpenAI compatibility and ignored: the URL already picks this engine |

The default is `ar` for every engine, so **send `language=en` for English** (or `auto`). Naming the language is faster and more reliable than `auto` on short or mixed audio.

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
  "text": "Let's move the launch to Thursday and send the draft to the team tonight.",
  "language": "en",
  "duration": 4.92,
  "engine": "qwen3",
  "model": "mlx-community/Qwen3-ASR-1.7B-bf16",
  "backend": "mlx",
  "processing_ms": 910
}
```

| Field | Meaning |
| --- | --- |
| `text` | The transcript. Empty when the audio holds no speech. It is the recognizer output before any LLM cleanup |
| `language` | The language code that was asked for (`auto` stays `auto`) |
| `duration` | Audio length in seconds |
| `engine` | Always `qwen3` here |
| `model`, `backend` | Model id, and `mlx` |
| `processing_ms` | Time spent on this request, queue wait included |

### Response: `response_format=text`

`Content-Type: text/plain`, the transcript only.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | A `language` Qwen3-ASR does not take (for example `sw`, which Whisper takes), or an empty file |
| `413` | File larger than 200 MB |
| `415` | The file is not audio the engine can read. `detail` lists the supported formats |
| `422` | The `file` field is missing |
| `503` | The engine is off or failed to load. `detail` says which and how to fix it. A sleeping engine does not return `503`: it loads and answers |
| `500` | Unexpected failure during transcription. See `~/Library/Application Support/Navo/Logs/engine.log` |

## Examples

**curl**

```bash
curl -s -F file=@meeting.mp3 -F language=en http://127.0.0.1:7861/qwen3/v1/audio/transcriptions

# Language detected, plain text
curl -s -F file=@note.wav -F language=auto -F response_format=text \
  http://127.0.0.1:7861/qwen3/v1/audio/transcriptions
```

**Python (standard library)**: [`examples/api/transcribe.py`](../examples/api/transcribe.py)

```bash
python3 examples/api/transcribe.py interview.wav --engine qwen3 --language fr
```

```python
from transcribe import transcribe

result = transcribe("interview.wav", language="fr", engine="qwen3")
print(result["text"], result["processing_ms"])
```

**Python (requests)**

```python
import requests

with open("meeting.mp3", "rb") as audio:
    r = requests.post(
        "http://127.0.0.1:7861/qwen3/v1/audio/transcriptions",
        files={"file": audio},
        data={"language": "en"},
        timeout=600,
    )
r.raise_for_status()
print(r.json()["text"])
```

**JavaScript (Node 18+ or the browser)**: [`examples/api/transcribe.mjs`](../examples/api/transcribe.mjs)

```bash
node examples/api/transcribe.mjs talk.wav auto qwen3
```

```js
const form = new FormData();
form.append("language", "auto");
form.append("file", audioBlob, "talk.wav");
const res = await fetch("http://127.0.0.1:7861/qwen3/v1/audio/transcriptions", { method: "POST", body: form });
const { text } = await res.json();
```

**OpenAI SDK**: [`examples/api/openai_client.py`](../examples/api/openai_client.py)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:7861/qwen3/v1", api_key="local")
with open("meeting.mp3", "rb") as audio:
    print(client.audio.transcriptions.create(model="qwen3", file=audio, language="en").text)
```

## Older URL

`POST http://127.0.0.1:7861/v1/audio/transcriptions` with `model=qwen3` (or `qwen3-asr`, `qwen3-asr-1.7b`, or `mlx-community/Qwen3-ASR-1.7B-bf16`) also reaches this engine. Without a recognized `model` it goes to the engine Navo uses for dictation.
