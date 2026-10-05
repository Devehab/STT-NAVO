"""Cut points: always inside a real pause, never inside a word."""

import numpy as np
import pytest

from navo_engine.splitting import find_cut, is_silent, split_for_model

SR = 16000


class Speech:
    """Builds speech-like audio: syllable bursts, short gaps inside words, pauses between phrases."""

    def __init__(self, seed=0, floor_db=-60.0):
        self.rng = np.random.default_rng(seed)
        self.parts = []
        self.floor = 10 ** (floor_db / 20)
        self.pauses = []  # (start, end) in samples

    @property
    def length(self):
        return sum(len(p) for p in self.parts)

    def word(self, seconds, level=0.2):
        n = int(seconds * SR)
        t = np.arange(n) / SR
        voiced = np.sin(2 * np.pi * 140 * t) + 0.5 * np.sin(2 * np.pi * 280 * t) + 0.3 * self.rng.standard_normal(n)
        envelope = np.sin(np.pi * np.arange(n) / n) ** 0.5
        self.parts.append(level * envelope * voiced / 1.5 + self.floor * self.rng.standard_normal(n))
        return self

    def gap(self, seconds, level_db=-45.0):
        """A closure inside a word or between fast words: quiet, but not a pause."""
        n = int(seconds * SR)
        self.parts.append(10 ** (level_db / 20) * self.rng.standard_normal(n))
        return self

    def pause(self, seconds):
        n = int(seconds * SR)
        start = self.length
        self.pauses.append((start, start + n))
        self.parts.append(self.floor * self.rng.standard_normal(n))
        return self

    def talk(self, seconds):
        """Continuous speech: words of 150 to 450 ms with closures of 30 to 120 ms, no pause."""
        end = self.length + int(seconds * SR)
        while self.length < end:
            self.word(self.rng.uniform(0.15, 0.45), level=self.rng.uniform(0.08, 0.3))
            self.gap(self.rng.uniform(0.03, 0.12))
        return self

    def audio(self):
        return np.concatenate(self.parts).astype(np.float32)


def inside(cut, span, slack=0):
    return span[0] - slack <= cut <= span[1] + slack


def test_cuts_inside_the_only_pause():
    s = Speech().talk(55).pause(0.5).talk(20)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[0])


def test_prefers_the_longer_pause():
    s = Speech(1).talk(58).pause(0.35).talk(8).pause(0.9).talk(10)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[1])


def test_closures_inside_words_are_not_pauses():
    # The target sits in dense speech full of 30 to 120 ms closures; the only pause is 7 s away.
    s = Speech(2).talk(53).pause(0.35).talk(25)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[0])


def test_long_pause_near_target_cut_near_target():
    s = Speech(3).talk(58).pause(4.0).talk(10)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[0])
    assert abs(cut - 60 * SR) < SR // 100  # the pause covers the target: cut right there


def test_without_any_pause_cuts_in_a_quiet_gap():
    s = Speech(4).talk(80)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    assert 50 * SR <= cut <= 70 * SR
    # The cut lands where the signal is quiet, far below the loud parts of the words.
    window = audio[cut - 400: cut + 400]
    assert np.sqrt(np.mean(window ** 2)) < 0.02


def test_silence_and_steady_noise_cut_at_target():
    for audio in (np.zeros(80 * SR, dtype=np.float32),
                  (0.05 * np.random.default_rng(5).standard_normal(80 * SR)).astype(np.float32)):
        cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
        assert abs(cut - 60 * SR) <= SR // 50


def test_pause_under_background_music():
    rng = np.random.default_rng(6)
    s = Speech(6, floor_db=-80).talk(56).pause(0.6).talk(20)
    audio = s.audio()
    t = np.arange(len(audio)) / SR
    music = 0.04 * (np.sin(2 * np.pi * 220 * t) + np.sin(2 * np.pi * 330 * t) + 0.2 * rng.standard_normal(len(t)))
    cut = find_cut((audio + music).astype(np.float32), 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[0])


def test_quiet_recording_still_finds_the_pause():
    # A distant microphone: speech peaks around -40 dBFS.
    s = Speech(7, floor_db=-75).talk(64).pause(0.4).talk(15)
    audio = s.audio() * 0.05
    cut = find_cut(audio.astype(np.float32), 50 * SR, 70 * SR, 60 * SR)
    assert inside(cut, s.pauses[0])


def test_keeps_silence_on_both_sides():
    s = Speech(8).talk(59).pause(0.6).talk(15)
    audio = s.audio()
    cut = find_cut(audio, 50 * SR, 70 * SR, 60 * SR)
    start, end = s.pauses[0]
    assert cut - start >= int(0.12 * SR) and end - cut >= int(0.12 * SR)


def test_is_silent():
    rng = np.random.default_rng(9)
    assert is_silent(np.zeros(SR * 5, dtype=np.float32))
    assert is_silent((10 ** (-70 / 20) * rng.standard_normal(SR * 5)).astype(np.float32))
    assert not is_silent(Speech(9).talk(3).audio())
    burst = np.zeros(SR * 60, dtype=np.float32)
    burst[SR * 30: SR * 30 + SR // 5] = 0.02 * rng.standard_normal(SR // 5)
    assert not is_silent(burst)
    assert is_silent(np.zeros(10, dtype=np.float32))


def test_split_for_model_respects_the_limit_and_the_pauses():
    s = Speech(10)
    for _ in range(12):
        s.talk(s.rng.uniform(4, 9)).pause(s.rng.uniform(0.35, 0.8))
    audio = s.audio()
    pieces = split_for_model(audio, 28.0)
    assert len(pieces) >= 3
    position = 0
    for piece, offset in pieces:
        assert len(piece) <= 28 * SR
        assert offset == pytest.approx(position / SR)
        position += len(piece)
    assert position == len(audio)
    for _, offset in pieces[1:]:
        cut = int(round(offset * SR))
        assert any(inside(cut, span) for span in s.pauses), offset


def test_split_for_model_short_audio_is_one_piece():
    audio = Speech(11).talk(10).audio()
    pieces = split_for_model(audio, 28.0)
    assert len(pieces) == 1 and len(pieces[0][0]) == len(audio)
