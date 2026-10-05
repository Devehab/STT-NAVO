"""The engine speaks the OpenAI API, so the official SDK works unchanged.

    pip install openai
    python3 openai_client.py recording.wav            # Cohere
    python3 openai_client.py recording.wav audar      # Audar
    python3 openai_client.py recording.wav whisper    # Whisper Large v3 Turbo
    python3 openai_client.py recording.wav qwen3      # Qwen3-ASR 1.7B

Each speech engine has its own base URL: http://127.0.0.1:7861/cohere/v1,
http://127.0.0.1:7861/audar/v1, http://127.0.0.1:7861/whisper/v1 and
http://127.0.0.1:7861/qwen3/v1. The language models that summarize and rewrite are at
http://127.0.0.1:7861/gemma/v1 and http://127.0.0.1:7861/llama/v1 (docs/API-LLM.md).

The script transcribes the recording, then asks Gemma for a summary. The engine never keeps a
speech model and a language model in memory together: the second request frees the first model.
"""

import sys

from openai import OpenAI

engine = sys.argv[2] if len(sys.argv) > 2 else "cohere"
speech = OpenAI(base_url=f"http://127.0.0.1:7861/{engine}/v1", api_key="local")  # any key, it is not checked

with open(sys.argv[1], "rb") as audio:
    transcript = speech.audio.transcriptions.create(
        model=engine,  # the base URL already picks the engine; this value is not used
        file=audio,
        language="ar",
    )
print(transcript.text)

writer = OpenAI(base_url="http://127.0.0.1:7861/gemma/v1", api_key="local")
stream = writer.chat.completions.create(
    model="gemma",  # the base URL already picks the model
    messages=[
        {"role": "system", "content": "Summarize the text in three short points, in its own language."},
        {"role": "user", "content": transcript.text},
    ],
    temperature=0.2,
    stream=True,  # the answer arrives while it is written
)
for chunk in stream:
    if chunk.choices:
        print(chunk.choices[0].delta.content or "", end="", flush=True)
print()
