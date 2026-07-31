# Audio / Inference Pipeline

## Sample rate and format

Everything downstream of capture is **16 kHz mono Float32** (whisper/ECAPA native rate). Capture may run at device rate and resample with `AVAudioConverter`.

## Stage 1 — Capture

- Microphone via `AVAudioEngine` input tap (primary).
- Optional system audio via `ScreenCaptureKit` audio stream (meetings without a bot).
- Mixed to a single mono ring buffer (~30–60 s capacity for late binding).

## Stage 2 — Classical DSP (always on)

Per 20–30 ms frame (see [`dsp_vad_redesign.md`](dsp_vad_redesign.md)):

| Feature | Use |
|---------|-----|
| RMS + adaptive floor | High-recall energy gate only |
| Bin-wise spectral flatness (Hann) | Structure for speech probability |
| Speech band 85–5500 Hz | Structure + rumble reject |
| Zero-crossing rate | Unvoiced / fricative boost |

`ClassicalSpeechScorer` produces `probability` + `energyPassed`. Failed energy caps `p` at 0.2 in `VADGate`.

Python reference: [`Tools/dsp_reference`](../Tools/dsp_reference).

## Stage 3 — Speech probability + hysteresis

Default: classical scorer (Silero protocol-ready later). Hysteresis:

- Open speech when `p ≥ 0.5` for ≥150 ms
- Close speech when `p ≤ 0.35` for ≥500 ms

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
