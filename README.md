# Alethia

Speak instead of type, and get meeting notes written for you. Everything runs on your Mac.

Alethia is a native macOS menu-bar app (Apple silicon, macOS 14+) that combines:

- **Dictation** — hold a key, talk, release. Clean, punctuated text lands in whatever app has focus. Fillers are removed, "scratch that" works, numbers and emails are formatted, and the style adapts to the app (casual in Slack, no trailing period in a search box). A small popover lets you fix the result for a few seconds; edits teach a personal dictionary so the same word comes out right next time.
- **Meetings** — Alethia notices when a call starts and offers to take notes. It records your mic and the other participants (system audio), shows a live transcript, then separates speakers, recognizes people it has heard before, and writes structured notes from a template (general, 1:1, standup, interview, sales call, lecture, brainstorm). Your own typed notes sit next to the generated ones.
- **Knowledge** — meetings, transcripts, notes and dictations are stored in a local SQLite database with full-text search.

No account. No cloud speech. Nothing leaves the Mac unless you deliberately connect a language model server.

## How it works

The app itself is under 10 MB. On first launch it downloads open-source speech models (~650 MB) that run on the Neural Engine:

| Job | Model | Runtime | License |
|-----|-------|---------|---------|
| Speech recognition | NVIDIA Parakeet TDT 0.6B v2 (English) or v3 (25 languages) | [FluidAudio](https://github.com/FluidInference/FluidAudio) CoreML | CC-BY-4.0 / Apache-2.0 |
| Voice activity | Silero VAD v6 | FluidAudio CoreML | MIT |
| Speaker separation | pyannote segmentation + WeSpeaker embeddings | FluidAudio CoreML | CC-BY-4.0 |
| Notes and polish (optional) | Apple Intelligence, or any OpenAI-compatible server (Ollama, LM Studio, llama.cpp, OpenAI, …) | — | — |

Parakeet TDT is at the top of the Open ASR leaderboard for English (≈6% WER) and transcribes about 200× faster than real time on the Neural Engine, so a one-hour meeting is ready in under a minute. Without a language model, Alethia still produces heuristic notes (decisions, action items, questions) from the transcript with rules.

See [docs/architecture.md](docs/architecture.md) for the pipeline and [docs/privacy.md](docs/privacy.md) for what is stored where.

## Install

Download `Alethia.dmg` from the latest [release](https://github.com/Abhijit-Kadalli/Alethia/releases), drag Alethia to Applications, and open it. The onboarding flow walks through:

1. **Microphone** — required.
2. **Accessibility** — required for the global dictation hotkey and for inserting text at the cursor.
3. **Screen & System Audio Recording** — optional; captures the other side of calls. Alethia never records the screen.
4. **Calendar** — optional; names meetings after the event you are in.
5. **Model download** — once, about 650 MB, into `~/Library/Application Support/FluidAudio/Models` (shared with other FluidAudio apps).

Then hold **Fn** (configurable: right ⌥, right ⌘, left ⌃, F5) to dictate, or click the menu-bar waveform to record a meeting.

## Build from source

Requirements: Xcode 16 or newer (Swift 5.10+), Apple silicon.

```bash
git clone https://github.com/Abhijit-Kadalli/Alethia.git
cd Alethia
swift test                 # unit tests (also run on Linux CI for the platform-independent modules)
./Scripts/run-app.sh       # build, package Alethia.app into ~/Applications, launch
```

`Scripts/package-app.sh` assembles a signed `.app` (ad-hoc by default; set `ALETHIA_CODESIGN_IDENTITY` for Developer ID) and fails if the bundle exceeds the 10 MiB budget. `Scripts/package-dmg.sh` wraps it in a DMG and notarizes when `ALETHIA_NOTARY_*` are set. Tagging `v*` runs the release workflow.

## Repository layout

```
Sources/
  AlethiaCore/        Models, settings, permissions, WAV codec, transcript ↔ speaker alignment
  AlethiaText/        Dictation formatter (fillers, self-corrections, voice commands, smart formatting,
                      app-aware style, dictionary/snippets), notes generation, LLM client
  AlethiaKnowledge/   SQLite + FTS5 store (meetings, utterances, speakers, dictations, dictionary,
                      snippets, templates) with change notifications
  AlethiaAudio/       Microphone and system-audio capture, mixer, WAV writer, mic-activity monitor
  AlethiaSpeech/      FluidAudio integration: ASR, live partials, VAD, diarization, model manager
  AlethiaDictation/   Global hotkey, overlay, text insertion (AX / paste / keystrokes), correction popover
  AlethiaMeetings/    Recorder, processor pipeline, meeting detection, calendar
  AlethiaApp/         Menu bar, onboarding, Hub (meetings, notes, transcript, history, dictionary, settings)
  CSQLite/            System SQLite module map
Tests/                XCTest targets; Core, Text, Knowledge and Audio run on Linux too
App/                  Info.plist, entitlements, icon
Scripts/              Packaging, DMG, icon, developer run loop
```

## Privacy and consent

Audio, transcripts and notes stay on the device. A red menu-bar indicator is visible while recording. You are responsible for obtaining consent from the people you record where the law requires it.

## License

MIT — see [LICENSE](LICENSE). Model weights carry their own licenses (listed above and in Settings › General).
