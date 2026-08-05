# Audio / Inference Pipeline

## Sample rate and format

Everything downstream of capture is **16 kHz mono Float32** (CrisperWhisper / ECAPA native rate). Capture may run at device rate and resample with a linear resampler (or `AVAudioConverter` later).

## Stage 1 — Capture

Two explicit modes:

- **Meeting** — `MeetingRecorder` starts `MixedAudioCapture` (mic + optional ScreenCaptureKit system audio) and appends PCM until stop.
- **Dictation** — `DictationMicCapture` (mic only) while Fn is held, unless a meeting is already streaming (shared `onPCM`).

## Stage 2 — Classical DSP / VAD (library)

Per-frame DSP + VAD utilities remain in `AlethiaAudio` for tests and optional future silence trimming. They are **not** used to auto-open ambient conversations.

Python reference: [`Tools/dsp_reference`](../Tools/dsp_reference).

## Stage 3 — ASR (CrisperWhisper sidecar)

On dictation release or meeting stop:

- Encode PCM as WAV
- `POST` to local sidecar `http://127.0.0.1:8765/transcribe`
- Dictation uses `mode=intended`; meetings use `mode=verbatim`
- Map JSON segments → `TranscriptSegment`

Sidecar setup: `Scripts/setup-crisperwhisper.sh` / `Scripts/start-crisper-sidecar.sh`.

## Stage 4 — Diarization (meetings)

For each ASR utterance window (or fixed 1.5–3 s speech windows):

1. Compute 192-dim ECAPA-TDNN embedding (spectral fallback until GGML weights land)
2. Cluster embeddings within the session (agglomerative, cosine linkage)
3. Match cluster centroids to the **speaker gallery**
4. User rename → update gallery centroid (EMA) and rewrite labels

## Stage 5 — Persist

Write session + utterances (+ dictation rows) into SQLite / FTS5. Optional short audio retention is off by default; transcripts are kept.

## Latency budget

| Stage | Target |
|-------|--------|
| Dictation hold → release | mic buffer only |
| Sidecar RTF on M-series turbo | ≪ 1.0 after warm model |
| Meeting stop → saved session | ASR + diarization of full buffer |
