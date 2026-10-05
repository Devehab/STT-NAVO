# Whisper Large v3 Turbo engine

Speech to text with **Whisper Large v3 Turbo** (`mlx-community/whisper-large-v3-turbo-asr-fp16`), running on your Mac inside the Navo engine. Audio never leaves the Mac.

For what the engines share (running the engine, turning engines on and off, the limit of two engines on at once, comparing them, the cleanup LLM, using the engine from agents) see [API.md](API.md). The other engines are documented in [API-Cohere.md](API-Cohere.md), [API-Audar.md](API-Audar.md) and [API-Qwen3.md](API-Qwen3.md).

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:7861/whisper` |
| OpenAI SDK `base_url` | `http://127.0.0.1:7861/whisper/v1` |
| Transcription endpoint | `POST http://127.0.0.1:7861/whisper/v1/audio/transcriptions` |
| Engine status | `GET http://127.0.0.1:7861/whisper/health` |
| Engine id | `whisper` |
| Runs on | Apple GPU through MLX (mlx-audio's Whisper port) |
| Languages | `auto` and 100 languages, see [Languages](API.md#languages). Strongest in English |
| Authentication | None. The engine listens on 127.0.0.1 only |

## The model

| | |
| --- | --- |
| Hugging Face | [mlx-community/whisper-large-v3-turbo-asr-fp16](https://huggingface.co/mlx-community/whisper-large-v3-turbo-asr-fp16), converted for MLX from [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) |
| Architecture | OpenAI Whisper Large v3 with the decoder cut from 32 layers to 4 and trained again: much faster decoding, with a small loss in accuracy against Large v3 |
| Weights used | FP16 `model.safetensors`, about 1.6 GB, with the tokenizer files it needs |
| Access | **Public**, no Hugging Face token needed |
| License | MIT |
| Memory | About 1.6 GB while it is loaded, none while it is asleep. The smallest of Navo's engines |
| Download | In Navo > Settings > Speech engines, **Download** next to Whisper |

## How Navo runs it

- **Language.** With a language code (`en`, `ar`, `fr`...) Whisper is told the language and never guesses it. With `auto` it detects the language from the first seconds of each piece. Whisper writes Arabic mostly in Modern Standard spelling; for Arabic dialects, Audar or Cohere usually do better.
- **Transcribe only.** Whisper can also translate into English; Navo always asks it to transcribe, so the text stays in the language that was spoken.
- **30 second windows.** Whisper hears 30 seconds at a time. Audio longer than 28 seconds is cut into pieces of at most 28 seconds, each cut inside a pause (see [How long audio is cut](API.md#how-long-audio-is-cut)), so every piece is one window and no word is split. The texts are joined with a space.
- **Each piece stands alone.** The text of one piece is not fed into the next (`condition_on_previous_text` is off), so a mistake or a loop never carries over.
- **Decoding.** Greedy first. When a piece comes out repetitive or unsure, Whisper's own fallback tries again at higher temperatures (0.2 up to 1.0), as in OpenAI's reference implementation. No timestamps are produced.
- **Non-speech.** Pieces with no sound at all are never sent to the model, since silence is where Whisper invents text ("Thank you.", "Subtitles by..."). Whisper's own no-speech check drops a window it judges to hold no speech, and a phrase repeated ten or more times in a row is collapsed to one.

## Before you call it

The engine must be **on**, and **at most two engines are on at once**. After you download Whisper, Navo turns it on if there is room; otherwise turn off one of the two engines that are on first (see [Two engines at a time](API.md#two-engines-at-a-time)). It does not have to be loaded: an engine that is asleep loads for the request. Check it:

```bash
curl -s http://127.0.0.1:7861/whisper/health
```

```json
{
  "id": "whisper",
  "name": "Whisper Large v3 Turbo",
  "model": "mlx-community/whisper-large-v3-turbo-asr-fp16",
  "languages": ["ar", "en", "auto", "zh", "de", "es", "..."],
  "status": "ready",
  "downloaded": true,
  "backend": "mlx",
  "device": "Apple GPU (MLX)",
  "error": null,
  "load_seconds": 2.3,
  "model_path": "/Users/you/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo-asr-fp16/snapshots/...",
  "model_bytes": 1620000000,
  "transcriptions": 12,
  "last_processing_ms": 640,
  "default": false
}
```

The values are illustrative and `languages` is shortened. `status` is one of:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `ready` | Loaded, requests are answered | Send audio |
| `loading` | Loading into memory, a few seconds | Poll `/whisper/health` every second |
| `asleep` | On, but out of memory after being idle | Send audio anyway: it loads first, so that request takes a few seconds more |
| `off` | Turned off, it never loads | Turn it on in Navo > Settings > Speech engines, or `curl -X POST http://127.0.0.1:7861/v1/engines/whisper/enable` (`409` while two others are on) |
| `error` | Loading failed. `error` says why, and `downloaded: false` means the model is not on this Mac yet | Download it in Settings, or read `~/Library/Application Support/Navo/Logs/engine.log` |

## POST /whisper/v1/audio/transcriptions

Send one audio file as `multipart/form-data`. The response is the transcript. The request and response have the same shape as the other engines, so a client written for one works with another by changing the URL.

### Request fields

| Field | Required | Default | Values |
| --- | --- | --- | --- |
| `file` | yes | | The audio file |
| `language` | no | `ar` | `auto`, or one of Whisper's 100 language codes: `en`, `ar`, `fr`, `de`, `es`, `zh`, `ja`... (full list in [Languages](API.md#languages)). Regional codes such as `en-US` and names such as `english` work too |
| `response_format` | no | `json` | `json` or `text` |
| `model` | no | | Accepted for OpenAI compatibility and ignored: the URL already picks this engine |

The default is `ar` for every engine, so **send `language=en` for English** (or `auto`). Naming the language is faster and more reliable than `auto`, which can pick the wrong language on short or mixed audio.

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
  "engine": "whisper",
  "model": "mlx-community/whisper-large-v3-turbo-asr-fp16",
  "backend": "mlx",
  "processing_ms": 640
}
```

| Field | Meaning |
| --- | --- |
| `text` | The transcript. Empty when the audio holds no speech. It is the recognizer output before any LLM cleanup |
| `language` | The language code that was asked for (`auto` stays `auto`) |
| `duration` | Audio length in seconds |
| `engine` | Always `whisper` here |
| `model`, `backend` | Model id, and `mlx` |
| `processing_ms` | Time spent on this request, queue wait included |

### Response: `response_format=text`

`Content-Type: text/plain`, the transcript only.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | A `language` Whisper does not take, or an empty file |
| `413` | File larger than 200 MB |
| `415` | The file is not audio the engine can read. `detail` lists the supported formats |
| `422` | The `file` field is missing |
| `503` | The engine is off or failed to load. `detail` says which and how to fix it. A sleeping engine does not return `503`: it loads and answers |
| `500` | Unexpected failure during transcription. See `~/Library/Application Support/Navo/Logs/engine.log` |

## Examples

**curl**

```bash
curl -s -F file=@meeting.mp3 -F language=en http://127.0.0.1:7861/whisper/v1/audio/transcriptions

# Language detected, plain text
curl -s -F file=@note.wav -F language=auto -F response_format=text \
  http://127.0.0.1:7861/whisper/v1/audio/transcriptions
```

**Python (standard library)**: [`examples/api/transcribe.py`](../examples/api/transcribe.py)

```bash
python3 examples/api/transcribe.py meeting.mp3 --engine whisper --language en
```

```python
from transcribe import transcribe

result = transcribe("meeting.mp3", language="en", engine="whisper")
print(result["text"], result["processing_ms"])
```

**Python (requests)**

```python
import requests

with open("meeting.mp3", "rb") as audio:
    r = requests.post(
        "http://127.0.0.1:7861/whisper/v1/audio/transcriptions",
        files={"file": audio},
        data={"language": "en"},
        timeout=600,
    )
r.raise_for_status()
print(r.json()["text"])
```

**JavaScript (Node 18+ or the browser)**: [`examples/api/transcribe.mjs`](../examples/api/transcribe.mjs)

```bash
node examples/api/transcribe.mjs meeting.mp3 en whisper
```

```js
const form = new FormData();
form.append("language", "en");
form.append("file", audioBlob, "meeting.mp3");
const res = await fetch("http://127.0.0.1:7861/whisper/v1/audio/transcriptions", { method: "POST", body: form });
const { text } = await res.json();
```

**OpenAI SDK**: [`examples/api/openai_client.py`](../examples/api/openai_client.py)

Most tools built for OpenAI's Whisper API work by changing only the base URL:

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:7861/whisper/v1", api_key="local")
with open("meeting.mp3", "rb") as audio:
    print(client.audio.transcriptions.create(model="whisper-1", file=audio, language="en").text)
```

With this base URL the `model` value is ignored, so `whisper-1` is fine.

## Older URL

`POST http://127.0.0.1:7861/v1/audio/transcriptions` with `model=whisper` (or `whisper-large-v3-turbo`, `whisper-turbo`, or `mlx-community/whisper-large-v3-turbo-asr-fp16`) also reaches this engine. `model=whisper-1` does not: OpenAI clients send it by default, so it keeps meaning the engine Navo uses for dictation.
