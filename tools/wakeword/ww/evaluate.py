"""Honest evaluation: false accepts per hour on long background streams and
false-reject rate on held-out positives, per sensitivity level, with the SAME
streaming extractor (embeddings computed by ww/embed.py exactly as on the
phone) + the SAME Decider the phone uses (threshold + patience + cooldown).

Thresholds are picked on VALIDATION data only, in logit space (no grid ceiling:
a saturating sigmoid pinned ww2's grid at 0.9999), then mapped through the
model's temperature to the score the phone compares."""
from __future__ import annotations

import numpy as np

from .detector import COOLDOWN_MS, FRAME_MS, LEVELS, PATIENCE, Decider, count_triggers

COOLDOWN_FRAMES = COOLDOWN_MS // FRAME_MS  # 25


def count_fast(scores: np.ndarray, threshold: float, patience: int = 1,
               cooldown_frames: int = COOLDOWN_FRAMES) -> int:
    """Same result as count_triggers(scores, Decider(threshold, patience)) but only
    visits frames at/above the threshold (pinned by a unit test)."""
    idx = np.nonzero(np.asarray(scores) >= threshold)[0]
    n, run, prev, last = 0, 0, -2, -10 ** 12
    for i in idx:
        run = run + 1 if i == prev + 1 else 1
        prev = i
        if run >= patience and i - last >= cooldown_frames:
            n += 1
            last = i
            run = 0
    return n


def fire_frames(scores: np.ndarray, threshold: float, patience: int = 1,
                cooldown_frames: int = COOLDOWN_FRAMES) -> list:
    idx = np.nonzero(np.asarray(scores) >= threshold)[0]
    out, run, prev, last = [], 0, -2, -10 ** 12
    for i in idx:
        run = run + 1 if i == prev + 1 else 1
        prev = i
        if run >= patience and i - last >= cooldown_frames:
            out.append(int(i))
            last = i
            run = 0
    return out


def poisson_upper_per_10h(n: int, hours: float, conf: float = 0.95) -> float | None:
    """One-sided upper confidence bound of the false-accept RATE (per 10 h)."""
    if hours <= 0:
        return None
    try:
        from scipy.stats import chi2
        up = 0.5 * float(chi2.ppf(conf, 2 * (n + 1)))
    except ImportError:  # normal approx fallback
        up = n + 1.645 * np.sqrt(n + 1) + 1
    return round(10 * up / hours, 3)


def false_accepts(scores, thresholds: dict, hours: float) -> dict:
    """scores: one array or a list of arrays (separate streams, decider reset)."""
    streams = scores if isinstance(scores, list) else [scores]
    out = {}
    for lv in LEVELS:
        n = sum(count_fast(s, float(thresholds[lv]), PATIENCE[lv]) for s in streams)
        out[lv] = {"false_accepts": int(n), "hours": round(hours, 3),
                   "per_hour": round(n / hours, 4) if hours > 0 else None,
                   "per_10h": round(10 * n / hours, 3) if hours > 0 else None,
                   "per_10h_upper95": poisson_upper_per_10h(int(n), hours)}
    return out


def false_rejects(scorer, frr: dict, thresholds: dict, frames: int = 16) -> dict:
    """frr = embed.frr_clips(...) output. A hit = the Decider fires at an
    emission time >= the clip start (lead)."""
    emb, offs, ts, lead = frr["emb"], frr["offsets"], frr["ts"], int(frr["lead"])
    hits = {lv: 0 for lv in LEVELS}
    n = len(offs) - 1
    for c in range(n):
        e = emb[offs[c]: offs[c + 1]]
        t = ts[offs[c]: offs[c + 1]]
        if len(e) < frames:
            continue
        sc = scorer.to_score(scorer.stream_logits(e))
        tt = t[frames - 1:]
        for lv in LEVELS:
            d = Decider.for_level(lv, thresholds)
            for s, ti in zip(sc, tt):
                if d.feed(float(s)) and ti >= lead:
                    hits[lv] += 1
                    break
    return {lv: {"clips": n, "detected": hits[lv],
                 "false_reject_rate": round(1 - hits[lv] / n, 4) if n else None} for lv in LEVELS}


def pick_thresholds_logit(val_logits: list, val_hours: float, pos_logits: np.ndarray,
                          target_fa_per_hour: float = 0.1, low_offset: float = 1.0,
                          high_mult: float = 5.0, step: float = 0.05, margin: float = 0.0) -> dict:
    """VALIDATION only. In logit space:
      normal = lowest L whose validation false accepts/hour (patience 1) <= target, + margin
      high   = lowest L with <= high_mult x target (more responsive), never above normal
      low    = normal + low_offset (and the app uses 2-frame patience at Low)
    Returns logits + the validation curve (FA/h and positive recall per L)."""
    vmax = max([float(np.max(v)) for v in val_logits if len(v)] + [0.0])
    vmin = min([float(np.min(v)) for v in val_logits if len(v)] + [0.0])
    lo = max(-10.0, min(vmin, -2.0))
    grid = np.arange(np.floor(lo / step) * step, vmax + 2 * step, step)
    curve = []
    for L in grid:
        fa = sum(count_fast(v, float(L), 1) for v in val_logits)
        rec = float((pos_logits >= L).mean()) if len(pos_logits) else 0.0
        curve.append({"L": float(L), "fa": int(fa),
                      "fa_per_hour": fa / val_hours if val_hours > 0 else 0.0, "recall": rec})

    def lowest(limit):
        for row in curve:
            if row["fa_per_hour"] <= limit:
                return row["L"]
        return curve[-1]["L"]

    normal = lowest(target_fa_per_hour) + margin
    high = min(normal, lowest(target_fa_per_hour * high_mult))
    low = normal + low_offset
    return {"logits": {"low": low, "normal": normal, "high": high}, "curve": curve,
            "val_max_logit": vmax}


def temperature_for(L_normal: float, target: float = 3.0) -> float:
    """T >= 1 so that sigmoid(L_normal / T) ~ sigmoid(target) (= 0.953): keeps
    every threshold far from float32's 1.0 on the phone."""
    return float(max(1.0, L_normal / target)) if L_normal > 0 else 1.0


def thresholds_from_logits(logits: dict, T: float, nd: int = 6) -> dict:
    """Score thresholds the app compares against (rounded DOWN to nd decimals so
    the phone never needs a higher score than the evaluation did)."""
    out = {}
    for lv, L in logits.items():
        s = 1.0 / (1.0 + np.exp(-float(L) / T))
        out[lv] = float(np.floor(s * 10 ** nd) / 10 ** nd)
    return out


# ---- legacy helpers kept for the tests / parity fixture -------------------------

def stream_scores(fx, net, stream_i16: np.ndarray, frames: int, chunk_s: int = 600,
                  with_times: bool = False):
    """Serial reference: one score per 80 ms frame (as on the phone)."""
    from . import audio
    fx.reset()
    embs, ts = [], []
    step = chunk_s * audio.SR
    for a in range(0, len(stream_i16), step):
        embs.append(fx.push(stream_i16[a: a + step].astype(np.float32) / 32768.0))
        ts += list(fx.emit_samples)
    e = np.concatenate(embs) if embs else np.zeros((0, 96), np.float32)
    if len(e) < frames:
        sc, tt = np.zeros(0, np.float32), np.zeros(0, np.int64)
    else:
        win = np.stack([e[j - frames + 1: j + 1] for j in range(frames - 1, len(e))])
        sc, tt = net.predict(win), np.asarray(ts[frames - 1:], np.int64)
    return (sc, tt) if with_times else sc


__all__ = ["count_fast", "count_triggers", "false_accepts", "false_rejects",
           "pick_thresholds_logit", "temperature_for", "thresholds_from_logits", "stream_scores"]
