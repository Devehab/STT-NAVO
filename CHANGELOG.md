# Changelog

What changed in each version of Navo. The newest is first. The release notes on GitHub and the
"What's new" part of the website come from here.

## 0.22.2

- **Navo's controls show up in Control Center.** In 0.22.0 and 0.22.1 the Navo controls were missing from Edit Controls: macOS started Navo's controls extension, and it quit at once, before it could say which controls it has. It now starts the way every extension built with Xcode does, and all six are there: Dictate, Record meeting, Language, Hide from screen sharing, Clipboard history and Flow Bar.

## 0.22.1

- **Navo.app stays exactly as installed.** Navo's engine runs Python code from inside the app, and Python saved its compiled copies next to that code, so the app changed after it was signed and macOS's signature check failed on it. The compiled copies now go to ~/Library/Caches/Navo, and the app's signature stays valid however long Navo runs.

## 0.22.0

- **Navo in Control Center and the menu bar** (macOS 26). In Control Center > Edit Controls, search Navo and drag in the ones you want: Dictate (start, or stop and paste), Record meeting (on while recording), Dictation language (shows it, and switches between Arabic and English), Hide from screen sharing, Clipboard history (Quick Paste) and Flow Bar (always there, or only while you dictate). They work from the menu bar too. Navo stays in the background, so dictation still pastes into the app you were typing in, and a control opens Navo if it is not running.

## 0.21.1

- **Spotlight finds Navo again.** Typing "Navo" in Spotlight could find nothing while the app was in the list of all apps: macOS still had notes of Navo copies that were gone (an installer disk opened in Finder, an older copy in another folder), and Spotlight looked for one of those. The installer now drops every note whose files are gone and registers the installed copy, so the next update fixes it on any Mac.
- **One Navo per Mac.** Building from source (scripts/run.sh) now installs into Applications, like the installer, and removes the copy an earlier build left in your home folder's Applications.

## 0.21.0

- **Copy several at once.** With several recordings or files selected, Copy puts all their texts on the clipboard, oldest first, each with its title, when it was recorded, its length, engine and language, then its text. Copy with times adds the time of each paragraph.
- **One Word document with all of them.** Export saves a .docx (Downloads by default) that opens in Word, Pages and Google Docs: a list of what is in it, then each one on its own page with its title and date. Arabic is right to left. Also as a text file, with or without times, and Export as Word for a single recording.
- **AI on several at once.** The AI button reads all of them together, oldest first, each with its title and date: a summary or a detailed summary of all of them (a later meeting's decision wins over an earlier one), an email or a message, or a clean rewrite that keeps each one apart, spelling and order fixed and every detail kept.
- **The AI checks the size first.** Before anything is sent, the panel shows how many tokens the text is, how much the model holds at a time, and how many requests it takes, with the time when it is long. Nothing ever goes past the model's context window: when it does not fit, each recording is read on its own and the answer is written from the notes, so it never hangs.

## 0.20.0

- **A notification when transcriptions are done.** Pick in Settings > Notetaker and Transcribe: when everything in line is done (one notification, even for ten files, with how many worked), for each one as it finishes (the last one says how all of them went), or never. Clicking it opens the recording or file, even while another meeting is being recorded. macOS asks once whether Navo may show them, when the first transcription starts; Send a test shows how one looks. macOS keeps them off the screen while you share it.
- **Emoji in the menu bar instead of the recording dot.** Settings > Privacy > Menu bar icon: keep Navo's icons, or pick an emoji for recording, paused, transcribing and done (and, if you like, for nothing going on), so nothing in the menu bar says "recording" to anyone who sees your screen. The time and the percentage next to it can be hidden too, and the tooltip then only says Navo.
- **Opening another recording while one is recorded** from the menu bar or a notification shows it in the list, with the recording in the bar above.

## 0.19.0

- **Select several recordings or files, and redo them with another model.** In Notetaker and Transcribe, ⌘-click or ⇧-click in the list, or use Select (all, transcribed, not transcribed yet, failed or partly done). With several selected: Transcribe again with the engine and language chosen above, or pick any other engine and language from its arrow. They go in line in the order of the list and run one after the other: each starts when the one before it is done.
- **Stop them all.** Stop takes the selected ones out of the line, and a line above the list shows what is being transcribed, how many wait, and Stop all. The text already written stays, and Continue goes on from there. Recording a new meeting, its live text and reading the others are not touched.
- **Delete several at once**, with one confirmation.

## 0.18.0

- **Read your other recordings while one is recording.** In Notetaker, Other recordings opens the list while the meeting goes on: read, play, copy or summarize an old one. The recording stays in a bar at the top with its time, its latest words, Pause and Stop, and Show live text brings the panel back. Playing an old recording no longer ends up in the one being recorded: Navo leaves its own sound out of the Mac audio it records.
- **AI and live text at the same time.** Settings > Cleanup and AI > Keep transcribing while AI writes: the speech models stay in memory beside the language model, so a meeting's live text, files in Transcribe and dictation go on while the AI writes a summary (they are transcribed between its words: about 1.2 s for 8 s of speech while Gemma writes, on a 16 GB Mac). Off by default: together they take about 8 to 10 GB, and the setting says what this Mac has. It changes at once, without restarting anything.
- **If macOS runs out of memory**, and stops Navo's engine to free it, Navo says so in plain words and in the problems log, and the engine starts again on the next request.

## 0.17.1

- **Select across paragraphs in a transcript.** In Notetaker and Transcribe, live or finished, the transcript is now one text: drag over as many paragraphs as you like, or press ⌘A for all of it, then ⌘C. Select All and Copy are also in the right-click menu, ⌘F finds a word, and what you copy is plain text with its times. A selection stays selected while new live text arrives, and the text stops following the newest line while you select or scroll up to read.
- **Copy the live text in one click.** A Copy button next to Stop live text copies everything so far, with its times.

## 0.17.0

- **See how a model spends its tokens.** Settings > Performance now shows, for each language model, its context window (what one request can hold, and the most the model was made for), the tokens in and out of a typical answer, how full the window was, and how many characters of your text fit in a token. That last one shows how well a model knows a language: on the same Arabic text Gemma fits 3.1 characters in a token, Qwen3 2.7, a small model 1.0, so the same text costs it three times as many tokens. Details on each recent answer shows every figure: the instructions' share, the answer's room, whether it was cut off.
- **Counted right for GGUF models.** llama.cpp sometimes sends several tokens in one piece (an Arabic letter can take two), so answers were counted short. Navo now counts them the way llama.cpp does.
- **A model is never asked for more than it was made for.** A model you added with a context shorter than Navo's limit gets requests that fit it, and a longer text is read in parts.
- **A problems log.** When something fails, a model, a transcription, the engine, or a figure that could not be measured, Navo carries on and notes what happened and why in Settings > Performance > Problems log (and Logs/problems.log), so it can be fixed later. Copy all puts it on the clipboard. Only the problem is written, never your text.

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
