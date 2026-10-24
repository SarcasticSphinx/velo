<p align="center"><img src="Assets/Velo/Velo-Logo.png" alt="Velo — Speak. It flows." width="720"></p>

# Velo

A native macOS menu-bar dictation app. Hold a key, speak, and release to insert text into your original application. Double-tap for hands-free dictation. Speech recognition runs on-device; optional rewriting uses local Ollama or OpenRouter.

## Features

- Configurable Right Option, Right Command, or Fn/Globe dictation key.
- Hold-to-dictate and double-tap locking, with a floating waveform and transcript pill.
- Automatic insertion, clipboard fallback, and in-memory recent transcripts.
- Personal vocabulary, snippets, and optional learning from corrections.
- Offline cleanup, spoken line breaks, and list formatting without an LLM.
- Optional Ollama or OpenRouter text cleanup.
- Native template menu-bar icon that follows light and dark appearance, including while recording.

## Requirements

- macOS 13 or later; Apple Silicon recommended.
- Xcode or Command Line Tools with the **macOS 26 SDK to build** the current source, which references SpeechAnalyzer. The compiled app has a macOS 13 deployment target.
- English (US) on-device speech assets. On macOS 26, Velo prepares SpeechTranscriber and may download assets on first use. Until ready, or on older systems, it uses the classic on-device recognizer. Unsupported local recognition fails rather than falling back to cloud speech recognition.

## Build and launch

```sh
git clone https://github.com/SarcasticSphinx/velo.git
cd velo
./build.sh
open dist/Velo.app
```

The build produces a local app for the current architecture. It reuses the historical `BreezeDictate Local Signing` certificate when installed, otherwise signs ad hoc. Select another existing identity with `VELO_SIGNING_IDENTITY="Your identity" ./build.sh`. The script does not create certificates or reset permissions. This is a developer build, not a notarized distribution; generated `dist/` files are excluded from source control.

## Permissions

Allow **Microphone** and **Speech Recognition** when requested. Enable Velo under **System Settings → Privacy & Security → Accessibility** for automatic insertion. The menu provides permission status and an Accessibility request action.

After a rebuild, if paste stops working, quit Velo, remove its old Accessibility entry, add the current `dist/Velo.app`, enable it, and relaunch. An older permission entry may still show the BreezeDictate name.

## Controls

| Action | Control |
| --- | --- |
| Hold to dictate | Right Option by default; release to finish |
| Hands-free recording | Double-tap the selected key; tap again to finish |
| Toggle recording | Option + Shift + Space |
| Paste last transcript | Option + Shift + V |
| Change dictation key | Menu → Dictation Key |

For Fn/Globe, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing** to avoid conflicts. Other shortcuts using the selected modifier may cancel a newly started recording.

Focus a text field before starting. Pauses do not intentionally end recording. If insertion is unavailable, Velo copies the text for manual paste. Recent Transcripts keeps up to 15 entries in memory until quitting. Sound effects are optional.

## Optional rewriting

Choose a provider in the menu:

- **Off:** on-device recognition and deterministic cleanup only.
- **Local Ollama:** run Ollama separately and install `gemma3:1b` with `ollama pull gemma3:1b`. Velo requests `keep_alive: 0` after generation. It does not launch Ollama or modify other models.
- **OpenRouter:** use **Configure OpenRouter API Key…**, save your key, then select OpenRouter rewriting. Keys are stored in macOS Keychain; your account needs credits. Model options include GPT-OSS 120B (default, preferentially routed to Groq/Cerebras), Gemini 2.5 Flash Lite, and GPT-4o mini. Availability, latency, and charges depend on the provider.

Rewriting makes light edits and attempts to preserve meaning. Short dictations may skip it; failures or excessive changes fall back to cleaned recognition text. Review important output before sending it.

## Privacy and storage

- Microphone audio is recognized on-device, not sent to Ollama or OpenRouter by Velo.
- With OpenRouter selected, transcript text, vocabulary hints, and destination-app context are sent to OpenRouter and its model provider. Cloud rewriting is optional.
- Ollama rewriting requests go to `127.0.0.1:11434`.
- Transcript history is kept in memory. Automatic insertion uses the clipboard, which other clipboard-history software may independently retain.
- **Learn From My Corrections** briefly observes the destination field after insertion and saves inferred word corrections locally. It can be disabled in the menu.
- Vocabulary and snippets remain under `~/Library/Application Support/BreezeDictate/`. The historical directory, preferences, bundle ID (`dev.local.BreezeDictate`), and Keychain service deliberately remain stable to preserve upgrades.
- Lifecycle logs exclude transcript text and API keys. Never commit keys, personal dictionaries, or signing credentials.

## Dictionary and snippets

Use **Personal Dictionary → Add Word…** for preferred spellings and **Add Snippet…** for reusable phrases. Vocabulary is applied after recognition and used as hints where supported, including by the optional rewrite provider.

Say “new line” or “new paragraph” for line breaks. Spoken numbered items and “bullet point” phrases can become lists using offline cleanup rules.

## Development

```sh
./test-engine.sh
./test-cleanup.sh
./build.sh
```

Tests cover recording intent, transcript accumulation, recognition policy, cleanup, and correction-learning rules. They do not replace real keyboard, microphone, permission, or cross-application insertion checks.

| Path | Purpose |
| --- | --- |
| `Sources/` | Swift application, speech, hotkey, insertion, rewrite and dictionary logic |
| `Tests/`, `test-*.sh` | Regression checks |
| `Resources/` | Bundled icons |
| `Assets/Velo/` | Brand masters, icon sizes, menu-mark export source |
| `Info.plist` | Bundle metadata and privacy descriptions |
| `dist/` | Generated local app, ignored by Git |

## Troubleshooting

- **Icon contrast:** the template wave uses macOS's menu-bar foreground color in every recording state.
- **No speech:** check Sound → Input, permissions, and English (US) speech assets. Inspect the app's status menu.
- **No insertion:** check Accessibility and try a normal TextEdit field. Protected fields and some apps may reject paste.
- **Shortcut conflict:** change Dictation Key or use the menu. Fn/Globe may conflict with system input switching.
- **OpenRouter failure:** check the key, credits, selected model and network. Cleaned recognition text remains the fallback.
- **Build errors:** select developer tools containing the macOS 26 SDK.

## Branding

Velo — **Speak. It flows.** See [the brand asset README](Assets/Velo/README.md) for the active wave artwork, generation provenance, and export details.
