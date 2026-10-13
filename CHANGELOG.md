# Changelog

What changed in each version of Navo. The newest is first. The release notes on GitHub and the
"What's new" part of the website come from here.

## 0.13.0

- **See the words while you talk.** The text appears in a small card above the Flow Bar as you speak. Finished phrases are bright, the one you are saying is dimmer. Each phrase is transcribed when you pause, so a long dictation is in almost as soon as you let go. Short dictations are still transcribed again in one go, so accuracy is unchanged. Settings > Dictation > Show the text while you talk.
- **A welcome screen with three steps.** On the first open: download the engine, allow the microphone, allow Accessibility. One button each, with progress, and a clear message and Try again if something fails.
- **No account, no developer tools.** New installs start with Audar, which downloads with no Hugging Face token. The engine brings its own Python and ready-made packages, so macOS no longer asks to install Xcode tools.
- **Install with one line.** `curl -fsSL https://devehab.github.io/STT-NAVO/install.sh | bash` downloads Navo, puts it in Applications and opens it, with no warning from macOS.
- **Hide the Flow Bar.** For 10 minutes, 30 minutes, 1 hour or 2 hours, or show it only while you dictate. It still appears when you dictate and hides again after. In Settings and in the menu bar.
- **Delete models you do not use.** A delete button next to each downloaded model in Settings, with a confirmation that says how much space comes back.
- **Clearer names.** Record is now Notetaker, Files is now Transcribe.

## 0.11.1

- AI summaries and rewrites on the Mac with Gemma 4 or Llama 3.1 (Google Gemini removed).
- Four speech engines, two on at a time: Cohere, Audar, Whisper, Qwen3-ASR.
- Search and a date filter in meetings and files.
