# Alethia

**Fully local** macOS app for meeting transcripts and speak-to-type dictation — with speaker diarization, persistent speaker naming, and an on-device knowledge base.

Alethia combines:

- **Meeting mode** (Granola-like) — click **Start Meeting Recording** in the menu bar; mic (+ optional system audio) records until you stop; audio is transcribed with CrisperWhisper, diarized, and stored locally.
- **Dictation mode** (Wispr-like) — hold **Fn**, speak, text is typed into the focused app; every dictation is also stored. Floating waveform overlay while active.
- **Knowledge** — transcripts, speakers, and dictations accumulate into a searchable local archive. Rename speakers over time.

Nothing leaves your Mac. No cloud ASR. No bot joins your meetings.

## Status

Active v1 development in this repo. Apple Silicon + macOS 14+.

CI:

| Workflow | Runner | Purpose |
|----------|--------|---------|
| `dsp-reference` | Ubuntu | Python DSP/VAD reference tests |
| `darwin` | **macOS 14** | `swift build` / `swift test` + CrisperWhisper sidecar smoke |

## Architecture (high level)

```
Mic / System Audio ──► Meeting buffer (while recording)
                              │
Fn hold ──► Dictation buffer ─┤
                              ▼
                    CrisperWhisper sidecar
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
         Diarization     Dictation paste   Knowledge
         (meetings)      (Accessibility)   (SQLite)
```

See [docs/architecture.md](docs/architecture.md) and [docs/pipeline.md](docs/pipeline.md).

## Repo layout

```
Apps/Alethia/           SwiftUI menu-bar app + Hub
Packages/
  AlethiaCore/          Shared models and permissions
  AlethiaAudio/         Capture, DSP, VAD, system audio, meeting recorder
  AlethiaASR/           CrisperWhisper sidecar client
  AlethiaDiarization/   Embeddings, clustering, gallery
  AlethiaDictation/     Hotkey (Fn), overlay, Accessibility typing
  AlethiaKnowledge/     SQLite store + FTS5 search
Tools/
  crisperwhisper_sidecar/  Local Python ASR HTTP server
  dsp_reference/           Python DSP/VAD reference
Scripts/                Sidecar setup + app packaging
Fixtures/               Short WAV for CI smoke
.github/workflows/      dsp-reference.yml + darwin.yml
```

## Requirements

For the release DMG:

- Apple Silicon Mac, macOS 14+
- Internet access on first launch to download approximately 550 MB of model weights
- Approximately 1.5 GB free disk space for the app, runtime, and model cache
- Microphone permission
- Accessibility permission (dictation paste + global Fn)
- Screen Recording (system audio for meetings, macOS 14.4+)

The release app bundles its Python/CrisperWhisper runtime. Model weights download on first launch into `~/Library/Application Support/Alethia/Models`; no repository clone or system Python installation is required.

Building from source additionally requires Xcode 15+ / Swift 5.9+ and Python 3.10+.

## Quick start (Mac)

```bash
git clone https://github.com/Abhijit-Kadalli/Alethia.git
cd Alethia
./Scripts/setup-crisperwhisper.sh   # Python venv + CrisperWhisper
./Scripts/start-crisper-sidecar.sh  # leave running (or use run-app.sh)
swift test                          # same checks as Darwin CI (stub sidecar in CI)
./Scripts/run-app.sh                # package, start sidecar, launch app
```

Grant permissions when prompted. Menu bar: start meeting recording. Hold **Fn** to dictate.

## CI locally

```bash
# Linux / any OS — DSP reference
cd Tools/dsp_reference && python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt && pytest -q

# macOS — mirrors GitHub Actions darwin job
./Scripts/setup-crisperwhisper.sh
ALETHIA_CRISPER_STUB=1 ./Scripts/start-crisper-sidecar.sh &
swift test --parallel
```

## Privacy

All audio and transcripts stay on device. Meeting recording shows a visible menu-bar indicator. You are responsible for obtaining consent when recording others. See [docs/privacy.md](docs/privacy.md).

## License

MIT — see [LICENSE](LICENSE).
