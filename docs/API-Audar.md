# Audar ASR V1 Turbo engine

Speech to text with **Audar ASR V1 Turbo** (`audarai/Audar-ASR-V1-Turbo`), running on your Mac inside the Navo engine. Audio never leaves the Mac.

For what the engines share (running the engine, turning engines on and off, the limit of two engines on at once, comparing them, the cleanup LLM, using the engine from agents) see [API.md](API.md). The other engines are documented in [API-Cohere.md](API-Cohere.md), [API-Whisper.md](API-Whisper.md) and [API-Qwen3.md](API-Qwen3.md).

| | |
| --- | --- |
| Base URL | `http://127.0.0.1:7861/audar` |
| OpenAI SDK `base_url` | `http://127.0.0.1:7861/audar/v1` |
| Transcription endpoint | `POST http://127.0.0.1:7861/audar/v1/audio/transcriptions` |
| Engine status | `GET http://127.0.0.1:7861/audar/health` |
| Engine id | `audar` |
| Runs on | Apple GPU through MLX (mlx-audio's Qwen3-ASR port). There is no PyTorch fallback for this engine |
| Languages | `ar` (Arabic dialects, MSA, and Arabic mixed with English) and `en` |
| Authentication | None. The engine listens on 127.0.0.1 only |

## The model

| | |
| --- | --- |
| Hugging Face | [audarai/Audar-ASR-V1-Turbo](https://huggingface.co/audarai/Audar-ASR-V1-Turbo) |
| Architecture | Qwen3-ASR (audio encoder plus Qwen3 decoder), 2.35B parameters: decoder 2.03B, encoder 0.32B |
| Weights used | The full precision BF16 `model.safetensors`, about 4.7 GB. The repository's GGUF and vLLM builds are not downloaded |
| Access | **Public**, no Hugging Face token needed |
| License | AudarAI Community License v1.0: research and limited commercial use, enterprise use needs a separate license. Read it on the model page before using the output commercially |
| Accuracy | First on the Open Universal Arabic ASR leaderboard according to its model card (average WER 23.17%) |
| Memory | About 4.7 GB while it is loaded, none while it is asleep. It leaves memory after the idle time, 10 minutes by default |
| Download | In Navo > Settings > Speech engines, **Download** next to Audar |

## How Navo runs it

These follow the model card, which calls its output protocol mandatory:

- **Language.** With `ar` or `en` the decoder is started with `language Arabic<asr_text>` or `language English<asr_text>`, so the model never guesses the language. With `auto` nothing is set and the model names the language itself; Navo removes that label from the text. The Arabic dialect (Gulf, Egyptian, Levantine, Maghrebi, MSA) is never chosen: the model writes what it hears in the dialect it hears, whatever `language` says.
- **30 second context.** Audio longer than 28 seconds is cut into pieces of at most 28 seconds, each cut inside a pause (see [How long audio is cut](API.md#how-long-audio-is-cut)), each piece is transcribed, and the texts are joined with a space.
- **Greedy decoding, 256 tokens per piece.** Deterministic output, and a hard stop if the model starts repeating itself.
- **Non-speech.** Pieces with no sound at all are not sent to the model. A piece the model marks as `language None` (music, noise) adds nothing to the transcript, and a phrase repeated ten or more times in a row is collapsed to one. Silent audio therefore returns an empty `text` rather than invented words.
- **Markers** such as `<hesitation>` are removed, as with the Cohere engine.

For maintainers: Audar ships an output layer (`lm_head`) that is not tied to its embeddings, while mlx-audio's Qwen3-ASR loader assumes it is and drops it. Navo loads that layer from the checkpoint itself after mlx-audio has loaded the rest (`Qwen3MLXBackend` in `engine/navo_engine/asr.py`, covered by `engine/tests/test_qwen3_mlx.py`). Without it the output is noise.

## Before you call it

The engine must be **on**, and **at most two engines are on at once**. After you download Audar, Navo turns it on if there is room; otherwise turn off one of the two engines that are on first (see [Two engines at a time](API.md#two-engines-at-a-time)). It does not have to be loaded: an engine that is asleep loads for the request (see [Memory: sleep and wake](API.md#memory-sleep-and-wake)). Check it:

```bash
curl -s http://127.0.0.1:7861/audar/health
```

```json
{
  "id": "audar",
  "name": "Audar ASR V1 Turbo",
  "model": "audarai/Audar-ASR-V1-Turbo",
  "languages": ["ar", "en", "auto"],
  "status": "ready",
  "downloaded": true,
  "backend": "mlx",
  "device": "Apple GPU (MLX)",
  "error": null,
  "load_seconds": 5.1,
  "model_path": "/Users/you/.cache/huggingface/hub/models--audarai--Audar-ASR-V1-Turbo/snapshots/...",
  "model_bytes": 4716000000,
  "transcriptions": 7,
  "last_processing_ms": 1240,
  "default": false
}
```

The values are illustrative. `status` is one of:

| `status` | Meaning | What to do |
| --- | --- | --- |
| `ready` | Loaded, requests are answered | Send audio |
| `loading` | Loading into memory, a few seconds | Poll `/audar/health` every second |
| `asleep` | On, but out of memory after being idle | Send audio anyway: it loads first, so that request takes a few seconds more |
| `off` | Turned off, it never loads | Turn it on in Navo > Settings > Speech engines, or `curl -X POST http://127.0.0.1:7861/v1/engines/audar/enable` (`409` while two others are on) |
| `error` | Loading failed. `error` says why, and `downloaded: false` means the model is not on this Mac yet | Download it in Settings, or read `~/Library/Application Support/Navo/Logs/engine.log` |

## POST /audar/v1/audio/transcriptions

Send one audio file as `multipart/form-data`. The response is the transcript. The request and response have the same shape as the other engines, so a client written for one works with another by changing the URL.

### Request fields

| Field | Required | Default | Values |
| --- | --- | --- | --- |
| `file` | yes | | The audio file |
| `language` | no | `ar` | `ar`, `en` or `auto`. Also accepts `arabic`, `english`, `automatic`, `detect`, `ar-SA`, `ar-EG`, `ar-SY`, `ar-JO`, `en-US`, `en-GB` |
| `response_format` | no | `json` | `json` or `text` |
| `model` | no | | Accepted for OpenAI compatibility and ignored: the URL already picks this engine |

Use `ar` for Arabic in any dialect, including Arabic mixed with English, and `en` for English-only audio: forced to Arabic, English speech tends to come out in Arabic letters. `auto` suits audio whose language you do not know, or that switches between languages from one sentence to the next. The `ar-..` variants all mean `ar`; there is no dialect setting, because the model takes the dialect from the audio.

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
  "text": "بدي أشرح الفكرة بطريقة بسيطة، and then we move to the demo.",
  "language": "ar",
  "duration": 6.84,
  "engine": "audar",
  "model": "audarai/Audar-ASR-V1-Turbo",
  "backend": "mlx",
  "processing_ms": 1180
}
```

| Field | Meaning |
| --- | --- |
| `text` | The transcript. Empty when the audio holds no speech. It is the recognizer output before any LLM cleanup |
| `language` | The language code that was used |
| `duration` | Audio length in seconds |
| `engine` | Always `audar` here |
| `model`, `backend` | Model id, and `mlx` |
| `processing_ms` | Time spent on this request, queue wait included |

### Response: `response_format=text`

`Content-Type: text/plain`, the transcript only.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | Unsupported `language`, or an empty file |
| `413` | File larger than 200 MB |
| `415` | The file is not audio the engine can read. `detail` lists the supported formats |
| `422` | The `file` field is missing |
| `503` | The engine is off or failed to load. `detail` says which and how to fix it. A sleeping engine does not return `503`: it loads and answers |
| `500` | Unexpected failure during transcription. See `~/Library/Application Support/Navo/Logs/engine.log` |

## Examples

**curl**

```bash
curl -s -F file=@note.ogg -F language=ar http://127.0.0.1:7861/audar/v1/audio/transcriptions

# English, plain text
curl -s -F file=@meeting.mp3 -F language=en -F response_format=text \
  http://127.0.0.1:7861/audar/v1/audio/transcriptions
```

**Python (standard library)**: [`examples/api/transcribe.py`](../examples/api/transcribe.py)

```bash
python3 examples/api/transcribe.py note.wav --engine audar
```

```python
from transcribe import transcribe

result = transcribe("note.wav", language="ar", engine="audar")
print(result["text"], result["processing_ms"])
```

**Python (requests)**

```python
import requests

with open("note.wav", "rb") as audio:
    r = requests.post(
        "http://127.0.0.1:7861/audar/v1/audio/transcriptions",
        files={"file": audio},
        data={"language": "ar"},
        timeout=600,
    )
r.raise_for_status()
print(r.json()["text"])
```

**JavaScript (Node 18+ or the browser)**: [`examples/api/transcribe.mjs`](../examples/api/transcribe.mjs)

```bash
node examples/api/transcribe.mjs note.wav ar audar
```

```js
const form = new FormData();
form.append("language", "ar");
form.append("file", audioBlob, "note.wav");
const res = await fetch("http://127.0.0.1:7861/audar/v1/audio/transcriptions", { method: "POST", body: form });
const { text } = await res.json();
```

**Swift**

```swift
var request = URLRequest(url: URL(string: "http://127.0.0.1:7861/audar/v1/audio/transcriptions")!)
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

client = OpenAI(base_url="http://127.0.0.1:7861/audar/v1", api_key="local")
with open("note.wav", "rb") as audio:
    print(client.audio.transcriptions.create(model="audar", file=audio, language="ar").text)
```

## Older URL

`POST http://127.0.0.1:7861/v1/audio/transcriptions` with `model=audar` (or `audar-asr-v1-turbo`, or `audarai/Audar-ASR-V1-Turbo`) also reaches this engine. Without a recognized `model` it goes to the engine Navo uses for dictation.
