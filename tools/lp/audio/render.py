#!/usr/bin/env python3
"""lpaudio: render the IELTS listening audio in CI (never on the server).

    python tools/lp/audio/render.py --content tools/lp/content --out out/lp_audio \
        [--have prev/manifest.json] [--plan-only]

Plan (who says what, which voice, pauses) comes from backend/core/logic/lp_audio.py
— the same code the server uses to check that a file belongs to the CURRENT script.
Engine: Kokoro-82M v1.0 (Apache-2.0), stock British / American voices, no cloning.
Each part -> one mono AAC .m4a (40 kbit/s, faststart so the phone can stream it)
named <bundle>-p<n>-<planhash12>.m4a, plus manifest.json (sha256, bytes, duration,
voices, accents). Parts whose file is already in the previous release manifest
(--have) are not rendered again (CI budget).
"""
from __future__ import annotations

import argparse
import datetime
import glob
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def load_lp_audio():
    path = os.path.join(ROOT, "backend", "core", "logic", "lp_audio.py")
    spec = importlib.util.spec_from_file_location("lp_audio", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


A = load_lp_audio()


def all_plans(content):
    plans = []
    for f in sorted(glob.glob(os.path.join(content, "ielts", "ielts-*.json"))):
        with open(f, encoding="utf-8") as fh:
            d = json.load(fh)
        if d.get("format") == "assisto.lp.ielts/1":
            plans.extend(A.bundle_plans(d))
    return plans


class Synth:
    def __init__(self):
        from kokoro import KPipeline  # CI only (torch + kokoro + misaki[en], pinned in the workflow)
        self._kp = KPipeline
        self._pipes = {}

    def say(self, voice, text):
        import numpy as np
        lang = voice[0]
        if lang not in self._pipes:
            self._pipes[lang] = self._kp(lang_code=lang)
        chunks = [np.asarray(a, dtype=np.float32).reshape(-1)
                  for _, _, a in self._pipes[lang](text, voice=voice, speed=A.SPEED) if a is not None]
        if not chunks:
            raise RuntimeError("no audio for %r" % text[:60])
        return np.concatenate(chunks)


def trim(x, thr=0.004):
    import numpy as np
    idx = np.where(np.abs(x) > thr)[0]
    if not len(idx):
        return x
    pad = int(0.03 * A.SAMPLE_RATE)
    return x[max(0, idx[0] - pad): idx[-1] + pad]


def render(plan, synth, out_dir):
    import numpy as np
    import soundfile as sf
    sr = A.SAMPLE_RATE
    pieces = [np.zeros(int(0.5 * sr), dtype=np.float32)]
    for s in plan["segments"]:
        pieces.append(trim(synth.say(s["voice"], s["text"])))
        pieces.append(np.zeros(int(float(s.get("gap") or 0) * sr), dtype=np.float32))
    x = np.concatenate(pieces)
    peak = float(np.max(np.abs(x))) or 1.0
    x = (x / peak * 0.89).astype(np.float32)
    dst = os.path.join(out_dir, plan["file"])
    with tempfile.TemporaryDirectory() as td:
        wav = os.path.join(td, "p.wav")
        sf.write(wav, x, sr, subtype="PCM_16")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                        "-af", "loudnorm=I=-19:TP=-1.5:LRA=11", "-ar", str(sr), "-ac", "1",
                        "-c:a", "aac", "-b:a", "40k", "-movflags", "+faststart", dst], check=True)
    return round(len(x) / sr, 2)


def entry(plan, path, duration):
    with open(path, "rb") as fh:
        blob = fh.read()
    return {"bundle": plan["bundle"], "part": plan["part"], "plan_hash": plan["hash"],
            "file": plan["file"], "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
            "duration_sec": duration, "voices": plan["voices"], "accents": plan["accents"],
            "narrator": A.NARRATOR, "preview_sec": plan["preview_sec"], "check_sec": plan["check_sec"]}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--content", default=os.path.join(ROOT, "tools", "lp", "content"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--have", default="", help="previous release manifest.json (skip parts already there)")
    ap.add_argument("--plan-only", action="store_true")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    plans = all_plans(a.content)
    if a.plan_only:
        with open(os.path.join(a.out, "plans.json"), "w", encoding="utf-8") as fh:
            json.dump(plans, fh, ensure_ascii=False, indent=1)
        print("plans:", len(plans))
        return 0
    have = {}
    if a.have and os.path.exists(a.have):
        with open(a.have, encoding="utf-8") as fh:
            have = {e["file"]: e for e in (json.load(fh).get("parts") or [])}
    synth = None
    parts, rendered = [], []
    for pl in plans:
        if pl["file"] in have:
            parts.append(have[pl["file"]])
            continue
        synth = synth or Synth()
        dur = render(pl, synth, a.out)
        e = entry(pl, os.path.join(a.out, pl["file"]), dur)
        parts.append(e)
        rendered.append(pl["file"])
        print("rendered %s  %.0fs  %d KB  %s" % (pl["file"], dur, e["bytes"] // 1024,
                                                 ",".join(v["voice"] for v in pl["voices"])), flush=True)
    man = {"format": A.FORMAT, "engine": A.ENGINE, "release": A.RELEASE_TAG,
           "generated_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
           "licence_note": "Kokoro-82M v1.0 (Apache-2.0) stock voices; no voice cloning; "
                           "see owner_actions/LP_AUDIO_LICENSE_BN.md",
           "parts": parts}
    with open(os.path.join(a.out, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(man, fh, ensure_ascii=False, indent=1)
    with open(os.path.join(a.out, "rendered.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(rendered) + ("\n" if rendered else ""))
    print("parts: %d, rendered now: %d" % (len(parts), len(rendered)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
