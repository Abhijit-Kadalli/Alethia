# Alethia

**Fully local** macOS app for ambient conversation capture and speak-to-type dictation — with speaker diarization, persistent speaker naming, and an on-device knowledge base.

Alethia combines:

- **Ambient mode** (Granola-like) — microphone (+ optional system audio) always on; DSP + VAD detects useful speech; conversations are segmented, diarized, and stored locally.
- **Dictation mode** (Wispr-like) — hold **Right Option**, speak, text is typed into the focused app; every dictation is also stored. Floating waveform overlay while active.
- **Knowledge** — transcripts, speakers, and dictations accumulate into a searchable local archive. Rename speakers over time.

Nothing leaves your Mac. No cloud ASR. No bot joins your meetings.

## Status

Active v1 development in this repo. Apple Silicon + macOS 14+.

CI:

| Workflow | Runner | Purpose |
|----------|--------|---------|
| `dsp-reference` | Ubuntu | Python DSP/VAD reference tests |
| `darwin` | **macOS 14** | `swift build` / `swift test` + whisper.cpp smoke |

## Architecture (high level)

```
Mic / System Audio ──► DSP + VAD ──► Conversation segments
                                         │
                    ┌────────────────────┼────────────────────┐
                    ▼                    ▼                    ▼
              whisper.cpp          ECAPA / spectral     Dictation paste
              (Metal CLI)          embeddings           (Accessibility)
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
  AlethiaAudio/         Capture, DSP, VAD, system audio, segmenter
  AlethiaASR/           whisper.cpp CLI bridge
  AlethiaDiarization/   Embeddings, clustering, gallery
  AlethiaDictation/     Hotkey, overlay, Accessibility typing
  AlethiaKnowledge/     SQLite store + FTS5 search
Tools/dsp_reference/    Python DSP/VAD reference
Scripts/                Model + whisper.cpp Darwin setup
Fixtures/               Short WAV for CI smoke
.github/workflows/      dsp-reference.yml + darwin.yml
```

## Requirements

- Apple Silicon Mac, macOS 14+
- Xcode 15+ / Swift 5.9+
- Microphone permission
- Accessibility permission (dictation paste)
- Screen Recording (system audio for meetings, macOS 14.4+)

## Quick start (Mac)

```bash
git clone https://github.com/Abhijit-Kadalli/Alethia.git
cd Alethia
./Scripts/setup-whisper-darwin.sh   # builds whisper.cpp + tiny model
./Scripts/download-models.sh        # optional larger turbo model
swift test                          # same checks as Darwin CI
swift run Alethia                   # or open Package.swift in Xcode
```

Grant permissions when prompted. Menu bar: start ambient. Hold Right Option to dictate.

## CI locally

```bash
# Linux / any OS — DSP reference
cd Tools/dsp_reference && python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && pytest -q

# macOS — mirrors GitHub Actions darwin job
./Scripts/setup-whisper-darwin.sh
swift test --parallel
```

## Privacy

All audio and transcripts stay on device. Ambient listening shows a menu-bar indicator. You are responsible for obtaining consent when recording others. See [docs/privacy.md](docs/privacy.md).

## License

MIT — see [LICENSE](LICENSE).
