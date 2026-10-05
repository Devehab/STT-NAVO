"""Where to cut long audio so that no word is split between two pieces.

A cut is only made inside a real pause. Around the target point the audio is measured in
10 ms frames; a frame is silent when it is well below the speech level of its surroundings
(an adaptive threshold, so a quiet room and a noisy call both work). Runs of silent frames
are pauses. A pause of at least 300 ms is a gap between phrases or a breath, never the
closure inside a word (Arabic geminate stops can hold 200 ms), so those are preferred;
among them the longest wins, with a small preference for being close to the target. The
cut goes inside the pause, as near the target as the pause allows while keeping some
silence on both sides. Only when there is no such pause in the whole search range does it
fall back to shorter pauses, and then to the quietest 100 ms of the range.

The Navo app uses the same method (Sources/Navo/Sessions/SmartCut.swift) to cut meetings
and long files into pieces, and the engine uses it to fit each piece into a model's input.
Keep the two in step.
"""

from __future__ import annotations

import numpy as np

from . import SAMPLE_RATE

FRAME = SAMPLE_RATE // 100  # 10 ms
CONTEXT = 3 * SAMPLE_RATE  # measured before the search range, for the noise floor
LOOKAHEAD = SAMPLE_RATE  # measured after it, so a pause at its end gets its true length
PAUSE_TIERS = (0.30, 0.15)  # seconds: a sure pause, then a shorter one
MARGIN = 0.15  # seconds of silence kept on each side of a cut when the pause allows
ALWAYS_SILENT_DB = -65.0
SILENT_PIECE_DB = -55.0  # loudest 100 ms below this: nothing to transcribe


def frame_db(audio: np.ndarray) -> np.ndarray:
    """Level of each 10 ms frame in dB (full scale 0 dB), with the frame's DC offset removed."""
    count = len(audio) // FRAME
    if count == 0:
        return np.zeros(0)
    frames = np.asarray(audio[: count * FRAME], dtype=np.float64).reshape(count, FRAME)
    frames = frames - frames.mean(axis=1, keepdims=True)
    power = (frames * frames).mean(axis=1)
    return 10.0 * np.log10(power + 1e-10)


def smooth(levels: np.ndarray) -> np.ndarray:
    """Median of 3: a single loud frame (a click) does not break a pause, a single quiet one does not make one."""
    if len(levels) < 3:
        return levels.copy()
    padded = np.concatenate(([levels[0]], levels, [levels[-1]]))
    return np.median(np.stack([padded[:-2], padded[1:-1], padded[2:]]), axis=0)


FLOOR_SMOOTH = 2  # frames on each side averaged before taking the floor (50 ms in all)
FLOOR_REACH = 150  # frames on each side searched for the floor (3 s in all)


def local_floor(levels: np.ndarray) -> np.ndarray:
    """Background level around each frame: the quietest 50 ms within 1.5 s either side.

    Following the floor over time keeps a fan that speeds up, or a room that gets louder,
    from hiding the pauses or from turning quiet speech into a pause.
    """
    count = len(levels)
    width = 2 * FLOOR_SMOOTH + 1
    padded = np.pad(levels, FLOOR_SMOOTH, mode="edge")
    averaged = np.convolve(padded, np.ones(width) / width, mode="valid")
    padded = np.pad(averaged, FLOOR_REACH, mode="edge")
    windows = np.lib.stride_tricks.sliding_window_view(padded, 2 * FLOOR_REACH + 1)
    return windows.min(axis=1)[:count]


def contrast(levels: np.ndarray) -> float:
    """How far a frame must sit below the speech around it to count as silent, in dB."""
    spread = float(np.percentile(levels, 95) - np.percentile(levels, 10))
    return min(max(0.25 * spread, 3.0), 15.0)


def find_cut(audio: np.ndarray, lo: int, hi: int, target: int) -> int:
    """Sample index in [lo, hi] where `audio` should be cut, as close to `target` as a pause allows."""
    total = len(audio)
    lo = max(0, min(lo, total))
    hi = max(lo, min(hi, total))
    target = min(max(target, lo), hi)
    if hi - lo < 2 * FRAME:
        return target

    start = max(0, lo - CONTEXT)
    end = min(total, hi + LOOKAHEAD)
    levels = smooth(frame_db(audio[start:end]))
    if len(levels) == 0:
        return target
    delta = contrast(levels)
    threshold = local_floor(levels) + delta
    silent = (levels < threshold) | (levels < ALWAYS_SILENT_DB)
    # 1 for a frame at the background level, 0 at the threshold: a real pause is nearly all 1s.
    purity = np.clip((threshold - levels) / delta, 0.0, 1.0)

    radius = max(target - lo, hi - target, 1)
    margin = int(MARGIN * SAMPLE_RATE)
    runs = []  # (seconds, cut, score)
    index = 0
    count = len(levels)
    while index < count:
        if not silent[index]:
            index += 1
            continue
        first = index
        while index < count and silent[index]:
            index += 1
        run_start = start + first * FRAME
        run_end = start + index * FRAME
        if run_end <= lo or run_start >= hi:
            continue
        seconds = (run_end - run_start) / SAMPLE_RATE
        keep = min((run_end - run_start) // 2, margin)
        cut = min(max(target, run_start + keep), run_end - keep)
        cut = min(max(cut, lo), hi)
        clean = float(purity[first:index].mean())
        score = min(seconds, 1.5) * (0.5 + 0.5 * clean) - 0.5 * abs(cut - target) / radius
        runs.append((seconds, cut, score))

    for shortest in PAUSE_TIERS:
        candidates = [run for run in runs if run[0] >= shortest]
        if candidates:
            return max(candidates, key=lambda run: run[2])[1]
    return quietest_point(levels, start, lo, hi, target)


def quietest_point(levels: np.ndarray, start: int, lo: int, hi: int, target: int) -> int:
    """Middle of the quietest 100 ms between lo and hi; near-ties go to the one closest to target."""
    window = 10
    first = max(0, (lo - start) // FRAME)
    last = min(len(levels), (hi - start) // FRAME)
    if last - first < window:
        return target
    sums = np.convolve(levels[first:last], np.ones(window) / window, mode="valid")
    best = float(sums.min())
    positions = np.flatnonzero(sums <= best + 1.0)
    centers = start + (first + positions + window // 2) * FRAME
    return int(min(centers, key=lambda c: abs(int(c) - target)))


def is_silent(audio: np.ndarray) -> bool:
    """True when not even 100 ms of the audio is loud enough to hold speech."""
    levels = frame_db(audio)
    if len(levels) == 0:
        return True
    power = 10.0 ** (levels / 10.0)
    window = min(10, len(power))
    loudest = np.convolve(power, np.ones(window) / window, mode="valid").max()
    return 10.0 * np.log10(loudest + 1e-10) < SILENT_PIECE_DB


def split_for_model(audio: np.ndarray, max_seconds: float, search_seconds: float = 10.0) -> list[tuple[np.ndarray, float]]:
    """Pieces of at most `max_seconds`, each cut inside a pause, with their start times in seconds."""
    limit = int(max_seconds * SAMPLE_RATE)
    search = int(min(search_seconds, max_seconds / 2) * SAMPLE_RATE)
    pieces = []
    begin = 0
    while len(audio) - begin > limit:
        hi = begin + limit
        cut = find_cut(audio, max(begin + SAMPLE_RATE, hi - search), hi, hi)
        if cut <= begin:
            cut = hi
        pieces.append((audio[begin:cut], begin / SAMPLE_RATE))
        begin = cut
    pieces.append((audio[begin:], begin / SAMPLE_RATE))
    return pieces
