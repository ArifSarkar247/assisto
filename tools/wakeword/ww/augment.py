"""Turn clips into classifier training windows.

A positive window = background audio with the wake phrase ending near the
END of the window (0-250 ms of tail), after speed / pitch / gain / room (RIR,
0.3-3 m) / noise (0-20 dB SNR) augmentation. The streaming extractor runs over
the whole window exactly as on the phone and the LAST `frames` embeddings are
kept. Far-field eval clips use 1-2 m rooms and 5-15 dB SNR.
"""
from __future__ import annotations

import numpy as np

from . import audio
from .features import HOP, StreamingFeatures, windows


def window_len(frames: int, spec_window: int) -> int:
    # context the extractor needs before the first embedding + frames-1 hops
    return spec_window + (frames - 1) * HOP + HOP


def augment_clip(rng: np.random.Generator, x: np.ndarray, noise: np.ndarray,
                 dist=(0.3, 3.0), snr=(0.0, 20.0), p_rir: float = 0.7) -> np.ndarray:
    y = x
    if rng.random() < 0.8:
        y = audio.speed(y, float(rng.uniform(0.88, 1.12)))
    if rng.random() < 0.5:
        y = audio.pitch_shift(y, float(rng.uniform(-2.5, 2.5)))
    if rng.random() < p_rir:
        y = audio.convolve(y, audio.synthetic_rir(rng, distance_m=float(rng.uniform(*dist))))
    y = audio.normalise(y, float(rng.uniform(-30, -3)))
    if len(noise) and rng.random() < 0.9:
        n = audio.random_crop(rng, noise, len(y))
        y = audio.mix_at_snr(y, n, float(rng.uniform(*snr)))
    return y.astype(np.float32)


def place_in_window(rng: np.random.Generator, clip: np.ndarray, total: int,
                    background: np.ndarray, bg_db=(-50, -25)) -> np.ndarray:
    bg = audio.random_crop(rng, background, total) if len(background) else np.zeros(total, np.float32)
    bg = audio.normalise(bg, float(rng.uniform(*bg_db))) if np.any(bg) else bg
    tail = int(rng.uniform(0.0, 0.25) * audio.SR)
    clip = clip[-(total - tail):]
    end = total - tail
    out = bg.copy()
    out[end - len(clip): end] += clip
    return np.clip(out, -1, 1).astype(np.float32)


def clip_windows(fx: StreamingFeatures, rng: np.random.Generator, clips, noise: np.ndarray,
                 frames: int, spec_window: int, rounds: int = 1, **aug) -> np.ndarray:
    """clips: iterable of float arrays -> [n, frames, 96]."""
    total = window_len(frames, spec_window)
    out = []
    for x in clips:
        for _ in range(rounds):
            y = augment_clip(rng, x, noise, **aug)
            w = place_in_window(rng, y, total, noise)
            e = fx.clip_embeddings(w)
            if len(e) >= frames:
                out.append(e[-frames:])
    if not out:
        return np.zeros((0, frames, 96), np.float32)
    return np.stack(out).astype(np.float32)


def stream_windows(fx: StreamingFeatures, stream_i16: np.ndarray, frames: int, stride: int = 2,
                   chunk_s: int = 600) -> np.ndarray:
    """Windows of a long background stream (processed in chunks, streaming)."""
    fx.reset()
    embs = []
    step = chunk_s * audio.SR
    for a in range(0, len(stream_i16), step):
        embs.append(fx.push(stream_i16[a: a + step].astype(np.float32) / 32768.0))
    e = np.concatenate(embs) if embs else np.zeros((0, 96), np.float32)
    return windows(e, frames, stride).astype(np.float16)
