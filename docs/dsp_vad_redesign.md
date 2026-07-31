# DSP / VAD redesign

## Problem

The v1 gate

`rms > 0.008 AND spectralFlatness < 0.55 AND speechBandRatio > 0.25`

rejected a large share of real speech (measured ~36% of active speech on an NPR Up First clip — male F0 / fricatives). Failed frames cap VAD `p` at 0.2, so conversations may never open.

## Design

| Piece | Role |
|-------|------|
| Bin-wise spectral flatness (Hann + power spectrum, skip DC) | Noise high, speech low |
| Adaptive noise floor (asymmetric EMA; noise-like frames only) | Sohn / WebRTC-style |
| High-recall energy gate only (`rms >= max(0.004, 1.8 * floor)`) | Precision is **not** in the gate |
| Speech probability: energy × structure(SFM, 85–5500 Hz band) + ZCR boost | Unvoiced path |
| Hard caps: SFM≥0.40 → p≤0.28; low-SFM + band&lt;0.08 → p≤0.22 | Reject white noise / rumble |
| Hysteresis open 150 ms @ p≥0.50 / close 500 ms @ p≤0.35 | Stable sessions |

## Types

- Swift: `DSPAnalyzer`, `AdaptiveNoiseFloor`, `ClassicalSpeechScorer` (`assess` → probability + energyPassed), `VADGate`
- Python mirror: `Tools/dsp_reference/dsp.py` (must stay in sync — Ubuntu CI)

## Target metrics (NPR Up First 90s from t=120s)

Gate recall on active speech ≈ **98.6%** (was ~64%); mean p active/quiet ≈ **0.90 / 0.10**; white-noise stream does not open VAD; male F0=120 does.
