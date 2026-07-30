"""Classical DSP front-end for Alethia ambient gating.

Mirrors Packages/AlethiaAudio/.../DSPAnalyzer.swift so CI can validate
signal-processing heuristics without a Mac / Swift toolchain.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np


@dataclass
class DSPFrameFeatures:
    rms: float
    zero_crossing_rate: float
    spectral_flatness: float
    speech_band_ratio: float

    @property
    def passes_noise_gate(self) -> bool:
        return (
            self.rms > 0.008
            and self.spectral_flatness < 0.55
            and self.speech_band_ratio > 0.25
        )


def analyze_frame(frame: np.ndarray, sample_rate: float = 16_000.0) -> DSPFrameFeatures:
    frame = np.asarray(frame, dtype=np.float32)
    if frame.size == 0:
        return DSPFrameFeatures(0.0, 0.0, 1.0, 0.0)

    rms = float(np.sqrt(np.mean(frame * frame)))
    signs = frame >= 0
    zcr = float(np.mean(signs[1:] != signs[:-1])) if frame.size > 1 else 0.0

    energies = _band_energies(frame, sample_rate)
    energies = np.maximum(energies, 1e-12)
    geo = float(np.exp(np.mean(np.log(energies))))
    arith = float(np.mean(energies))
    flatness = geo / arith if arith > 0 else 1.0
    speech = float(energies[1] + energies[2])
    total = float(np.sum(energies))
    ratio = speech / total

    return DSPFrameFeatures(rms, zcr, flatness, ratio)


def _band_energies(frame: np.ndarray, sample_rate: float) -> np.ndarray:
    n = frame.size
    nyquist = sample_rate / 2.0
    edges = np.array([0.0, 300.0, 1000.0, 3400.0, nyquist], dtype=np.float64)
    energies = np.zeros(len(edges) - 1, dtype=np.float64)
    # RFFT magnitude energy into coarse bands
    spec = np.fft.rfft(frame)
    mags2 = (spec.real * spec.real + spec.imag * spec.imag).astype(np.float64)
    freqs = np.fft.rfftfreq(n, d=1.0 / sample_rate)
    for b in range(len(energies)):
        mask = (freqs >= edges[b]) & (freqs < edges[b + 1])
        energies[b] = float(np.sum(mags2[mask]))
    return energies


@dataclass
class VADConfig:
    open_threshold: float = 0.50
    close_threshold: float = 0.35
    open_ms: int = 150
    close_ms: int = 500


class VADGate:
    def __init__(self, config: VADConfig | None = None) -> None:
        self.config = config or VADConfig()
        self.state = "silence"
        self._open_ms = 0
        self._close_ms = 0

    def process(self, probability: float, dsp_passed: bool, frame_ms: int) -> str:
        p = probability if dsp_passed else min(probability, 0.2)
        if self.state == "silence":
            if p >= self.config.open_threshold:
                self._open_ms += frame_ms
                if self._open_ms >= self.config.open_ms:
                    self.state = "speech"
                    self._open_ms = 0
                    self._close_ms = 0
            else:
                self._open_ms = 0
        else:
            if p <= self.config.close_threshold:
                self._close_ms += frame_ms
                if self._close_ms >= self.config.close_ms:
                    self.state = "silence"
                    self._close_ms = 0
                    self._open_ms = 0
            else:
                self._close_ms = 0
        return self.state


def energy_vad_probability(frame: np.ndarray) -> float:
    features = analyze_frame(frame)
    if not features.passes_noise_gate:
        return 0.05
    x = min(max((features.rms - 0.008) / 0.05, 0.0), 1.0)
    return 0.2 + 0.75 * x


def synthesize_tone(freq_hz: float, duration_s: float, sample_rate: float = 16_000.0, amp: float = 0.1) -> np.ndarray:
    t = np.arange(0, duration_s, 1.0 / sample_rate, dtype=np.float32)
    return (amp * np.sin(2 * math.pi * freq_hz * t)).astype(np.float32)
