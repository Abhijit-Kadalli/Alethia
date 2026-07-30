import numpy as np

from dsp import VADGate, analyze_frame, energy_vad_probability, synthesize_tone


def test_silence_fails_noise_gate():
    frame = np.zeros(480, dtype=np.float32)
    features = analyze_frame(frame)
    assert features.rms == 0
    assert not features.passes_noise_gate


def test_speech_like_tone_passes_gate():
    # 800 Hz is inside speech bands
    tone = synthesize_tone(800, 0.03, amp=0.2)
    features = analyze_frame(tone)
    assert features.rms > 0.05
    assert features.passes_noise_gate


def test_vad_hysteresis_opens_and_closes():
    gate = VADGate()
    # Stay silent
    for _ in range(5):
        assert gate.process(0.1, True, 30) == "silence"
    # Open after enough high-prob frames (150ms)
    states = [gate.process(0.8, True, 30) for _ in range(6)]
    assert states[-1] == "speech"
    # Close after sustained low prob (500ms)
    states = [gate.process(0.1, True, 30) for _ in range(20)]
    assert states[-1] == "silence"


def test_energy_vad_probability_range():
    silence = np.zeros(480, dtype=np.float32)
    speech = synthesize_tone(1000, 0.03, amp=0.25)
    assert energy_vad_probability(silence) < 0.1
    assert energy_vad_probability(speech) > 0.5
