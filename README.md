![Velo — Speak. It flows.](Assets/Velo/Velo-Logo.png)

# Velo — small offline macOS dictation prototype

**Personal-use prototype (v0.1), source included. Not a precompiled `.app`.**

Designed for a low idle-memory footprint on Apple Silicon Macs. It uses the **built-in macOS on-device speech recognizer**, rather than downloading/loading Whisper, EmbeddingGemma, or Ollama to perform ordinary dictation. It does **not** guarantee a specific RAM figure or better accuracy than EG2 on your particular accent. The only way to verify that is to try and measure it on your Mac.

## What works in this prototype

- macOS menu-bar microphone, no Dock icon or always-open window
- Global **Option + Shift + Space (⌥⇧Space)** toggle shortcut
- Local streaming partial transcript and unobtrusive floating recording status
- On-device recognition enforced with `requiresOnDeviceRecognition` (no silent cloud fallback)
- Voice punctuation and recognition-time custom vocabulary hints
- Very lightweight cleanup of hesitation sounds and spelling corrections (no LLM)
- Automatic paste into the original active app; best-effort preservation of clipboard contents
- Vocabulary persisted in one editable local JSON file
- **Optional, off by default:** on-demand Ollama `gemma3:1b` rewriting on localhost with `keep_alive: 0` to free its memory after use
- No subscriptions, analytics, accounts, cloud APIs, or saved audio/transcript history

## Dictating (Wispr Flow-style)

- **Speech engine:** on macOS 26 the app uses Apple's SpeechAnalyzer with the long-form `SpeechTranscriber` model (the one behind Notes and Voice Memos transcription), which is much more accurate on natural, paused speech than the classic `SFSpeechRecognizer`. It's still fully on-device. The classic recognizer is only used on older macOS or while the model downloads on first launch. **Permission & Recognition Status…** shows which engine is active.

- **Hold Right Option (⌥)** and speak; release to insert. **Double-tap** it for hands-free; tap once to finish. ⌥⇧Space also toggles hands-free recording.
- Change the key under **Dictation Key** in the menu (Right Option, Right Command, or Fn / Globe). Pressing another key within a second of holding it is treated as a keyboard shortcut and cancels that recording.
- Pauses never end or erase a recording. Only releasing the dictation key (or tapping it in hands-free mode) finishes it.
- A small pill at the bottom of the screen shows a live waveform, a red dot in hands-free mode, and the tail of what you've said.
- When finished, the text is pasted into the focused text field. **If no text field is focused, it's copied to the clipboard** ("Copied · ⌘V to paste").
- **⌥⇧V** pastes the last transcript again. **Recent Transcripts** in the menu keeps the last 15 (in memory only) — click one to copy it.
- Say **"new line"** or **"new paragraph"** to insert line breaks.
- **Lists (offline, no AI):** "I need three things. First, buy milk, second, call mom, and third, book the flight" → a numbered list. "Number one … number two …" also works, and "bullet point milk bullet point eggs" makes a bulleted list.
- **OpenRouter model:** GPT-OSS 120B served by Groq (falls back to Cerebras) is the default. In a benchmark on this task it answered in about 0.26 s, versus about 0.85–0.95 s for GPT-4o mini and Gemini 2.5 Flash Lite, which remain selectable under **OpenRouter Model**.
- **Optional rewrite (Ollama or OpenRouter)** makes light edits only: grammar, punctuation, misplaced words, stutters and self-corrections, rarely merging repeated sentences. It knows which app you're typing into (chat, email, code editor) and formats lists. Dictations under four words skip the model, replies are capped to about the input length, and a rewrite that changes too much of what you said is thrown away in favor of your original text.
- You can start the next dictation while the previous one is still being pasted.
- Start/stop sounds can be turned off with **Sound Effects** in the menu.
- If you choose Fn, set System Settings → Keyboard → "Press 🌐 key to" **Do Nothing**, or Fn will also switch your input language.
- `build.sh` signs the app with a local certificate ("BreezeDictate Local Signing", created once in your login keychain), so the Accessibility permission needed for auto-paste survives rebuilds.

## Requirements

- Mac running **macOS 13+** (modern Apple Silicon recommended)
- Apple Command Line Tools (or Xcode); install with `xcode-select --install` if necessary
- Built-in on-device speech support for the `en-US` locale
- For automatic paste into other apps, grant **Accessibility** permission to Velo
- For optional rewriting only: Ollama and `ollama pull gemma3:1b`

## Build and run

In Terminal, unzip the project, navigate into its folder, and run:

```sh
cd ~/Downloads/Velo
chmod +x build.sh
./build.sh
open dist/Velo.app
```

The build script compiles native Swift and produces `dist/Velo.app` using your Mac's developer tools. You do **not** need to publish the app or buy an Apple Developer subscription. The build script applies an ad-hoc signature for local use. macOS may ask you to approve opening an unsigned/developer-built app.

After launch, find the microphone icon on your menu bar. Click it or press **⌥⇧Space** to start speaking; press the shortcut again to finish and insert the result.

Allow **Microphone** and **Speech Recognition** when macOS prompts you. To enable auto-paste, select **Request Accessibility Permission…** from the app's menu, then enable the app in System Settings → Privacy & Security → Accessibility. If you rebuild or relocate an ad-hoc-signed app, you may need to reapprove permissions.

> **Privacy:** The code sets `requiresOnDeviceRecognition = true`, and refuses to start for unsupported on-device speech locales. The optional rewrite feature only connects to `127.0.0.1:11434` (Ollama). Transcripts are not persisted to disk by the app; the last transcription is kept in memory until quitting. When automatic insertion is used, the text temporarily goes through the system clipboard, and the app tries to restore the original clipboard after pasting. Clipboard restoration cannot be guaranteed for every app or exotic clipboard format.

## Personal dictionary

Menu → **Personal Dictionary**:

- **Add Word…** — the correct spelling (e.g. *Wispr Flow*) and, optionally, what dictation tends to hear instead (*whisper flow*). Words are fixed after recognition, used as hints by the speech engine, and sent to the optional AI rewrite so it never "corrects" them.
- **Add Snippet…** — a trigger phrase (e.g. *insert my email*) and the text to insert. Pick a phrase you wouldn't otherwise say. Stored in `snippets.json`.
- **Learn From My Corrections** (on by default) — after pasting, Velo watches that text field for up to 30 seconds. If you fix a word it misheard (e.g. *Velo* → *Velo*), the fix is added to your dictionary automatically and the pill shows "Learned …". Field contents are only read locally and never saved; only the learned word pair is. Choosing a different word (*good* → *great*) or rewriting a sentence is not learned.
- Click any entry to remove it. Everything works with the AI rewrite off and stays on this Mac.

## Teach proper names

In the menu bar, choose **Edit Personal Vocabulary…**. The app opens:

`~/Library/Application Support/BreezeDictate/vocabulary.json`

For example:

```json
{
  "gigadoo": "Giggadoo",
  "giga doo": "Giggadoo",
  "neon database": "NeonDB",
  "burp suite": "Burp Suite"
}
```

Keys are the speech recognizer's likely mistaken output; values are the preferred spelling. The values are also passed as recognition hints for later recordings. Save the file and start the next dictation; updates are reread every session. Keep this file valid JSON.

## Optional smart rewrite (higher memory use)

By default, the app performs only deterministic cleanup. This is fast and doesn't require Ollama.

If you need stronger grammar/structure rewriting and accept longer response times and temporary extra memory:

```sh
ollama pull gemma3:1b
ollama serve
```

If Ollama is already running, do not start another `ollama serve`. Enable **Smart Rewrite (needs Ollama)** in the menu. The app requests the local model only after you finish speaking, asks it to polish the text without changing meaning, and requests `keep_alive: 0` so Ollama will unload the model after generation. If Ollama is down or times out, the app inserts the regular cleaned transcript instead. This prototype **does not** implement semantic memory or automatic learning of facts; the lightweight JSON dictionary is the only persisted memory.

## Check actual RAM usage

1. Run Velo and open **Activity Monitor → Memory**.
2. Note the **Velo** memory footprint at idle, while dictating, and immediately after.
3. Compare responsiveness and accuracy using a 10-second sample, including your product names and technical terms.
4. The OS-managed speech model may use separate system services or neural-engine memory not all attributed to this app. Total pressure matters more than only the app's number.

## Limitations of this v0.1

- The code **has not been compiled or run on macOS** in the environment where it was prepared. It is supplied as a buildable-source prototype, not a claimed-tested binary. If the Mac build reports a Swift compiler error, copy the output to your coding assistant for a precise fix.
- Uses Apple's mature SFSpeechRecognizer, rather than the newer macOS 26 SpeechAnalyzer. SpeechAnalyzer is the intended next engine to benchmark for accuracy and latency on your machine.
- English (US) only. No Bangla recognition is promised.
- Can struggle with long continuous recordings and some technical terms; optimized for short, quick dictation.
- Text insertion into terminal shells, games, protected text fields, and remote desktop windows may differ. If insertion isn't allowed, the transcript is copied and the user can paste manually.
- Shortcut may be already reserved by another app; click menu icon if that happens.
- No wake-word, background recording, diarization, true learned writing style, or automatic cross-app memory.

## Uninstall

Quit Velo. Delete `dist/Velo.app` (and your source folder if desired). To remove its personal vocabulary and all stored settings, delete `~/Library/Application Support/BreezeDictate` and optional macOS preference `dev.local.BreezeDictate` (with `defaults delete dev.local.BreezeDictate` if it exists). The app itself does not install a third-party transcription model.

## Reference documentation

- [Apple: requiresOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [Apple: contextualStrings](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings)
- [Apple: SpeechAnalyzer (newer future backend)](https://developer.apple.com/documentation/speech/speechanalyzer)


## Velo branding and upgrade compatibility

Velo is the new product name. Build with `./build.sh`, then open `dist/Velo.app`.
The wave logo and app icon are in `Assets/Velo`; bundled resources are in `Resources`.
Earlier ghost artwork is archived in `Assets/LegacyBrand` and is not used by Velo.

The internal bundle ID `dev.local.BreezeDictate`, existing preference keys, Keychain service,
local signing identity and Application Support directory remain stable deliberately. This
preserves existing settings, vocabulary, snippets and API keys. macOS may still display the
previous name in an existing privacy-permission entry until it refreshes.
