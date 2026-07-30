# Alethia

**Fully local** macOS app for ambient conversation capture and speak-to-type dictation — with speaker diarization, persistent speaker naming, and an on-device knowledge base.

Alethia combines:

- **Ambient mode** (Granola-like) — microphone always on; signal-processing VAD detects useful speech; conversations are segmented, diarized, and stored locally.
- **Dictation mode** (Wispr-like) — hold a hotkey, speak, text is typed into the focused app; every dictation is also stored.
- **Knowledge** — transcripts, speakers, and dictations accumulate into a searchable local archive.

Nothing leaves your Mac. No cloud ASR. No bot joins your meetings.

## Status

Early scaffold. Apple Silicon (M-series) + macOS 14+ are the v1 targets. Build the app on a Mac with Xcode 15+.

## Architecture (high level)

```
Mic / System Audio ──► DSP + Silero VAD ──► Conversation segments
                                              │
                         ┌────────────────────┼────────────────────┐
                         ▼                    ▼                    ▼
                   whisper.cpp          ECAPA embeddings     Dictation paste
                   (Metal/CoreML)       + clustering         (Accessibility)
                         │                    │                    │
                         └────────────► SQLite knowledge ◄─────────┘
                                              │
                                       Hub search / timeline
```

See [docs/architecture.md](docs/architecture.md) and [docs/pipeline.md](docs/pipeline.md).

## Repo layout

```
Apps/Alethia/           SwiftUI menu-bar app + Hub
Packages/
  AlethiaCore/          Shared models and permissions
  AlethiaAudio/         Capture, DSP, VAD, conversation segmenter
  AlethiaASR/           whisper.cpp bridge
  AlethiaDiarization/   Speaker embeddings, clustering, gallery
  AlethiaDictation/     Hotkey + Accessibility typing
  AlethiaKnowledge/     SQLite store + search
Tools/dsp_reference/    Python DSP/VAD reference (CI-testable)
Scripts/                Model download helpers
Models/                 Downloaded weights (gitignored)
docs/                   Architecture, pipeline, privacy
```

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 15+
- Microphone permission
- Accessibility permission (dictation paste)
- System Audio / Screen Recording (macOS 14.4+) for meeting capture without a bot

## Quick start (Mac)

```bash
git clone https://github.com/Abhijit-Kadalli/Alethia.git
cd Alethia
./Scripts/download-models.sh
open Package.swift   # or open the Xcode project once generated
```

Build the `Alethia` app target and run. Grant permissions when prompted.

## DSP reference (Linux / CI)

```bash
cd Tools/dsp_reference
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pytest -q
```

## Privacy

All audio and transcripts stay on device. Ambient listening shows a menu-bar indicator. You are responsible for obtaining consent when recording others. See [docs/privacy.md](docs/privacy.md).

## License

MIT — see [LICENSE](LICENSE).
