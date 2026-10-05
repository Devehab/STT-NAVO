# Language models: Gemma and Llama

Text in, text out, with an open language model running on your Mac inside the Navo engine: summaries, rewrites, translations, anything you can ask in a prompt. Navo's own **AI** button uses this API. Nothing is sent anywhere: the address is `127.0.0.1` and the models work with no internet.

For the speech engines (audio in, text out) see [API.md](API.md).

| Id | Model | Made by | Base URL | Download | License |
| --- | --- | --- | --- | --- | --- |
| `gemma` | Gemma 4 E4B, 4 bit ([mlx-community/gemma-4-e4b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit)) | Google | `http://127.0.0.1:7861/gemma/v1` | 5.2 GB | Apache 2.0 |
| `llama` | Llama 3.1 8B Instruct, 4 bit ([mlx-community/Meta-Llama-3.1-8B-Instruct-4bit](https://huggingface.co/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit)) | Meta | `http://127.0.0.1:7861/llama/v1` | 4.5 GB | Llama 3.1 Community License |

Both are public (no Hugging Face token) and both answer the same request with the same response shape, so switching is a URL change. Gemma was trained on more than 140 languages and is the better choice for Arabic; Llama is strong in English.

- **OpenAI compatible:** `POST /{model}/v1/chat/completions` follows OpenAI's chat format, with or without streaming, so the OpenAI SDKs and most tools that accept a custom `base_url` work unchanged.
- **No authentication:** no API key. Clients that insist on one can send any value.
- **Asleep until used:** a model is not in memory until a request needs it. The request wakes it, it answers, and it leaves memory again a minute later.

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/gemma/v1/chat/completions` | A system prompt and a text in, the answer out, with Gemma |
| `POST` | `/llama/v1/chat/completions` | The same with Llama |
| `POST` | `/v1/chat/completions` | The same, with the model named in `model` (`gemma` or `llama`) |
| `GET` | `/v1/llms` | Both models and their state |
| `GET` | `/gemma/health`, `/llama/health` | One model |
| `POST` | `/v1/llms/{model}/load` | Load it ahead of a request |
| `POST` | `/v1/llms/{model}/unload` | Free its memory now |
| `POST` | `/v1/llms/unload` | Free every language model now |

## Quick start

```bash
# 1. Is the model on this Mac?
curl -s http://127.0.0.1:7861/gemma/health

# 2. Ask it: a system prompt (what to do) and a user message (the text to do it on)
curl -s http://127.0.0.1:7861/gemma/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "system", "content": "Summarize the text in three short points."},
      {"role": "user", "content": "اجتمعنا اليوم مع الفريق واتفقنا نأجل الإطلاق ليوم الخميس. سارة بتجهز العرض، وأحمد بيراجع الميزانية قبل الأربعاء."}
    ]
  }'
```

Ready-made clients are in [`examples/api`](../examples/api): `chat.py` (Python, standard library only, streams by default) and `openai_client.py` (official OpenAI SDK).

## Memory: how the models share the Mac

A Mac with 16 GB (or 8 GB) cannot hold a speech model and a language model at once and stay pleasant to use, so the engine follows three rules. They hold for every client, Navo included.

1. **One kind of model in memory at a time.** Before a language model loads, every speech engine and the small cleanup model leave memory. Before a speech engine loads, the language models leave. The two kinds are never loaded together, and the two language models are never loaded together either.
2. **At most 6 GB.** Both models are 4 bit builds: about 4.5 GB of weights in memory. A request may use at most 6,144 tokens, prompt plus answer, which bounds the working memory on top of the weights (about 0.8 GB for Llama at the full context, less for Gemma). A longer prompt is refused with `413` instead of growing past the limit.
3. **Asleep unless used.** A model loads for a request and leaves memory 60 seconds after its last answer, or at once when a speech model needs the room. When nothing is loaded any more, the models process exits and the engine is back at a few dozen MB.

Everything runs on one model thread, so requests never overlap: each waits for the one before it.

What a request does, step by step:

| Step | What happens | Rough time (it depends on the Mac) |
| --- | --- | --- |
| 1 | The request arrives. If the models process is asleep, the gateway starts it | 1 to 2 s |
| 2 | Speech engines and the cleanup model leave memory (they become `asleep`, not `off`) | under 1 s |
| 3 | The language model loads | 3 to 10 s the first time, faster after |
| 4 | It writes the answer | depends on the length, tens of tokens a second |
| 5 | It stays for `keep_alive` seconds (60 by default), then leaves memory | |

While a language model writes, a transcription request simply waits its turn: a meeting that is being recorded keeps recording, and its live text continues once the answer is done. That transcription then sends the language model away and loads its speech engine again, with no error and no change for the client, only a few seconds more.

The numbers are measured, not promised: every response carries `navo.peak_memory_bytes` (the most memory MLX used for that answer, weights included), `GET /v1/llms` shows the highest value of the session, and Navo > Settings > AI writing > Test shows what macOS counts for the models process.

## Before you call it

The model must be **downloaded**: in Navo > Settings > AI writing, click **Download** next to it, or from a terminal:

```bash
ENGINE_SRC="$HOME/Applications/Navo.app/Contents/Resources/engine"
ENGINE_HOME="$HOME/Library/Application Support/Navo/engine"
PYTHONPATH="$ENGINE_SRC" "$ENGINE_HOME/venv/bin/python" -m navo_engine.download --model mlx-community/gemma-4-e4b-it-4bit
```

It does not have to be loaded: a request loads it. Check it:

```bash
curl -s http://127.0.0.1:7861/v1/llms
```

```json
{
  "llms": [
    {
      "id": "gemma",
      "name": "Gemma 4 E4B",
      "maker": "Google",
      "license": "Apache 2.0",
      "model": "mlx-community/gemma-4-e4b-it-4bit",
      "status": "asleep",
      "downloaded": true,
      "error": null,
      "load_seconds": null,
      "idle_seconds": null,
      "model_path": "/Users/you/.cache/huggingface/hub/models--mlx-community--gemma-4-e4b-it-4bit/snapshots/...",
      "model_bytes": 5180000000,
      "context_tokens": 6144,
      "memory_limit_bytes": 6442450944,
      "peak_memory_bytes": 4870000000,
      "requests": 3,
      "last_tokens_per_second": 38.2
    },
    {"id": "llama", "name": "Llama 3.1 8B", "status": "asleep", "downloaded": false, "...": "..."}
  ]
}
```

The values are illustrative. `GET /gemma/health` returns one of these objects. Reading the state never wakes a model.

| `status` | Meaning | What to do |
| --- | --- | --- |
| `asleep` | Not in memory. With `downloaded: true` the next request loads it | Send the request |
| `loading` | Loading into memory | Wait, or send the request: it queues |
| `ready` | In memory, answers at once | Send the request |
| `writing` | Writing an answer | Send the request: it queues behind it |
| `error` | Loading failed, `error` says why | See `~/Library/Application Support/Navo/Logs/engine.log`. If it says the model type is not supported, update the engine in Navo > Settings > Speech engines > Reinstall / update |

## POST /{model}/v1/chat/completions

`{model}` is `gemma` or `llama`. The body is JSON.

### Request

```json
{
  "messages": [
    {"role": "system", "content": "You turn rough notes into a short, friendly email in English. Reply with the email only."},
    {"role": "user", "content": "اجتمعنا اليوم مع الفريق واتفقنا نأجل الإطلاق ليوم الخميس. سارة بتجهز العرض، وأحمد بيراجع الميزانية قبل الأربعاء."}
  ],
  "temperature": 0.3,
  "max_tokens": 400
}
```

The three parts you work with:

- **The system prompt** (`role: "system"`) says what the model is and what it must do: the task, the language, the format, the rules. Put everything that stays the same between requests here.
- **The command or the text** (`role: "user"`) is what to do it on: the transcript, the notes, the question.
- **The response** is the model's answer, in `choices[0].message.content` (see below).

| Field | Default | Meaning |
| --- | --- | --- |
| `messages` | required | `role` is `system`, `user` or `assistant` (`developer` counts as `system`); `content` is a string, or OpenAI content parts with `text`. Earlier turns can be included for a conversation |
| `temperature` | `0.3` | `0` always gives the same answer; higher is freer. Use `0.2` to `0.4` for summaries, up to `0.7` for casual writing |
| `top_p` | `0.95` | Nucleus sampling, used when `temperature` is above 0 |
| `top_k` | off | Keep only the k most likely tokens (Google suggests `64` for Gemma) |
| `max_tokens` | `1024` | The most tokens in the answer, capped at 2,048. `max_completion_tokens` is accepted too |
| `stop` | none | A string or a list of strings: the answer ends before the first one that appears |
| `repetition_penalty` | off | Above `1.0` (for example `1.1`) discourages repeating |
| `stream` | `false` | `true` sends the answer piece by piece, see [Streaming](#streaming) |
| `keep_alive` | `60` | Seconds the model stays in memory after this answer. `0` frees it at once, a negative number keeps it until a speech model needs the room |
| `model` | | Ignored on `/gemma/...` and `/llama/...`: the URL already picks the model |

Other OpenAI fields (`tools`, `response_format`, `n`...) are ignored.

### Response

```json
{
  "id": "chatcmpl-navo-3f2a9c1b7d4e",
  "object": "chat.completion",
  "created": 1791180000,
  "model": "mlx-community/gemma-4-e4b-it-4bit",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hi team,\n\nQuick update from today's meeting: we're moving the launch to Thursday. Sara is putting the presentation together, and Ahmad will review the budget before Wednesday.\n\nThanks,\n[Your name]"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {"prompt_tokens": 96, "completion_tokens": 48, "total_tokens": 144},
  "navo": {"llm": "gemma", "seconds": 1.31, "tokens_per_second": 36.6, "peak_memory_bytes": 4870000000}
}
```

The values are illustrative.

| Field | Meaning |
| --- | --- |
| `choices[0].message.content` | The answer |
| `choices[0].finish_reason` | `stop` when the model finished, `length` when it reached `max_tokens` (the answer is cut off) |
| `usage` | Tokens in the prompt, in the answer, and together |
| `navo.seconds`, `navo.tokens_per_second` | How long the writing took and how fast it was, loading not included |
| `navo.peak_memory_bytes` | The most memory MLX used for this answer, weights included |
| `model` | The weights that answered |

### Streaming

With `"stream": true` the answer comes as server-sent events in OpenAI's chunk format, one event per piece of text, so you can show it while it is written:

```
data: {"id": "chatcmpl-navo-98bc...", "object": "chat.completion.chunk", "created": 1791180000, "model": "mlx-community/gemma-4-e4b-it-4bit", "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""}, "finish_reason": null}]}

data: {"id": "chatcmpl-navo-98bc...", "object": "chat.completion.chunk", "created": 1791180000, "model": "mlx-community/gemma-4-e4b-it-4bit", "choices": [{"index": 0, "delta": {"content": "Hi"}, "finish_reason": null}]}

data: {"id": "chatcmpl-navo-98bc...", "object": "chat.completion.chunk", "created": 1791180000, "model": "mlx-community/gemma-4-e4b-it-4bit", "choices": [{"index": 0, "delta": {"content": " team"}, "finish_reason": null}]}

data: {"id": "chatcmpl-navo-98bc...", "object": "chat.completion.chunk", "created": 1791180000, "model": "mlx-community/gemma-4-e4b-it-4bit", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 96, "completion_tokens": 48, "total_tokens": 144}, "navo": {"llm": "gemma", "seconds": 1.31, "tokens_per_second": 36.6, "peak_memory_bytes": 4870000000}}

data: [DONE]
```

Join the `delta.content` values in order. The last chunk before `[DONE]` has the `finish_reason`, `usage` and `navo`. **To stop an answer, close the connection:** the model stops writing within a token and the next request in line starts. The first event comes only after the model has loaded, so allow a generous timeout for it (Navo uses 10 minutes).

### Long texts

A prompt of more than about 6,000 tokens is refused (`413`), because a longer context would need more memory than the limit allows. Roughly, 6,000 tokens are 4,500 English words or 2,500 to 3,500 Arabic words. For longer texts do what Navo does (`Sources/Navo/AI/AIWriter.swift`):

1. Cut the text into parts of about 5,000 characters, between paragraphs or sentences.
2. Ask for short notes of each part ("one line per point, keep names, numbers, decisions and tasks").
3. Ask for the final summary or email from the notes.

A one hour meeting becomes about a dozen small requests, each well inside the limit.

### Errors

Errors return JSON: `{"detail": "human readable reason"}`. For `422` the `detail` is a list that names the invalid field.

| Status | When |
| --- | --- |
| `400` | `messages` is empty |
| `404` | Unknown model id in the URL |
| `413` | The prompt does not fit the context. `detail` gives its size in tokens and the limit |
| `422` | The body is not valid JSON for this endpoint |
| `503` | The model is not downloaded yet, or failed to load. `detail` says which and how to fix it. A sleeping model does not return `503`: it loads and answers |
| `500` | Unexpected failure while writing. See `~/Library/Application Support/Navo/Logs/engine.log` |

In a stream, an error after the first event arrives as `data: {"error": {"message": "..."}}` followed by `data: [DONE]`.

## Waking and freeing a model

You never have to: a request wakes the model and it leaves by itself. These are for clients that want to control the timing.

```bash
curl -s -X POST http://127.0.0.1:7861/v1/llms/gemma/load     # load now (the speech models leave memory first)
curl -s -X POST http://127.0.0.1:7861/v1/llms/gemma/unload   # free it now
curl -s -X POST http://127.0.0.1:7861/v1/llms/unload         # free both
```

`load` returns when the model is in memory (`503` if it is not downloaded). `unload` waits for an answer that is still being written. Navo calls `/v1/llms/unload` when you close its AI panel, so the memory is back before you dictate again.

## Examples

**curl, streaming**

```bash
curl -s -N http://127.0.0.1:7861/llama/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"stream": true, "messages": [
        {"role": "system", "content": "Rewrite the text as a short, casual text message in American English."},
        {"role": "user", "content": "I would like to inform you that I will be arriving approximately fifteen minutes late."}]}'
```

**Python (standard library)**: [`examples/api/chat.py`](../examples/api/chat.py)

```bash
python3 examples/api/chat.py "Summarize in three points." meeting.txt
python3 examples/api/chat.py "Rewrite as a formal email." notes.txt --model llama --no-stream --json
```

```python
from chat import chat, stream

result = chat("Summarize in three points.", open("meeting.txt").read(), model="gemma")
print(result["choices"][0]["message"]["content"])
print(result["usage"], result["navo"])

for piece in stream("Summarize in three points.", open("meeting.txt").read()):
    print(piece, end="", flush=True)
```

**Python (requests)**

```python
import requests

r = requests.post(
    "http://127.0.0.1:7861/gemma/v1/chat/completions",
    json={
        "messages": [
            {"role": "system", "content": "Summarize the text in three short points, in its own language."},
            {"role": "user", "content": open("meeting.txt").read()},
        ],
        "temperature": 0.2,
        "max_tokens": 500,
    },
    timeout=600,
)
r.raise_for_status()
print(r.json()["choices"][0]["message"]["content"])
```

**JavaScript (Node 18+ or the browser), streaming**

```js
const res = await fetch("http://127.0.0.1:7861/gemma/v1/chat/completions", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    stream: true,
    messages: [
      { role: "system", content: "Summarize in three points." },
      { role: "user", content: text },
    ],
  }),
});
const decoder = new TextDecoder();
let buffer = "", answer = "";
for await (const bytes of res.body) {
  buffer += decoder.decode(bytes, { stream: true });
  const lines = buffer.split("\n");
  buffer = lines.pop();
  for (const line of lines) {
    if (!line.startsWith("data:") || line.includes("[DONE]")) continue;
    answer += JSON.parse(line.slice(5)).choices?.[0]?.delta?.content ?? "";
  }
}
```

**Swift**

```swift
var request = URLRequest(url: URL(string: "http://127.0.0.1:7861/gemma/v1/chat/completions")!)
request.httpMethod = "POST"
request.timeoutInterval = 600
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = try JSONSerialization.data(withJSONObject: [
    "messages": [
        ["role": "system", "content": "Summarize in three points."],
        ["role": "user", "content": text],
    ],
])
let (data, _) = try await URLSession.shared.data(for: request)
let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
let answer = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
```

**OpenAI SDK**: [`examples/api/openai_client.py`](../examples/api/openai_client.py)

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:7861/gemma/v1", api_key="local")
reply = client.chat.completions.create(
    model="gemma",
    messages=[
        {"role": "system", "content": "Summarize in three points."},
        {"role": "user", "content": text},
    ],
)
print(reply.choices[0].message.content)

# Streaming
for chunk in client.chat.completions.create(model="gemma", stream=True, messages=[{"role": "user", "content": "Hello"}]):
    print(chunk.choices[0].delta.content or "", end="")
```

## The prompts Navo uses

Navo's AI button sends a system prompt per action (summary, detailed summary, formal email, friendly email, text message, clean rewrite, each in English or Arabic) and the transcript as the user message. They are in `Sources/Navo/AI/WritingActions.swift`; copy them to get the same results from your own tools. For example, the short summary:

```text
You receive a transcript of speech: a dictation, a meeting, or a voice note. It was made by speech recognition, so it may contain misheard words, repetitions, filler words and missing punctuation, and it may mix Arabic (often a spoken dialect) with English. Understand what the speaker meant and work from that meaning.

Task: summarize the transcript. Write it in the main language of the transcript. If that is Arabic, use clear Modern Standard Arabic.
Start with one sentence that says what it is about. Then list the most important points, at most seven, one short line each, every line starting with "• ". Leave out small talk and repetition.

Rules:
- Use only what the transcript says. Never add facts, names, numbers, dates, promises or opinions that are not in it.
- Keep names, numbers, dates, prices and technical terms exactly as meant.
- Never use em dashes or en dashes. Use commas, periods or line breaks instead.
- Plain text only: no Markdown, no asterisks, no # headings, no bold.
- Reply with the result only. No introduction such as "Here is", no notes, no closing remarks.
```

## The shared URL, and the cleanup model

`POST http://127.0.0.1:7861/v1/chat/completions` reaches a language model when `model` names one: `gemma`, `llama`, an alias such as `gemma-4-e4b-it` or `llama-3.1-8b`, or the Hugging Face id. With any other `model` value (or none) it reaches the small **cleanup model** (Qwen3 4B) that tidies each dictation, which is documented in [API.md](API.md#post-v1chatcompletions). The cleanup model lives on the speech side: it can be in memory together with a speech engine, and it leaves with them when a language model loads.

## Options when you run the engine yourself

| Option | Default | Meaning |
| --- | --- | --- |
| `--gemma-model` | `mlx-community/gemma-4-e4b-it-4bit` | Hugging Face id or local folder for `gemma`: an MLX build that mlx-lm can load |
| `--llama-model` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | The same for `llama` |
| `--llm-context` | `6144` | Most tokens of a request, prompt plus answer. Raising it raises the memory a request can use |
| `--llm-keep-alive` | `60` | Seconds a model stays in memory after its last answer. `0` frees it at once |

Navo passes the two model ids from Settings > AI writing > Advanced. A larger or less compressed model (8 bit, a bigger Llama) works the same way but can need more than 6 GB.

## Good practice

- Check `GET /{model}/health` first and tell the user when the model is not downloaded, instead of failing on the first request.
- Put the instructions in the system prompt and the text in the user message. Say the output language and the format explicitly, and ask for "the result only".
- Stream when a person is waiting, and close the connection when they cancel.
- Send one request at a time. The engine queues them, so parallel calls do not finish sooner.
- Remember that a request moves the speech models out of memory. Do not run a batch of language model requests while someone is dictating: each dictation in between swaps the models back and forth.
- Keep the host on 127.0.0.1. There is no authentication, so exposing the port would let anyone on the network use your models.
