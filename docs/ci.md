# CI

## `dsp-reference` (Ubuntu)

Runs Python DSP/VAD reference tests under `Tools/dsp_reference`.

## `darwin` (macOS 14)

1. `Scripts/setup-crisperwhisper.sh` — create sidecar venv + install `crisperwhisper[transformers]`
2. Start sidecar with `ALETHIA_CRISPER_STUB=1` (no large model download in CI)
3. `swift build --build-tests` / `swift test --parallel`
4. Smoke `POST /transcribe` against `Fixtures/speech_short.wav`

Local mirror:

```bash
./Scripts/setup-crisperwhisper.sh
ALETHIA_CRISPER_STUB=1 ./Scripts/start-crisper-sidecar.sh &
swift test --parallel
```
