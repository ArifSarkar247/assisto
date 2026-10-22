"""Honest evaluation: false accepts per hour on long background streams and
false-reject rate on held-out far-field positives, per sensitivity level, with
the SAME streaming extractor + Decider the phone uses."""
from __future__ import annotations

import numpy as np

from . import audio
from .augment import augment_clip
from .detector import LEVELS, Decider, count_triggers
from .features import StreamingFeatures


def stream_scores(fx: StreamingFeatures, net, stream_i16: np.ndarray, frames: int,
                  chunk_s: int = 600, with_times: bool = False):
    """One score per 80 ms frame over a long stream (as on the phone).
    with_times: also return the sample index at which each score exists."""
    fx.reset()
    hist = np.zeros((0, 96), np.float32)
    hist_t: list = []
    scores, times = [], []
    step = chunk_s * audio.SR
    for a in range(0, len(stream_i16), step):
        e = fx.push(stream_i16[a: a + step].astype(np.float32) / 32768.0)
        if not len(e):
            continue
        allv = np.concatenate([hist, e])
        allt = hist_t + list(fx.emit_samples)
        idx = [j for j in range(len(hist), len(allv)) if j >= frames - 1]
        if idx:
            win = np.stack([allv[j - frames + 1: j + 1] for j in idx])
            scores.append(net.predict(win))
            times += [allt[j] for j in idx]
        keep = frames - 1
        hist = allv[len(allv) - keep:] if keep else np.zeros((0, 96), np.float32)
        hist_t = allt[len(allt) - keep:] if keep else []
    sc = np.concatenate(scores) if scores else np.zeros(0, np.float32)
    return (sc, np.asarray(times, np.int64)) if with_times else sc


def false_accepts(scores: np.ndarray, thresholds: dict, hours: float) -> dict:
    out = {}
    for lv in LEVELS:
        n = count_triggers(scores, Decider.for_level(lv, thresholds))
        out[lv] = {"false_accepts": int(n), "hours": round(hours, 3),
                   "per_hour": round(n / hours, 4) if hours > 0 else None,
                   "per_10h": round(10 * n / hours, 3) if hours > 0 else None}
    return out


def far_field_positives(rng: np.random.Generator, clips, noise: np.ndarray,
                        dist=(1.0, 2.0), snr=(5.0, 15.0)):
    """Held-out positives as heard from 1-2 m in a room with noise."""
    return [augment_clip(rng, x, noise, dist=dist, snr=snr, p_rir=1.0) for x in clips]


def false_rejects(fx: StreamingFeatures, net, clips, background: np.ndarray, frames: int,
                  thresholds: dict, rng: np.random.Generator, lead_s: float = 2.5,
                  tail_s: float = 1.0) -> dict:
    """Each clip is embedded in background (lead + clip + tail) and streamed;
    a hit = the Decider fires between clip start and clip end + tail."""
    hits = {lv: 0 for lv in LEVELS}
    n = 0
    for x in clips:
        lead, tail = int(lead_s * audio.SR), int(tail_s * audio.SR)
        total = lead + len(x) + tail
        bg = audio.random_crop(rng, background, total) if len(background) else np.zeros(total, np.float32)
        bg = audio.normalise(bg, -45.0) if np.any(bg) else bg
        y = bg.copy()
        y[lead: lead + len(x)] += x
        sc, ts = stream_scores(fx, net, (np.clip(y, -1, 1) * 32767).astype(np.int16), frames,
                               with_times=True)
        for lv in LEVELS:
            d = Decider.for_level(lv, thresholds)
            fired = False
            for s, t in zip(sc, ts):
                if d.feed(float(s)) and t >= lead:
                    fired = True
                    break
            hits[lv] += int(fired)
        n += 1
    return {lv: {"clips": n, "detected": hits[lv],
                 "false_reject_rate": round(1 - hits[lv] / n, 4) if n else None} for lv in LEVELS}


def pick_thresholds(val_neg_scores: np.ndarray, val_hours: float, val_pos_scores: np.ndarray,
                    target_fa_per_hour: float = 0.1) -> dict:
    """Thresholds chosen on VALIDATION data only (never on the eval sets):
      normal = lowest t whose validation false accepts/hour <= target
      low    = halfway between normal and 1 (fewer false wakes, 2-frame patience)
      high   = lowest t with <= 5x target (more responsive)
    Returns thresholds + the validation curve for the report."""
    grid = np.round(np.arange(0.05, 0.991, 0.01), 3)
    curve = []
    for t in grid:
        fa = count_triggers(val_neg_scores, Decider(threshold=float(t), patience=1))
        rec = float((val_pos_scores >= t).mean()) if len(val_pos_scores) else 0.0
        curve.append({"t": float(t), "fa": int(fa),
                      "fa_per_hour": fa / val_hours if val_hours > 0 else 0.0, "recall": rec})

    def lowest(limit):
        for row in curve:
            if row["fa_per_hour"] <= limit:
                return row["t"]
        return 0.99

    normal = lowest(target_fa_per_hour)
    high = min(normal, lowest(target_fa_per_hour * 5))
    low = round(normal + (1 - normal) * 0.5, 3)
    return {"thresholds": {"low": min(0.99, low), "normal": normal, "high": high}, "curve": curve}
