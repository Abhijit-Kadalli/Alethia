"""Classical DSP front-end for Alethia ambient gating.

Mirrors Packages/AlethiaAudio/... (DSPAnalyzer, AdaptiveNoiseFloor, ClassicalSpeechScorer)
so CI can validate signal-processing heuristics without a Mac / Swift toolchain.
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
        """Absolute high-recall floor without adaptive context."""
        return self.rms >= 0.004


def analyze_frame(frame: np.ndarray, sample_rate: float = 16_000.0) -> DSPFrameFeatures:
    frame = np.asarray(frame, dtype=np.float32)
    if frame.size == 0:
        return DSPFrameFeatures(0.0, 0.0, 1.0, 0.0)

    rms = float(np.sqrt(np.mean(frame * frame)))
    signs = frame >= 0
    zcr = float(np.mean(signs[1:] != signs[:-1])) if frame.size > 1 else 0.0

    power, n_fft = _power_spectrum(frame)
    flatness = _spectral_flatness(power)
    ratio = _speech_band_ratio(power, sample_rate, n_fft, 85.0, 5500.0)

    return DSPFrameFeatures(rms, zcr, flatness, ratio)


def is_noise_like(features: DSPFrameFeatures) -> bool:
    return features.spectral_flatness >= 0.35 or features.speech_band_ratio < 0.12


def _power_spectrum(frame: np.ndarray) -> tuple[np.ndarray, int]:
    n = frame.size
    if n <= 1:
        windowed = frame.astype(np.float64)
    else:
        hann = 0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(n) / (n - 1))
        windowed = frame.astype(np.float64) * hann
    spec = np.fft.rfft(windowed)
    power = (spec.real * spec.real + spec.imag * spec.imag).astype(np.float64)
    return power, n


def _spectral_flatness(power: np.ndarray) -> float:
    bins = power[1:]  # skip DC
    if bins.size == 0:
        return 1.0
    bins = np.maximum(bins, 1e-12)
    geo = float(np.exp(np.mean(np.log(bins))))
    arith = float(np.mean(bins))
    if arith <= 0:
        return 1.0
    return float(min(max(geo / arith, 0.0), 1.0))


def _speech_band_ratio(
    power: np.ndarray, sample_rate: float, n_fft: int, low_hz: float, high_hz: float
) -> float:
    if power.size <= 1 or n_fft <= 0:
        return 0.0
    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sample_rate)
    total = float(np.sum(power[1:]))
    if total <= 0:
        return 0.0
    mask = (freqs >= low_hz) & (freqs < high_hz)
    mask[0] = False
    speech = float(np.sum(power[mask]))
    return speech / max(total, 1e-12)


class AdaptiveNoiseFloor:
    def __init__(
        self,
        initial: float = 0.01,
        rise_alpha: float = 0.05,
        fall_alpha: float = 0.25,
        min_floor: float = 0.002,
        margin: float = 1.8,
    ) -> None:
        self.floor = max(initial, min_floor)
        self.rise_alpha = rise_alpha
        self.fall_alpha = fall_alpha
        self.min_floor = min_floor
        self.margin = margin

    def energy_passed(self, rms: float) -> bool:
        return rms >= max(0.004, self.margin * self.floor)

    def update(self, rms: float, noise_like: bool) -> None:
        if not noise_like:
            return
        if rms > self.floor:
            self.floor = (1.0 - self.rise_alpha) * self.floor + self.rise_alpha * rms
        else:
            self.floor = (1.0 - self.fall_alpha) * self.floor + self.fall_alpha * rms
        self.floor = max(self.floor, self.min_floor)

    def reset(self, initial: float = 0.01) -> None:
        self.floor = max(initial, self.min_floor)


@dataclass
class SpeechAssessment:
    probability: float
    energy_passed: bool
    features: DSPFrameFeatures


class ClassicalSpeechScorer:
    def __init__(self) -> None:
        self.noise_floor = AdaptiveNoiseFloor()

    def assess(self, frame: np.ndarray, sample_rate: float = 16_000.0) -> SpeechAssessment:
        features = analyze_frame(frame, sample_rate)
        noise_like = is_noise_like(features)
        self.noise_floor.update(features.rms, noise_like)
        energy_passed = self.noise_floor.energy_passed(features.rms)
        p = self._score(features, energy_passed, self.noise_floor.floor)

        if features.spectral_flatness >= 0.40:
            p = min(p, 0.28)
        if features.spectral_flatness < 0.25 and features.speech_band_ratio < 0.08:
            p = min(p, 0.22)  # sub-bass rumble below ~85 Hz
        if not energy_passed:
            p = min(p, 0.20)

        return SpeechAssessment(p, energy_passed, features)

    def probability(self, frame: np.ndarray) -> float:
        return self.assess(frame).probability

    def reset(self) -> None:
        self.noise_floor.reset()

    @staticmethod
    def _score(features: DSPFrameFeatures, energy_passed: bool, floor: float) -> float:
        if not energy_passed:
            return 0.05
        thresh = max(0.004, 1.8 * floor)
        energy = min(max((features.rms - thresh) / max(0.04, thresh * 3), 0.0), 1.0)
        sfm_structure = min(max(1.0 - features.spectral_flatness / 0.55, 0.0), 1.0)
        band_structure = min(max((features.speech_band_ratio - 0.08) / 0.55, 0.0), 1.0)
        structure = 0.55 * sfm_structure + 0.45 * band_structure
        p = 0.15 + 0.75 * (0.45 * energy + 0.55 * structure)
        if 0.08 < features.zero_crossing_rate < 0.45:
            p += 0.08 * min(features.zero_crossing_rate / 0.25, 1.0)
        return float(min(max(p, 0.0), 1.0))


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
    """Compatibility wrapper — uses ClassicalSpeechScorer (stateful per call is fresh)."""
    return ClassicalSpeechScorer().probability(frame)


def synthesize_tone(
    freq_hz: float, duration_s: float, sample_rate: float = 16_000.0, amp: float = 0.1
) -> np.ndarray:
    t = np.arange(0, duration_s, 1.0 / sample_rate, dtype=np.float32)
    return (amp * np.sin(2 * math.pi * freq_hz * t)).astype(np.float32)


def synthesize_noise(duration_s: float, sample_rate: float = 16_000.0, amp: float = 0.1) -> np.ndarray:
    n = int(duration_s * sample_rate)
    return (amp * np.random.randn(n)).astype(np.float32)
