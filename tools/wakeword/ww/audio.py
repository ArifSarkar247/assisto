"""Audio helpers for the "Hey Assisto" wake-word pipeline (numpy only;
scipy/soundfile are used when installed). Everything is 16 kHz mono float32
in [-1, 1] unless stated otherwise."""
from __future__ import annotations

import math
import wave

import numpy as np

SR = 16000


def read_audio(path: str, sr: int = SR) -> np.ndarray:
    """Any wav/flac/ogg -> mono float32 at `sr`."""
    try:
        import soundfile as sf  # BSD-3 (libsndfile LGPL-2.1, dynamically linked)
        x, rate = sf.read(path, dtype="float32", always_2d=True)
        x = x.mean(axis=1)
    except ImportError:
        with wave.open(path, "rb") as w:
            rate = w.getframerate()
            ch = w.getnchannels()
            raw = w.readframes(w.getnframes())
            width = w.getsampwidth()
        if width != 2:
            raise ValueError("only 16-bit PCM wav without soundfile")
        x = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
        if ch > 1:
            x = x.reshape(-1, ch).mean(axis=1)
    return resample(x.astype(np.float32), rate, sr)


def write_wav(path: str, x: np.ndarray, sr: int = SR) -> None:
    pcm = (np.clip(x, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def resample(x: np.ndarray, src: int, dst: int) -> np.ndarray:
    if src == dst or len(x) == 0:
        return x.astype(np.float32)
    try:
        from scipy.signal import resample_poly
        g = math.gcd(int(src), int(dst))
        return resample_poly(x, dst // g, src // g).astype(np.float32)
    except ImportError:
        n = int(round(len(x) * dst / src))
        t = np.linspace(0, len(x) - 1, n)
        return np.interp(t, np.arange(len(x)), x).astype(np.float32)


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(x, dtype=np.float64)) + 1e-12))


def trim_silence(x: np.ndarray, thresh_db: float = -40.0, pad: int = 1600) -> np.ndarray:
    if len(x) == 0:
        return x
    frame = 320
    n = len(x) // frame
    if n == 0:
        return x
    e = np.sqrt(np.mean(x[: n * frame].reshape(n, frame) ** 2, axis=1) + 1e-12)
    ref = e.max()
    on = np.where(20 * np.log10(e / ref + 1e-12) > thresh_db)[0]
    if len(on) == 0:
        return x
    a = max(0, on[0] * frame - pad)
    b = min(len(x), (on[-1] + 1) * frame + pad)
    return x[a:b]


def speed(x: np.ndarray, factor: float) -> np.ndarray:
    """Tempo+pitch change by resampling (factor > 1 = faster/higher)."""
    if abs(factor - 1.0) < 1e-3:
        return x
    return resample(x, int(SR * factor), SR)


def pitch_shift(x: np.ndarray, semitones: float) -> np.ndarray:
    """Pitch shift keeping duration ~constant: resample + overlap-add stretch."""
    if abs(semitones) < 1e-3:
        return x
    f = 2.0 ** (semitones / 12.0)
    y = speed(x, f)  # higher pitch, shorter
    return time_stretch(y, len(x))


def time_stretch(x: np.ndarray, target_len: int, win: int = 512) -> np.ndarray:
    """Simple WSOLA-free OLA stretch to `target_len` samples (good enough for
    data augmentation; artefacts are themselves useful variation)."""
    if len(x) < win * 2 or target_len <= 0:
        return np.resize(x, max(target_len, 1)).astype(np.float32)
    hop_out = win // 2
    n_frames = max(1, (target_len - win) // hop_out + 1)
    hop_in = (len(x) - win) / max(1, n_frames - 1)
    w = np.hanning(win).astype(np.float32)
    out = np.zeros(target_len + win, dtype=np.float32)
    norm = np.zeros_like(out)
    for i in range(n_frames):
        a = int(round(i * hop_in))
        seg = x[a: a + win]
        if len(seg) < win:
            seg = np.pad(seg, (0, win - len(seg)))
        o = i * hop_out
        out[o: o + win] += seg * w
        norm[o: o + win] += w
    norm[norm < 1e-3] = 1.0
    return (out / norm)[:target_len].astype(np.float32)


def synthetic_rir(rng: np.random.Generator, rt60: float | None = None,
                  distance_m: float | None = None) -> np.ndarray:
    """Synthetic room impulse response: direct path + early reflections +
    exponentially decaying diffuse tail. Licence-free (generated here)."""
    rt60 = rt60 if rt60 is not None else float(rng.uniform(0.15, 0.8))
    d = distance_m if distance_m is not None else float(rng.uniform(0.3, 3.0))
    n = int(SR * min(1.2, rt60 * 1.2)) + 1
    h = np.zeros(n, dtype=np.float32)
    delay = int(SR * d / 343.0)
    if delay >= n:
        delay = 0
    h[delay] = 1.0 / max(d, 0.3)
    for _ in range(int(rng.integers(4, 12))):
        k = delay + int(rng.uniform(0.002, 0.05) * SR)
        if k < n:
            h[k] += float(rng.uniform(-0.6, 0.6)) / max(d, 0.3)
    t = np.arange(n) / SR
    decay = np.exp(-6.9 * t / rt60)  # -60 dB at rt60
    tail = rng.standard_normal(n).astype(np.float32) * decay.astype(np.float32)
    tail[: delay + int(0.003 * SR)] = 0
    # Farther talker -> more reverberant energy relative to the direct path.
    drr = 0.15 * min(3.0, d)
    h += tail * drr / (np.sqrt(np.sum(tail ** 2)) + 1e-9)
    return h / (np.max(np.abs(h)) + 1e-9)


def convolve(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    try:
        from scipy.signal import fftconvolve
        y = fftconvolve(x, h)[: len(x)]
    except ImportError:
        nfft = 1 << int(np.ceil(np.log2(len(x) + len(h))))
        y = np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(h, nfft), nfft)[: len(x)]
    return y.astype(np.float32)


def mix_at_snr(signal: np.ndarray, noise: np.ndarray, snr_db: float) -> np.ndarray:
    if len(noise) < len(signal):
        noise = np.resize(noise, len(signal))
    noise = noise[: len(signal)]
    s, n = rms(signal), rms(noise)
    if n < 1e-6:
        return signal
    k = s / (n * (10 ** (snr_db / 20.0)))
    return (signal + k * noise).astype(np.float32)


def normalise(x: np.ndarray, peak_dbfs: float = -3.0) -> np.ndarray:
    p = np.max(np.abs(x)) + 1e-9
    return (x / p * (10 ** (peak_dbfs / 20.0))).astype(np.float32)


def random_crop(rng: np.random.Generator, x: np.ndarray, n: int) -> np.ndarray:
    if len(x) <= n:
        return np.pad(x, (0, n - len(x)))
    a = int(rng.integers(0, len(x) - n))
    return x[a: a + n]
