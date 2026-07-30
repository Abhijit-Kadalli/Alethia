# Audio / Inference Pipeline

## Sample rate and format

Everything downstream of capture is **16 kHz mono Float32** (whisper/ECAPA native rate). Capture may run at device rate and resample with `AVAudioConverter`.

## Stage 1 — Capture

- Microphone via `AVAudioEngine` input tap (primary).
- Optional system audio via `ScreenCaptureKit` audio stream (meetings without a bot).
- Mixed to a single mono ring buffer (~30–60 s capacity for late binding).

## Stage 2 — Classical DSP (always on)

Per 20–30 ms frame:

| Feature | Use |
|---------|-----|
| RMS energy | Noise gate / adaptive threshold |
| Zero-crossing rate | Rough voiced vs unvoiced |
| Spectral flatness | Reject noise-like frames |
| Band energy ratios | Boost speech band confidence |

Frames that fail the noise gate never reach VAD/ASR.

Python reference: [`Tools/dsp_reference`](../Tools/dsp_reference).

## Stage 3 — Silero VAD

Neural VAD outputs speech probability per frame. Hysteresis:

- Open speech when `p > 0.5` for ≥150 ms
- Close speech when `p < 0.35` for ≥400 ms

## Stage 4 — Conversation segmenter

A **conversation** opens when sustained speech exceeds a usefulness bar:

- ≥ 2 s cumulative speech within a 8 s window, **or**
- ≥ 1.5 s continuous speech with high VAD confidence

It closes after ~4–6 s of silence (configurable) once minimum content exists.

Short bursts (coughs, “hey”) are discarded and never create sessions.

## Stage 5 — ASR (whisper.cpp)

On conversation close (and optionally mid-conversation chunks):

- Run whisper on speech-only PCM (silence already stripped)
- Prefer Metal GPU + Core ML encoder on Apple Silicon
- Emit segments with start/end timestamps

Dictation mode uses the same ASR path on the hotkey-gated buffer.

## Stage 6 — Diarization

For each ASR utterance window (or fixed 1.5–3 s speech windows):

1. Compute 192-dim ECAPA-TDNN embedding
2. Cluster embeddings within the session (agglomerative, cosine linkage)
3. Match cluster centroids to the **speaker gallery** (cosine ≥ threshold → known name; else `Speaker N`)
4. User rename → update gallery centroid (EMA) and rewrite labels

## Stage 7 — Persist

Write session + utterances (+ dictation rows) into SQLite / FTS5. Optional short audio retention is off by default; transcripts are kept.

## Latency budget (ambient)

| Stage | Target |
|-------|--------|
| DSP + VAD | &lt; 5 ms / frame |
| Segment close → ASR start | immediate |
| ASR RTF on M-series turbo | ≪ 1.0 |
| Diarization per minute speech | seconds, offline to UI |
