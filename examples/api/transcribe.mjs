#!/usr/bin/env node
// Transcribe an audio file with the local Navo engine (Node 18+, no dependencies).
//   node transcribe.mjs recording.wav              the engine Navo uses for dictation
//   node transcribe.mjs recording.wav ar audar     Audar ASR V1 Turbo
//   node transcribe.mjs meeting.mp3 en cohere      Cohere Transcribe Arabic
//   node transcribe.mjs meeting.mp3 en whisper     Whisper Large v3 Turbo
//   node transcribe.mjs talk.wav auto qwen3        Qwen3-ASR 1.7B, language detected
import { realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import { pathToFileURL } from "node:url";

const BASE_URL = process.env.NAVO_URL ?? "http://127.0.0.1:7861";

// engine: "cohere", "audar", "whisper", "qwen3", or undefined for the engine Navo uses for dictation.
export async function transcribe(path, language = "ar", engine = undefined) {
  const form = new FormData();
  form.append("language", language);
  form.append("file", new Blob([await readFile(path)]), basename(path));
  const root = engine ? `${BASE_URL}/${engine}` : BASE_URL;
  const response = await fetch(`${root}/v1/audio/transcriptions`, { method: "POST", body: form });
  const body = await response.json();
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${body.detail ?? JSON.stringify(body)}`);
  return body; // { text, language, duration, engine, model, backend, processing_ms }
}

// Run as a script (not when imported); realpath because symlinked paths differ from import.meta.url.
if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [file, language = "ar", engine] = process.argv.slice(2);
  if (!file) {
    console.error("usage: node transcribe.mjs <audio file> [ar|en|auto|fr|...] [cohere|audar|whisper|qwen3]");
    process.exit(2);
  }
  transcribe(file, language, engine)
    .then((result) => console.log(result.text))
    .catch((error) => {
      const refused = error.cause?.code === "ECONNREFUSED";
      const missing = error.code === "ENOENT";
      console.error(
        missing ? `error: file not found: ${file}`
        : refused ? `error: nothing is listening at ${BASE_URL}. Is Navo running?`
        : `error: ${error.message}`
      );
      process.exit(1);
    });
}
