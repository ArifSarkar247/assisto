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
    "slr53_bn": {
        "what": "Bengali conversational-style ASR speech, ONE shard (~13 h) (OpenSLR 53)",
        "url": "https://www.openslr.org/resources/53/asr_bengali_0.zip",
        "licence": "CC BY-SA 4.0", "commercial_ok": True, "use": "eval only (false accepts / hour)",
    },
}

AUDIO_EXT = (".wav", ".flac", ".ogg")
_NC_ND = re.compile(r"(non-?commercial|no-?deriv|\bby-nc|\bnc\b|-nc-|-nd\b|\bnd\b|by-nd)", re.I)


def download(url: str, dest: str) -> str:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return dest
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "assisto-wakeword-train/1"})
    with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            f.write(b)
    os.replace(tmp, dest)
    return dest


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


def musan_split(path: str, out_dir: str, max_files: int = 2500, eval_frac: float = 0.15,
                seed: int = 0) -> dict:
    """Extract MUSAN music+noise (resampled), drop files whose LICENSE entry
    is NonCommercial / NoDerivatives, split train/eval. Returns a report."""
    os.makedirs(out_dir, exist_ok=True)
    rng = random.Random(seed)
    clips, licences = {}, {}
    for name, b in _iter_archive(path, ("musan/music", "musan/noise")):
        if os.path.basename(name) == "LICENSE":
            licences[os.path.dirname(name)] = b.decode("utf-8", "replace")
            continue
        if len(clips) >= max_files:
            continue
        x = _decode(b)
        if x is None or len(x) < audio.SR:
            continue
        clips[name] = (np.clip(x[: audio.SR * 60], -1, 1) * 32767).astype(np.int16)
    dropped = []
    for name in list(clips):
        lic = licences.get(os.path.dirname(name), "")
        stem = os.path.splitext(os.path.basename(name))[0]
        for line in lic.splitlines():
            if stem in line and _NC_ND.search(line):
                dropped.append(name)
                clips.pop(name, None)
                break
    names = sorted(clips)
    rng.shuffle(names)
    k = int(len(names) * eval_frac)
    split = {"eval": names[:k], "train": names[k:]}
    for part, ns in split.items():
        arr = np.concatenate([clips[n] for n in ns]) if ns else np.zeros(0, np.int16)
        np.save(os.path.join(out_dir, f"musan_{part}.npy"), arr)
    return {"kept": len(names), "dropped_nc_nd": len(dropped), "licence_files": len(licences),
            "train_files": len(split["train"]), "eval_files": len(split["eval"])}


def tv_like_mix(speech: np.ndarray, music: np.ndarray, snr_db=(0, 12), seed: int = 0) -> np.ndarray:
    """'TV in the room': speech with music/noise underneath at random levels,
    through a synthetic room. int16 in, int16 out."""
    rng = np.random.default_rng(seed)
    s = speech.astype(np.float32) / 32768.0
    if len(music) == 0 or len(s) == 0:
        return speech
    m = np.resize(music.astype(np.float32) / 32768.0, len(s))
    out = np.zeros_like(s)
    seg = audio.SR * 30
    for a in range(0, len(s), seg):
        b = min(len(s), a + seg)
        x = audio.mix_at_snr(s[a:b], m[a:b], float(rng.uniform(*snr_db)))
        x = audio.convolve(x, audio.synthetic_rir(rng))
        out[a:b] = x[: b - a]
    return (np.clip(out / (np.max(np.abs(out)) + 1e-9) * 0.7, -1, 1) * 32767).astype(np.int16)


def licence_table() -> str:
    rows = ["| source | what | licence | commercial OK | used for |", "|---|---|---|---|---|"]
    for k, s in SOURCES.items():
        rows.append(f"| {k} | {s['what']} | {s['licence']} | {'yes' if s['commercial_ok'] else 'NO'} | {s['use']} |")
    return "\n".join(rows)
