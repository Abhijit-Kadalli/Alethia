import numpy as np

from dsp import (
    ClassicalSpeechScorer,
    VADGate,
    analyze_frame,
    energy_vad_probability,
    synthesize_noise,
    synthesize_tone,
)


def test_silence_fails_noise_gate():
    frame = np.zeros(480, dtype=np.float32)
    features = analyze_frame(frame)
    assert features.rms == 0
    assert not features.passes_noise_gate


def test_speech_like_tone_passes_gate():
    tone = synthesize_tone(800, 0.03, amp=0.2)
    features = analyze_frame(tone)
    assert features.rms > 0.05
    assert features.passes_noise_gate


def test_male_f0_gets_high_probability():
    scorer = ClassicalSpeechScorer()
    # Warm floor on quiet noise first
    for _ in range(20):
        scorer.assess(synthesize_noise(0.03, amp=0.002))
    tone = synthesize_tone(120, 0.03, amp=0.12)
    a = scorer.assess(tone)
    assert a.energy_passed
    assert a.probability >= 0.50


def test_white_noise_capped_below_open_threshold():
    scorer = ClassicalSpeechScorer()
    for _ in range(30):
        a = scorer.assess(synthesize_noise(0.03, amp=0.08))
    # Steady white noise must not clear VAD open threshold after caps
    assert a.probability <= 0.28


def test_vad_hysteresis_opens_and_closes():
    gate = VADGate()
    for _ in range(5):
        assert gate.process(0.1, True, 30) == "silence"
    states = [gate.process(0.8, True, 30) for _ in range(6)]
    assert states[-1] == "speech"
    states = [gate.process(0.1, True, 30) for _ in range(20)]
    assert states[-1] == "silence"


def test_energy_vad_probability_range():
    silence = np.zeros(480, dtype=np.float32)
    speech = synthesize_tone(1000, 0.03, amp=0.25)
    assert energy_vad_probability(silence) < 0.1
    assert energy_vad_probability(speech) > 0.5


def test_binwise_sfm_tone_lower_than_noise():
    tone = synthesize_tone(800, 0.03, amp=0.2)
    noise = synthesize_noise(0.03, amp=0.2)
    assert analyze_frame(tone).spectral_flatness < analyze_frame(noise).spectral_flatness
