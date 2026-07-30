# Continuous integration

Alethia uses two GitHub Actions workflows:

## `dsp-reference` (Ubuntu)

Runs the Python signal-processing reference under `Tools/dsp_reference`.
Validates DSP/VAD heuristics that mirror the Swift front-end.

## `darwin` (macOS 14)

Runs on Apple Silicon GitHub-hosted runners:

1. `Scripts/setup-whisper-darwin.sh` — clone/build whisper.cpp with Metal, fetch `ggml-tiny.bin` (cached)
2. `swift build --build-tests`
3. `swift test --parallel`
4. Smoke `whisper-cli` against `Fixtures/speech_short.wav`

Headless runners do **not** exercise live microphone, Accessibility paste, or ScreenCaptureKit permission prompts. Those remain manual checks on a physical Mac.

PRs that change `Packages/**`, `Apps/**`, or `Package.swift` should stay green on **darwin**.
