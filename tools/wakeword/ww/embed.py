"""Embedding extraction, in parallel worker processes (CI has 4 vCPUs; the e2e
extractor takes a FIXED [1, 12400] window, so one ORT session per process with
one thread each beats one session with 4 intra-op threads).

Every result is bit-identical to the serial StreamingFeatures (= the phone):
  * streams: the e2e embedding emitted at absolute sample m*HOP uses audio
    [m*HOP - W, m*HOP); a chunk of hops [ma, mb) is computed by a FRESH
    extractor fed audio from (ma - m0)*HOP, m0 = ceil(W / HOP), so its first
    emission lands exactly on hop ma.
  * augmented clip windows: item i / round r uses rng = default_rng([seed, i, r]),
    so the output does not depend on the number of workers.
The classifier never changes these (frozen extractor), so they are computed
ONCE per run (and cached by the workflow) and shared by every seed.
"""
from __future__ import annotations

import math
import multiprocessing as mp
import os

import numpy as np

from . import audio
from .augment import augment_clip, place_in_window, window_len
from .features import EMB_DIM, HOP, FeatureSpec, StreamingFeatures

_G: dict = {}


def _workers() -> int:
    return max(1, int(os.environ.get("WW_WORKERS", os.cpu_count() or 1)))


def _init_worker(spec: FeatureSpec):
    os.environ["WW_THREADS"] = "1"
    _G["fx"] = StreamingFeatures(spec)


def _pool(spec: FeatureSpec, n_jobs: int):
    w = min(_workers(), max(1, n_jobs))
    ctx = mp.get_context("fork")
    return ctx.Pool(w, initializer=_init_worker, initargs=(spec,))


def _m0(spec: FeatureSpec) -> int:
    return int(math.ceil(spec.window_samples / HOP))


# ---- long streams ------------------------------------------------------------

def _stream_job(args):
    ma, mb = args
    fx: StreamingFeatures = _G["fx"]
    m0 = _G["m0"]
    s = _G["stream"]
    a, b = (ma - m0) * HOP, mb * HOP
    fx.reset()
    e = fx.push(s[a:b].astype(np.float32) / 32768.0)
    return ma, e[: mb - ma]


def stream_embeddings(spec: FeatureSpec, stream_i16: np.ndarray, chunk_hops: int = 4500,
                      dtype=np.float32):
    """-> (emb [T, 96], emit_sample [T]) for one long int16 stream."""
    if spec.backend != "e2e":  # oww: mel context is not chunkable exactly -> serial
        fx = StreamingFeatures(spec)
        embs, ts = [], []
        for a in range(0, len(stream_i16), 600 * audio.SR):
            embs.append(fx.push(stream_i16[a: a + 600 * audio.SR].astype(np.float32) / 32768.0))
            ts += list(fx.emit_samples)
        e = np.concatenate(embs) if embs else np.zeros((0, EMB_DIM), np.float32)
        return e.astype(dtype), np.asarray(ts, np.int64)
    m0 = _m0(spec)
    m_end = len(stream_i16) // HOP + 1  # hops m with m*HOP <= len
    if m_end <= m0:
        return np.zeros((0, EMB_DIM), dtype), np.zeros(0, np.int64)
    jobs = [(ma, min(m_end, ma + chunk_hops)) for ma in range(m0, m_end, chunk_hops)]
    _G["stream"], _G["m0"] = stream_i16, m0
    out = np.zeros((m_end - m0, EMB_DIM), dtype)
    try:
        with _pool(spec, len(jobs)) as p:
            for ma, e in p.imap_unordered(_stream_job, jobs):
                out[ma - m0: ma - m0 + len(e)] = e
    finally:
        _G.pop("stream", None)
    return out, np.arange(m0, m_end, dtype=np.int64) * HOP


# ---- augmented clip windows ----------------------------------------------------

def _clip_job(items):
    fx: StreamingFeatures = _G["fx"]
    c = _G["clipcfg"]
    out = []
    for i, r in items:
        rng = np.random.default_rng([c["seed"], i, r])
        y = augment_clip(rng, c["clips"][i], c["noise"], rirs=c["rirs"], **c["aug"])
        w = place_in_window(rng, y, c["total"], c["background"])
        e = fx.clip_embeddings(w)
        out.append((i, r, e[-c["frames"]:] if len(e) >= c["frames"] else None))
    return out


def clip_windows(spec: FeatureSpec, clips, noise, frames: int, seed: int, rounds: int = 1,
                 rirs=None, background=None, dtype=np.float16, spec_window: int = 0,
                 **aug) -> np.ndarray:
    """clips: list of float arrays -> [n, frames, 96] (deterministic order)."""
    clips = list(clips)
    total = window_len(frames, spec_window or spec.window_samples)
    items = [(i, r) for i in range(len(clips)) for r in range(rounds)]
    if not items:
        return np.zeros((0, frames, EMB_DIM), dtype)
    _G["clipcfg"] = {"seed": seed, "clips": clips, "noise": noise, "rirs": rirs, "aug": aug,
                     "total": total, "background": noise if background is None else background,
                     "frames": frames}
    res = {}
    step = 64
    jobs = [items[a: a + step] for a in range(0, len(items), step)]
    try:
        with _pool(spec, len(jobs)) as p:
            for chunk in p.imap_unordered(_clip_job, jobs):
                for i, r, e in chunk:
                    if e is not None:
                        res[(i, r)] = e
    finally:
        _G.pop("clipcfg", None)
    keys = sorted(res)
    if not keys:
        return np.zeros((0, frames, EMB_DIM), dtype)
    return np.stack([res[k] for k in keys]).astype(dtype)


# ---- false-reject test clips (whole clip streamed inside background) -----------

def _frr_job(items):
    fx: StreamingFeatures = _G["fx"]
    c = _G["frrcfg"]
    out = []
    for i in items:
        rng = np.random.default_rng([c["seed"], i])
        x = c["clips"][i]
        if c["aug"] is not None:
            x = augment_clip(rng, x, c["noise"], rirs=c["rirs"], **c["aug"])
        lead, tail = int(c["lead_s"] * audio.SR), int(c["tail_s"] * audio.SR)
        total = lead + len(x) + tail
        bg_src = c["background"]
        bg = audio.random_crop(rng, bg_src, total).astype(np.float32) if len(bg_src) else \
            np.zeros(total, np.float32)
        bg = audio.normalise(bg, c["bg_db"]) if np.any(bg) else bg
        y = bg.copy()
        y[lead: lead + len(x)] += x
        y = (np.clip(y, -1, 1) * 32767).astype(np.int16).astype(np.float32) / 32768.0
        fx.reset()
        e = fx.push(y)
        out.append((i, e, np.asarray(fx.emit_samples, np.int64)))
    return out


def frr_clips(spec: FeatureSpec, clips, seed: int, noise=None, rirs=None, aug=None,
              background=None, lead_s: float = 2.5, tail_s: float = 1.0, bg_db: float = -45.0):
    """Each (optionally augmented) clip placed after `lead_s` of quiet background,
    streamed like the phone. -> dict(emb [sum T, 96] f32, offsets [n+1], ts [sum T], lead)."""
    clips = list(clips)
    _G["frrcfg"] = {"seed": seed, "clips": clips, "noise": noise, "rirs": rirs, "aug": aug,
                    "background": background if background is not None else np.zeros(0, np.int16),
                    "lead_s": lead_s, "tail_s": tail_s, "bg_db": bg_db}
    res = {}
    jobs = [list(range(a, min(len(clips), a + 16))) for a in range(0, len(clips), 16)]
    try:
        if jobs:
            with _pool(spec, len(jobs)) as p:
                for chunk in p.imap_unordered(_frr_job, jobs):
                    for i, e, t in chunk:
                        res[i] = (e, t)
    finally:
        _G.pop("frrcfg", None)
    embs = [res[i][0] for i in range(len(clips))]
    ts = [res[i][1] for i in range(len(clips))]
    offs = np.cumsum([0] + [len(e) for e in embs]).astype(np.int64)
    return {"emb": (np.concatenate(embs) if embs else np.zeros((0, EMB_DIM))).astype(np.float32),
            "offsets": offs, "ts": np.concatenate(ts) if ts else np.zeros(0, np.int64),
            "lead": np.int64(int(lead_s * audio.SR))}
