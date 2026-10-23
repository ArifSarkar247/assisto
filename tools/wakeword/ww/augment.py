"""Turn clips into classifier training windows.

A positive window = background audio with the wake phrase ending near the
END of the window (0-250 ms of tail), after speed / pitch / gain / room
(OpenSLR-26 simulated RIR bank or our synthetic RIR, 0.3-3 m) / noise
(music, noise or TV-like speech, 0-20 dB SNR) / optional TV-speaker colouring.
The streaming extractor runs over the whole window exactly as on the phone and
the LAST `frames` embeddings are kept (ww/embed.py does this in parallel).
"""
from __future__ import annotations

import numpy as np

from . import audio
from .features import HOP


def window_len(frames: int, spec_window: int) -> int:
    # context the extractor needs before the first embedding + frames-1 hops
    return spec_window + (frames - 1) * HOP + HOP


def _pick_noise(rng: np.random.Generator, noise):
    if isinstance(noise, (list, tuple)):
        pool = [n for n in noise if len(n)]
        return pool[int(rng.integers(0, len(pool)))] if pool else np.zeros(0, np.float32)
    return noise


def augment_clip(rng: np.random.Generator, x: np.ndarray, noise, dist=(0.3, 3.0),
                 snr=(0.0, 20.0), p_rir: float = 0.7, rirs=None, p_real_rir: float = 0.0,
                 p_band: float = 0.0, p_noise: float = 0.9) -> np.ndarray:
    """noise: one float array or a list (one is picked per clip).
    rirs: optional simulated RIR bank [n, L] (used with prob p_real_rir)."""
    from .datasets import band_limit, pick_rir
    y = x
    if rng.random() < 0.8:
        y = audio.speed(y, float(rng.uniform(0.88, 1.12)))
    if rng.random() < 0.5:
        y = audio.pitch_shift(y, float(rng.uniform(-2.5, 2.5)))
    if rng.random() < p_band:
        y = band_limit(rng, y)
    if rng.random() < p_rir:
        h = pick_rir(rng, rirs, p_real=p_real_rir, distance_m=float(rng.uniform(*dist)))
        y = audio.convolve(y, h)
    y = audio.normalise(y, float(rng.uniform(-30, -3)))
    n_src = _pick_noise(rng, noise)
    if len(n_src) and rng.random() < p_noise:
        n = audio.random_crop(rng, n_src, len(y))
        y = audio.mix_at_snr(y, n, float(rng.uniform(*snr)))
    return y.astype(np.float32)


def place_in_window(rng: np.random.Generator, clip: np.ndarray, total: int,
                    background, bg_db=(-50, -25)) -> np.ndarray:
    background = _pick_noise(rng, background)
    bg = audio.random_crop(rng, background, total) if len(background) else np.zeros(total, np.float32)
    bg = audio.normalise(bg, float(rng.uniform(*bg_db))) if np.any(bg) else bg
    tail = int(rng.uniform(0.0, 0.25) * audio.SR)
    clip = clip[-(total - tail):]
    end = total - tail
    out = bg.astype(np.float32).copy()
    out[end - len(clip): end] += clip
    return np.clip(out, -1, 1).astype(np.float32)
