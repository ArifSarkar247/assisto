"""Negative / background audio — download + prepare (CI only; never commit
raw data). Every source is listed in SOURCES with its licence; only sources
marked commercial_ok=True may feed TRAINING. Eval-only sources never touch the
model weights (they only measure false accepts).

Prepared output (cached by the workflow): int16 16 kHz mono .npy streams.
"""
from __future__ import annotations

import io
import os
import random
import re
import tarfile
import urllib.request
import zipfile

import numpy as np

from . import audio

SOURCES = {
    "fleurs_bn": {
        "what": "Bengali read speech (FLEURS, bn_in, train split)",
        "url": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/bn_in/audio/train.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "train-negative",
    },
    "fleurs_bn_dev": {
        "what": "Bengali read speech (FLEURS, bn_in, dev split)",
        "url": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/bn_in/audio/dev.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "validation",
    },
    "librispeech_dev": {
        "what": "English read speech (LibriSpeech dev-clean)",
        "url": "https://www.openslr.org/resources/12/dev-clean.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "train-negative",
    },
    "librispeech_test": {
        "what": "English read speech (LibriSpeech test-clean)",
        "url": "https://www.openslr.org/resources/12/test-clean.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "eval",
    },
    "musan": {
        "what": "MUSAN music + noise (per-file NC/ND licences filtered out)",
        "url": "https://www.openslr.org/resources/17/musan.tar.gz",
        "licence": "CC BY 4.0 (corpus); per-file licences in LICENSE files", "commercial_ok": True,
        "use": "train-negative + augmentation noise (85%), eval (15%)",
    },
    "fleurs_bn_test": {
        "what": "Bengali read speech (FLEURS, bn_in, test split) - extra VALIDATION hours",
        "url": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/bn_in/audio/test.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "validation",
    },
    "fleurs_hi_dev": {
        "what": "Hindi read speech (FLEURS, hi_in, dev split) - VALIDATION",
        "url": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/hi_in/audio/dev.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "validation",
    },
    "fleurs_hi": {
        "what": "Hindi read speech (FLEURS, hi_in, train split) - 'Hindi serial on the TV' negatives",
        "url": "https://huggingface.co/datasets/google/fleurs/resolve/main/data/hi_in/audio/train.tar.gz",
        "licence": "CC BY 4.0", "commercial_ok": True, "use": "train-negative",
    },
    "sim_rir": {
        "what": "Simulated room impulse responses, 16 kHz (OpenSLR 26; image method, small/medium/large rooms)",
        "url": "https://www.openslr.org/resources/26/sim_rir_16k.zip",
        "licence": "Apache-2.0", "commercial_ok": True,
        "use": "augmentation (rooms split train 80% / validation 10% / eval 10%)",
    },
    "slr53_bn": {
        "what": "Bengali conversational-style ASR speech, ONE shard (~13 h) (OpenSLR 53)",
        "url": "https://www.openslr.org/resources/53/asr_bengali_0.zip",
        "licence": "CC BY-SA 4.0", "commercial_ok": True, "use": "eval only (false accepts / hour)",
    },
    "slr53_bn_1": {
        "what": "Bengali ASR speech, a SECOND shard (OpenSLR 53, asr_bengali_1) - speech of the TV-mix test set",
        "url": "https://www.openslr.org/resources/53/asr_bengali_1.zip",
        "licence": "CC BY-SA 4.0", "commercial_ok": True, "use": "eval only (TV-like test set)",
    },
}
# MUSAN "speech" (LibriVox + US-government recordings, public domain per MUSAN's
# LICENSE files; NC/ND entries filtered like music/noise) comes from the same
# archive as "musan" above: broadcast/read English speech for TV-like mixes.

AUDIO_EXT = (".wav", ".flac", ".ogg")
_NC_ND = re.compile(r"(non-?commercial|no-?deriv|\bby-nc|\bnc\b|-nc-|-nd\b|\bnd\b|by-nd)", re.I)


def download(url: str, dest: str) -> str:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    # OpenSLR's main host is slow from CI (MUSAN = 11 GB); its official mirrors
    # serve the same files (EU mirror measured ~30x faster). Try EU, US, then the original.
    urls = [url]
    if url.startswith("https://www.openslr.org/"):
        tail = url[len("https://www.openslr.org/"):]
        urls = ["https://openslr.elda.org/" + tail, "https://us.openslr.org/" + tail, url]
    last = None
    for u in urls:
        try:
            req = urllib.request.Request(u, headers={"User-Agent": "assisto-wakeword-train/1"})
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            os.replace(tmp, dest)
            return dest
        except Exception as e:  # noqa: BLE001
            last = e
            print(f"download failed ({u}): {e}", flush=True)
    raise RuntimeError(f"download failed for {url}: {last}")


def _iter_archive(path: str, prefixes=()):
    """Yield (member_name, bytes) for audio (and LICENSE) members."""
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if (n.lower().endswith(AUDIO_EXT) or os.path.basename(n) == "LICENSE") and \
                        (not prefixes or n.startswith(prefixes)):
                    yield n, z.read(n)
        return
    with tarfile.open(path, "r|*") as t:  # streaming: one pass, no random access
        for m in t:
            if not m.isfile():
                continue
            n = m.name
            if prefixes and not n.startswith(prefixes):
                continue
            if n.lower().endswith(AUDIO_EXT) or os.path.basename(n) == "LICENSE":
                f = t.extractfile(m)
                if f is not None:
                    yield n, f.read()


def _decode(b: bytes) -> np.ndarray | None:
    try:
        import soundfile as sf
        x, rate = sf.read(io.BytesIO(b), dtype="float32", always_2d=True)
        return audio.resample(x.mean(axis=1), rate, audio.SR)
    except Exception:  # noqa: BLE001
        return None


def archive_to_stream(path: str, max_hours: float, seed: int = 0, prefixes=(),
                      gap_s=(0.1, 1.5)) -> np.ndarray:
    """Concatenate an archive's clips (random gaps of near-silence between)
    into ONE int16 stream, capped at max_hours."""
    rng = np.random.default_rng(seed)
    cap = int(max_hours * 3600 * audio.SR)
    parts, total = [], 0
    for _, b in _iter_archive(path, prefixes):
        if total >= cap:
            break
        x = _decode(b)
        if x is None or len(x) == 0:
            continue
        g = np.zeros(int(rng.uniform(*gap_s) * audio.SR), np.float32)
        g += rng.standard_normal(len(g)).astype(np.float32) * 1e-4
        parts += [x, g]
        total += len(x) + len(g)
    if not parts:
        return np.zeros(0, np.int16)
    y = np.concatenate(parts)[:cap]
    return (np.clip(y, -1, 1) * 32767).astype(np.int16)


def _split3(names, rng, val_frac, eval_frac):
    names = sorted(names)
    rng.shuffle(names)
    kv, ke = int(len(names) * val_frac), int(len(names) * eval_frac)
    return {"val": names[:kv], "eval": names[kv: kv + ke], "train": names[kv + ke:]}


def musan_split(path: str, out_dir: str, max_files: int = 2500, eval_frac: float = 0.15,
                seed: int = 0, val_frac: float = 0.10, speech_files: int = 300,
                speech_max_s: int = 120) -> dict:
    """Extract MUSAN music+noise AND speech (resampled), drop files whose
    LICENSE entry is NonCommercial / NoDerivatives, split by FILE into
    train / val / eval. Writes musan_{part}.npy (music+noise) and
    mspeech_{part}.npy (speech). Returns a report."""
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(seed)
    clips, speech, licences = {}, {}, {}
    for name, b in _iter_archive(path, ("musan/music", "musan/noise", "musan/speech")):
        if os.path.basename(name) == "LICENSE":
            licences[os.path.dirname(name)] = b.decode("utf-8", "replace")
            continue
        is_sp = name.startswith("musan/speech")
        if (is_sp and len(speech) >= speech_files) or (not is_sp and len(clips) >= max_files):
            continue
        x = _decode(b)
        if x is None or len(x) < audio.SR:
            continue
        cap = audio.SR * (speech_max_s if is_sp else 60)
        (speech if is_sp else clips)[name] = (np.clip(x[:cap], -1, 1) * 32767).astype(np.int16)
    dropped = []
    for pool in (clips, speech):
        for name in list(pool):
            lic = licences.get(os.path.dirname(name), "")
            stem = os.path.splitext(os.path.basename(name))[0]
            for line in lic.splitlines():
                if stem in line and _NC_ND.search(line):
                    dropped.append(name)
                    pool.pop(name, None)
                    break
    rep = {"kept": len(clips), "speech_kept": len(speech), "dropped_nc_nd": len(dropped),
           "licence_files": len(licences)}
    for tag, pool in (("musan", clips), ("mspeech", speech)):
        split = _split3(list(pool), rng, val_frac, eval_frac)
        for part, ns in split.items():
            arr = np.concatenate([pool[n] for n in ns]) if ns else np.zeros(0, np.int16)
            np.save(os.path.join(out_dir, f"{tag}_{part}.npy"), arr)
            rep[f"{tag}_{part}_files"] = len(ns)
            rep[f"{tag}_{part}_h"] = round(len(arr) / audio.SR / 3600, 3)
    return rep


def rir_bank(path: str, out_dir: str, per_split=(1600, 200, 200), max_len: int = audio.SR,
             seed: int = 0) -> dict:
    """OpenSLR 26 simulated RIRs -> rir_{train,val,eval}.npy (float16 [n, max_len],
    peak-normalised). Split by ROOM (a room's RIRs never cross splits)."""
    rng = random.Random(seed)
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if n.lower().endswith(".wav")]
        rooms = {}
        for n in names:
            rooms.setdefault(os.path.dirname(n), []).append(n)
        split = _split3(list(rooms), rng, 0.10, 0.10)
        rep = {"rooms": len(rooms), "files": len(names)}
        for part, want in zip(("train", "val", "eval"), per_split):
            pool = [n for r in split[part] for n in rooms[r]]
            rng.shuffle(pool)
            out = []
            for n in pool[:want]:
                x = _decode(z.read(n))
                if x is None or len(x) < 16:
                    continue
                x = x[:max_len]
                k = int(np.argmax(np.abs(x)))
                x = x[max(0, k - 16):]  # drop leading silence before the direct path
                x = x / (np.max(np.abs(x)) + 1e-9)
                out.append(np.pad(x, (0, max_len - len(x))).astype(np.float16))
            arr = np.stack(out) if out else np.zeros((0, max_len), np.float16)
            np.save(os.path.join(out_dir, f"rir_{part}.npy"), arr)
            rep[f"rir_{part}"] = len(arr)
    return rep


def pick_rir(rng: np.random.Generator, rirs: np.ndarray | None, p_real: float = 0.6,
             distance_m: float | None = None) -> np.ndarray:
    """A room impulse response: from the licence-clean simulated bank (OpenSLR 26)
    with probability p_real, else our own synthetic one."""
    if rirs is not None and len(rirs) and rng.random() < p_real:
        h = rirs[int(rng.integers(0, len(rirs)))].astype(np.float32)
        nz = np.nonzero(np.abs(h) > 1e-4)[0]
        return h[: (nz[-1] + 1) if len(nz) else 1]
    return audio.synthetic_rir(rng, distance_m=distance_m)


def band_limit(rng: np.random.Generator, x: np.ndarray) -> np.ndarray:
    """A TV / small-speaker colouring: random high-pass 80-350 Hz + low-pass 3.4-7.5 kHz."""
    try:
        from scipy.signal import butter, sosfilt
    except ImportError:
        return x
    lo, hi = float(rng.uniform(80, 350)), float(rng.uniform(3400, 7500))
    sos = butter(2, [lo, hi], btype="bandpass", fs=audio.SR, output="sos")
    return sosfilt(sos, x).astype(np.float32)


def tv_like_mix(speech: np.ndarray, music: np.ndarray, snr_db=(0, 20), seed: int = 0,
                rirs: np.ndarray | None = None, p_band: float = 0.7,
                level_db=(-38.0, -16.0)) -> np.ndarray:
    """'TV in the room': speech with music/noise underneath at a random SNR
    (default 0-20 dB) per 30 s segment, random TV-speaker colouring, a room
    (simulated RIR bank or synthetic), random playback level. int16 in/out."""
    rng = np.random.default_rng(seed)
    s = speech.astype(np.float32) / 32768.0
    if len(music) == 0 or len(s) == 0:
        return speech
    out = np.zeros_like(s)
    seg = audio.SR * 30
    for a in range(0, len(s), seg):
        b = min(len(s), a + seg)
        m = audio.random_crop(rng, music, b - a).astype(np.float32) / 32768.0
        x = audio.mix_at_snr(s[a:b], m, float(rng.uniform(*snr_db)))
        if rng.random() < p_band:
            x = band_limit(rng, x)
        x = audio.convolve(x, pick_rir(rng, rirs))[: b - a]
        lv = float(rng.uniform(*level_db))
        x = x * (10 ** (lv / 20.0) / (audio.rms(x) + 1e-9))
        out[a:b] = x
    return (np.clip(out, -1, 1) * 32767).astype(np.int16)


def speed_stream(x: np.ndarray, factor: float, max_samples: int | None = None,
                 seg_s: int = 60) -> np.ndarray:
    """Speed-perturbed copy of an int16 stream (tempo + pitch, = new synthetic
    'speakers'), processed in segments."""
    out, n = [], 0
    seg = seg_s * audio.SR
    for a in range(0, len(x), seg):
        y = audio.speed(x[a: a + seg].astype(np.float32) / 32768.0, factor)
        out.append((np.clip(y, -1, 1) * 32767).astype(np.int16))
        n += len(y)
        if max_samples and n >= max_samples:
            break
    y = np.concatenate(out) if out else np.zeros(0, np.int16)
    return y[:max_samples] if max_samples else y


def babble_mix(x: np.ndarray, seed: int = 0, snr_db=(0.0, 10.0), max_samples: int | None = None,
               rirs: np.ndarray | None = None) -> np.ndarray:
    """Two talkers at once (talk-show / crowded room): the stream over a
    time-shifted copy of itself at 0-10 dB, per 30 s segment, through a room."""
    rng = np.random.default_rng(seed)
    n = min(len(x), max_samples or len(x))
    out = np.zeros(n, np.int16)
    seg = audio.SR * 30
    for a in range(0, n, seg):
        b = min(n, a + seg)
        s = x[a:b].astype(np.float32) / 32768.0
        o = audio.random_crop(rng, x, b - a).astype(np.float32) / 32768.0
        y = audio.mix_at_snr(s, o, float(rng.uniform(*snr_db)))
        if rng.random() < 0.7:
            y = audio.convolve(y, pick_rir(rng, rirs))[: b - a]
        y = y * (10 ** (float(rng.uniform(-36, -18)) / 20.0) / (audio.rms(y) + 1e-9))
        out[a:b] = (np.clip(y, -1, 1) * 32767).astype(np.int16)
    return out


def clips_stream(clips, seed: int = 0, gap_s=(0.5, 2.0)) -> np.ndarray:
    """Float clips -> one int16 stream with quiet gaps (e.g. TTS near-miss phrases)."""
    rng = np.random.default_rng(seed)
    parts = []
    for x in clips:
        g = rng.standard_normal(int(rng.uniform(*gap_s) * audio.SR)).astype(np.float32) * 1e-4
        parts += [g, np.asarray(x, np.float32)]
    if not parts:
        return np.zeros(0, np.int16)
    return (np.clip(np.concatenate(parts), -1, 1) * 32767).astype(np.int16)


def licence_table() -> str:
    rows = ["| source | what | licence | commercial OK | used for |", "|---|---|---|---|---|"]
    for k, s in SOURCES.items():
        rows.append(f"| {k} | {s['what']} | {s['licence']} | {'yes' if s['commercial_ok'] else 'NO'} | {s['use']} |")
    return "\n".join(rows)
