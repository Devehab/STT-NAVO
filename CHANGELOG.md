# Changelog

What changed in each version of Navo. The newest is first. The release notes on GitHub and the
"What's new" part of the website come from here.

## 0.16.0

- **See how fast each model is.** A new Performance page in Settings, from your own use: for speech to text, the speed in "× real time" (seconds of audio per second of work, so short and long recordings compare fairly), the wait after you let go of the key, the cleanup time and the time to wake a model up; for AI writing, the time to the first word, the writing speed in tokens a second and the whole time. With what each number means, and the recent runs one by one. Each dictation in History shows its speed, and hovering shows where the time went. Only numbers are kept, never text.
- **Change the language after you stopped talking.** Switch the language (shortcut, Flow Bar or menu bar) while Navo is still writing, and it writes that dictation again in the new language: no need to wait and say it again. Switching while you talk starts the live text over in the new language. The Flow Bar shows the language it is writing in.

## 0.15.0

- **Use the models you already have.** Settings > Cleanup and AI > Add a model lists the models LM Studio downloaded, or takes any folder or .gguf file. Navo uses them where they are, so nothing is downloaded twice: MLX folders run on MLX, GGUF files on llama.cpp (Navo adds it to its engine once). Each one is tested right away, and can be picked for summaries, rewrites and translations. Remove takes it out of Navo and never touches its files.
- **Live text as accurate as transcribing afterwards.** Live text now comes in two passes: each sentence appears in grey a moment after it is said, and about every 20 seconds Navo listens to that stretch again as a whole and puts the final text in its place. A few seconds alone give a model too little context; 20 seconds give it as much as a full transcription. The saved transcript is always the final text.
- **Long dictations too.** While you talk, every 20 seconds or so is heard again as a whole, so a long dictation is accurate and still in a second or two after you let go. Short dictations are transcribed again in one go, as before.

## 0.14.0

- **Audar downloads work again.** On a new Mac the download finished but Navo kept saying "not downloaded", because the newest Hugging Face library counts the files Navo skips on purpose as missing. The engine now checks the files on disk itself, and a download only says done once the engine can really find the model. Download Cohere with its token right in its row.
- **Live text in Notetaker and Transcribe.** Pick Live, as you speak: each sentence appears a moment after it is said, cut at a pause so no word is split, and the sentence being said shows in grey as it comes. The 30 seconds to 5 minutes choices are still there. On a file, Live shows new text every few seconds.
- **Keep talking while Navo writes.** Press the dictation key again while the last part is still being written: Navo keeps writing in the background, listens again, and pastes everything together, in order, once. Settings > Dictation.
- **Private mode.** Navo's windows, the Flow Bar and the live text stay out of screen sharing, screenshots and screen recordings, while you still see them. Settings > Privacy, or Hide Navo from Screen Sharing in the menu bar.
- **Settings in pages.** General, Dictation, Speech engines, Cleanup and AI, Notetaker and Transcribe, Flow Bar, Clipboard, Privacy, History and storage, each with an icon and a line that says what it is for, and a note under each switch.
- **Model names are safe from dictation.** Text dictated into a model field by mistake no longer breaks the model: Navo uses the default and says so under the field, with Reset.

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
