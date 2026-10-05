# Cohere Transcribe Arabic engine

Speech to text with **Cohere Transcribe Arabic** (`CohereLabs/cohere-transcribe-arabic-07-2026`), running on your Mac inside the Navo engine. Audio never leaves the Mac.

For what the engines share (running the engine, turning engines on and off, the limit of two engines on at once, comparing them, the cleanup LLM, using the engine from agents) see [API.md](API.md). The other engines are documented in [API-Audar.md](API-Audar.md), [API-Whisper.md](API-Whisper.md) and [API-Qwen3.md](API-Qwen3.md).

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:7861/cohere` |
| OpenAI SDK `base_url` | `http://127.0.0.1:7861/cohere/v1` |
| Transcription endpoint | `POST http://127.0.0.1:7861/cohere/v1/audio/transcriptions` |
| Engine status | `GET http://127.0.0.1:7861/cohere/health` |
| Engine id | `cohere` |
| Runs on | Apple GPU through MLX (mlx-audio), with the PyTorch reference implementation as automatic fallback |
| Languages | `ar` (Arabic in any dialect, including Arabic mixed with English) and `en` |
| Authentication | None. The engine listens on 127.0.0.1 only |

## The model

| | |
| --- | --- |
| Hugging Face | [CohereLabs/cohere-transcribe-arabic-07-2026](https://huggingface.co/CohereLabs/cohere-transcribe-arabic-07-2026) |
| Access | **Gated.** Accept the terms on the model page with your Hugging Face account, then give Navo a Read token once for the download. The token is not stored |
| Download | In Navo > Settings > Speech engines, **Download** next to Cohere (or Install / Reinstall, which downloads every engine that is on). Needs the token field filled in |
| Memory | About the size of the model on disk while it is loaded (Settings shows the exact figure), none while it is asleep. It leaves memory after the idle time, 10 minutes by default |

## Before you call it

The engine must be **on**, and **at most two engines are on at once** (see [Two engines at a time](API.md#two-engines-at-a-time)). It does not have to be loaded: an engine that is asleep loads for the request (see [Memory: sleep and wake](API.md#memory-sleep-and-wake)). Check it:

```bash
curl -s http://127.0.0.1:7861/cohere/health
```

```json
{
  "id": "cohere",
  "name": "Cohere Transcribe Arabic",
  "model": "CohereLabs/cohere-transcribe-arabic-07-2026",
  "languages": ["ar", "en"],
  "status": "ready",
  "downloaded": true,
  "backend": "mlx",
  "device": "Apple GPU (MLX)",
  "error": null,
  "load_seconds": 6.4,
  "model_path": "/Users/you/.cache/huggingface/hub/models--CohereLabs--cohere-transcribe-arabic-07-2026/snapshots/...",
  "model_bytes": 4130000000,
  "transcriptions": 42,
  "last_processing_ms": 870,
  "default": true
}
```

The values are illustrative. `status` is one of:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `ready` | Loaded, requests are answered | Send audio |
| `loading` | Loading into memory, a few seconds | Poll `/cohere/health` every second |
| `asleep` | On, but out of memory after being idle | Send audio anyway: it loads first, so that request takes a few seconds more |
| `off` | Turned off, it never loads | Turn it on in Navo > Settings > Speech engines, or `curl -X POST http://127.0.0.1:7861/v1/engines/cohere/enable` (`409` while two others are on) |
| `error` | Loading failed. `error` says why, and `downloaded: false` means the model is not on this Mac yet | Download it in Settings, or read `~/Library/Application Support/Navo/Logs/engine.log` |

## POST /cohere/v1/audio/transcriptions

Send one audio file as `multipart/form-data`. The response is the transcript.

### Request fields

| Field | Required | Default | Values |
| --- | --- | --- | --- |
| `file` | yes | | The audio file |
| `language` | no | `ar` | `ar` or `en`. Also accepts `arabic`, `english`, `ar-SA`, `ar-EG`, `ar-SY`, `ar-JO`, `en-US`, `en-GB` |
| `response_format` | no | `json` | `json` or `text` |
| `model` | no | | Accepted for OpenAI compatibility and ignored: the URL already picks this engine |

Use `ar` for Arabic in any dialect, including Arabic mixed with English. Use `en` for English-only audio: with `ar`, English speech can come out in Arabic letters. There is no automatic language detection: `auto` is refused with `400` (Audar, Whisper and Qwen3 have it). For other languages, use Whisper or Qwen3.

### Audio

| | |
| --- | --- |
| Formats | WAV, FLAC, MP3, OGG (Vorbis or Opus), AIFF, CAF |
| Not supported | M4A/AAC, WebM, MP4 video. Convert first: `ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav` |
| Sample rate and channels | Any. Audio is resampled to 16 kHz and stereo is mixed to mono automatically |
| Length | No fixed limit. Audio longer than 29.5 seconds is cut inside pauses (see [How long audio is cut](API.md#how-long-audio-is-cut)) and the pieces are joined |
| Size | Up to 200 MB per request |
| Best input | 16 kHz mono WAV, which is what Navo itself sends |

The model does not return timestamps or speaker labels. Pieces with no sound at all are not sent to the model, so silence returns an empty `text`; very quiet noise can still produce invented words.

### Response: `response_format=json` (default)

```json
{
  "text": "بدي أشرح الفكرة بطريقة بسيطة، and then we move to the demo.",
  "language": "ar",
  "duration": 6.84,
  "engine": "cohere",
  "model": "CohereLabs/cohere-transcribe-arabic-07-2026",
  "backend": "mlx",
  "processing_ms": 910
}
```

| Field | Meaning |
| --- | --- |
| `text` | The transcript, with punctuation. Recognizer markers such as `<hesitation>` are removed; otherwise it is the raw recognizer output, before any LLM cleanup |
| `language` | The language code that was used |
| `duration` | Audio length in seconds |
| `engine` | Always `cohere` here |
| `model`, `backend` | Model id, and `mlx` or `transformers` (PyTorch fallback) |
| `processing_ms` | Time spent on this request, queue wait included |

### Response: `response_format=text`

`Content-Type: text/plain`, the transcript only.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | Unsupported `language` (including `auto`), or an empty file |
| `413` | File larger than 200 MB |
| `415` | The file is not audio the engine can read. `detail` lists the supported formats |
| `422` | The `file` field is missing |
| `503` | The engine is off or failed to load. `detail` says which and how to fix it. A sleeping engine does not return `503`: it loads and answers |
| `500` | Unexpected failure during transcription. See `~/Library/Application Support/Navo/Logs/engine.log` |

## Examples

**curl**

```bash
curl -s -F file=@note.ogg -F language=ar http://127.0.0.1:7861/cohere/v1/audio/transcriptions

# English, plain text
curl -s -F file=@meeting.mp3 -F language=en -F response_format=text \
  http://127.0.0.1:7861/cohere/v1/audio/transcriptions
```

**Python (standard library)**: [`examples/api/transcribe.py`](../examples/api/transcribe.py)

```bash
python3 examples/api/transcribe.py note.wav --engine cohere
```

```python
from transcribe import transcribe

result = transcribe("note.wav", language="ar", engine="cohere")
print(result["text"], result["processing_ms"])
```

**Python (requests)**

```python
import requests

with open("note.wav", "rb") as audio:
    r = requests.post(
        "http://127.0.0.1:7861/cohere/v1/audio/transcriptions",
        files={"file": audio},
        data={"language": "ar"},
        timeout=600,
    )
r.raise_for_status()
print(r.json()["text"])
```

**JavaScript (Node 18+ or the browser)**: [`examples/api/transcribe.mjs`](../examples/api/transcribe.mjs)

```js
const form = new FormData();
form.append("language", "ar");
form.append("file", audioBlob, "note.wav");
const res = await fetch("http://127.0.0.1:7861/cohere/v1/audio/transcriptions", { method: "POST", body: form });
const { text } = await res.json();
```

**Swift**

```swift
var request = URLRequest(url: URL(string: "http://127.0.0.1:7861/cohere/v1/audio/transcriptions")!)
request.httpMethod = "POST"
let boundary = UUID().uuidString
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
var body = Data()
body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nar\r\n".utf8))
body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
body.append(try Data(contentsOf: audioURL))
body.append(Data("\r\n--\(boundary)--\r\n".utf8))
let (data, _) = try await URLSession.shared.upload(for: request, from: body)
let text = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["text"] as? String
```

**OpenAI SDK**: [`examples/api/openai_client.py`](../examples/api/openai_client.py)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:7861/cohere/v1", api_key="local")
with open("note.wav", "rb") as audio:
    print(client.audio.transcriptions.create(model="cohere", file=audio, language="ar").text)
```

## Older URL

`POST http://127.0.0.1:7861/v1/audio/transcriptions` still works. It uses the engine named in the `model` field (`cohere`, `cohere-transcribe-arabic-07-2026` or the Hugging Face id), and otherwise the engine Navo uses for dictation. Use the `/cohere` URL when you need Cohere specifically.
