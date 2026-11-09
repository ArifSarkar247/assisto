#!/usr/bin/env python3
"""Assemble rendered clips into one compressed audio file per Listening part + a manifest.

    python tools/lp/tts/assemble.py --plan work/plan.json --clips work/clips --out out/audio

Needs numpy + soundfile + ffmpeg (CI). Each clip: leading/trailing silence trimmed, level matched
(RMS), then joined with the plan's silences. The part is loudness-normalised and encoded to mp3.
audio_manifest.json records sha256, size, duration, cue times per question range, the voices and
their licences, and any honest substitutions (AU fallback, pitch shift).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys

import numpy as np
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
VOICES = json.load(open(os.path.join(HERE, "voices.json"), encoding="utf-8"))
SR = 24000
LICENCES = {
    "kokoro": {"engine": "Kokoro-82M v1.0 (kokoro==0.9.4, torch 2.6.0)", "licence": "Apache-2.0",
               "source": "https://huggingface.co/hexgrad/Kokoro-82M"},
    "melo": {"engine": "MeloTTS English (commit 209145371cff)", "licence": "MIT",
             "source": "https://huggingface.co/myshell-ai/MeloTTS-English"},
}


def load(path: str) -> np.ndarray:
    x, sr = sf.read(path, dtype="float32", always_2d=False)
    if x.ndim > 1:
        x = x.mean(axis=1)
    if sr != SR:
        raise ValueError(f"{path}: sample rate {sr} != {SR}")
    return x


def trim(x: np.ndarray, thr_db: float = -45.0, pad: float = 0.04) -> np.ndarray:
    if not len(x):
        return x
    frame = int(0.01 * SR)
    n = len(x) // frame
    if n == 0:
        return x
    e = np.sqrt((x[: n * frame].reshape(n, frame) ** 2).mean(axis=1) + 1e-12)
    loud = np.where(20 * np.log10(e) > thr_db)[0]
    if not len(loud):
        return x
    a = max(0, loud[0] * frame - int(pad * SR))
    b = min(len(x), (loud[-1] + 1) * frame + int(pad * SR))
    return x[a:b]


def level(x: np.ndarray, target_db: float = -20.0) -> np.ndarray:
    rms = np.sqrt((x ** 2).mean() + 1e-12)
    g = 10 ** (target_db / 20) / rms
    y = x * g
    peak = np.abs(y).max() if len(y) else 0
    return y / peak * 0.97 if peak > 0.97 else y


def median_f0(x: np.ndarray) -> float:
    """Rough median pitch (Hz) by autocorrelation over voiced frames (gender check only)."""
    f = int(0.04 * SR)
    hop = int(0.02 * SR)
    lo, hi = int(SR / 350), int(SR / 70)
    out = []
    for i in range(0, len(x) - f, hop):
        w = x[i:i + f] * np.hanning(f)
        if np.sqrt((w ** 2).mean()) < 0.01:
            continue
        ac = np.correlate(w, w, "full")[f - 1:]
        if ac[0] <= 0:
            continue
        k = lo + int(np.argmax(ac[lo:hi]))
        if ac[k] / ac[0] > 0.4:
            out.append(SR / k)
    return float(np.median(out)) if out else 0.0


def pitch_shift(x: np.ndarray, factor: float) -> np.ndarray:
    """Formant-naive pitch shift via ffmpeg asetrate+atempo (duration kept)."""
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        a, b = os.path.join(td, "a.wav"), os.path.join(td, "b.wav")
        sf.write(a, x, SR, subtype="PCM_16")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", a, "-af",
                        f"asetrate={int(SR * factor)},aresample={SR},atempo={1 / factor:.5f}", b],
                       check=True)
        return load(b)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--clips", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    plan = json.load(open(a.plan, encoding="utf-8"))
    os.makedirs(a.out, exist_ok=True)
    clips = plan["clips"]

    # Measure the Australian voice once: which gender does it sound like?
    melo_ids = [c for c, v in clips.items() if v["engine"] == "melo"
                and os.path.exists(os.path.join(a.clips, c + ".wav"))]
    melo_f0 = float(np.median([median_f0(load(os.path.join(a.clips, c + ".wav")))
                               for c in melo_ids[:12]])) if melo_ids else 0.0
    melo_gender = ("F" if melo_f0 >= 165 else "M") if melo_f0 else None
    print(f"melo EN-AU median F0 {melo_f0:.0f} Hz -> sounds {melo_gender}")

    manifest = {"format": "assisto.lp.audio/1", "voices_licences": LICENCES,
                "no_voice_cloning": True, "melo_au_measured": {"median_f0_hz": round(melo_f0),
                                                               "sounds": melo_gender},
                "files": []}
    errors = []
    for f in plan["files"]:
        parts = []
        t = 0.0
        cues = []
        used = {}
        subs = []
        for it in f["items"]:
            if it["kind"] == "silence":
                n = int(it["s"] * SR)
                parts.append(np.zeros(n, dtype=np.float32))
                t += n / SR
                continue
            if it["kind"] == "cue":
                cues.append({"questions": it["questions"], "start_s": round(t, 2)})
                continue
            c = clips[it["clip"]]
            path = os.path.join(a.clips, it["clip"] + ".wav")
            eng, voice = c["engine"], c["voice"]
            if not os.path.exists(path) and c.get("fallback"):
                fb = c["fallback"]
                path = os.path.join(a.clips, fb["clip"] + ".wav")
                eng, voice = fb["engine"], fb["voice"]
                subs.append({"role": it["role"], "wanted": f"{c['engine']}:{c['voice']}",
                             "used": f"{eng}:{voice}", "accent_substituted": True})
            if not os.path.exists(path):
                errors.append(f"{f['id']}: missing clip for {it['role']}: {c['text'][:50]!r}")
                continue
            x = trim(load(path))
            if eng == "melo" and melo_gender and c.get("gender") and c["gender"] != melo_gender:
                fac = 0.84 if c["gender"] == "M" else 1.17
                x = pitch_shift(x, fac)
                if not any(s.get("pitch_shift") and s["role"] == it["role"] for s in subs):
                    subs.append({"role": it["role"], "pitch_shift": fac,
                                 "why": f"only AU voice sounds {melo_gender}; script says {c['gender']}"})
            x = level(x)
            parts.append(x.astype(np.float32))
            t += len(x) / SR
            used[it["role"]] = {"engine": eng, "voice": voice, "licence": LICENCES[eng]["licence"]}
        if not parts:
            continue
        audio = np.concatenate(parts)
        wav = os.path.join(a.out, f["id"] + ".wav")
        mp3 = os.path.join(a.out, f["file"])
        sf.write(wav, audio, SR, subtype="PCM_16")
        enc = VOICES["encode"]
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav, "-af",
                        f"loudnorm={enc['loudnorm']}", "-ar", str(enc["sample_rate"]), "-ac", "1",
                        "-c:a", "libmp3lame", "-b:a", enc["bitrate"], mp3], check=True)
        os.remove(wav)
        data = open(mp3, "rb").read()
        manifest["files"].append({
            "id": f["id"], "file": f["file"], "bundle": f["bundle"], "part": f["part"],
            "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            "duration_s": round(t, 1), "cues": cues, "speakers": f["speakers"], "voices_used": used,
            "substitutions": subs})
        print(f"{f['file']}: {t / 60:.1f} min, {len(data) / 1e6:.2f} MB, subs={len(subs)}")
    manifest["errors"] = errors
    json.dump(manifest, open(os.path.join(a.out, "audio_manifest.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    if errors:
        print("\n".join(errors[:20]), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
