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
    for lang in sorted(A.TRACK_VOICES):           # language-course test questions (ja, zh, fr)
        for f in sorted(glob.glob(os.path.join(content, lang, "*.json"))):
            with open(f, encoding="utf-8") as fh:
                plans.extend(A.track_plans(json.load(fh), lang))
    return plans


class LangUnavailable(Exception):
    pass


class Synth:
    def __init__(self):
        from kokoro import KPipeline  # CI only (torch + kokoro + misaki[en], pinned in the workflow)
        self._kp = KPipeline
        self._pipes = {}

    def say(self, voice, text, speed):
        import numpy as np
        base, _, effect = voice.partition("+")
        lang = base[0]                      # Kokoro: the voice prefix is the language code
        if lang not in self._pipes:
            try:
                self._pipes[lang] = self._kp(lang_code=lang)
            except Exception as e:  # noqa: BLE001 — e.g. misaki[ja] not installable on the runner
                self._pipes[lang] = e
        if isinstance(self._pipes[lang], Exception):
            raise LangUnavailable("%s: %s" % (lang, str(self._pipes[lang])[:200]))
        chunks = [np.asarray(a, dtype=np.float32).reshape(-1)
                  for _, _, a in self._pipes[lang](text, voice=base, speed=speed) if a is not None]
        if not chunks:
            raise RuntimeError("no audio for %r" % text[:60])
        x = np.concatenate(chunks)
        return lower_pitch(x) if effect == "low" else x


def lower_pitch(x, factor=0.84):
    """~3 semitones lower, same tempo (ffmpeg asetrate + atempo) — an effect on
    the same synthetic voice for a second speaker, never cloning."""
    import numpy as np
    import soundfile as sf
    sr = A.SAMPLE_RATE
    with tempfile.TemporaryDirectory() as td:
        a, b = os.path.join(td, "a.wav"), os.path.join(td, "b.wav")
        sf.write(a, x, sr, subtype="PCM_16")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", a, "-af",
                        "asetrate=%d,aresample=%d,atempo=%.4f" % (int(sr * factor), sr, 1 / factor), b], check=True)
        y, _ = sf.read(b, dtype="float32")
    return np.asarray(y, dtype=np.float32).reshape(-1)


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
    one = []
    for s in plan["segments"]:
        one.append(trim(synth.say(s["voice"], s["text"], plan.get("speed") or A.SPEED)))
        one.append(np.zeros(int(float(s.get("gap") or 0) * sr), dtype=np.float32))
    one = np.concatenate(one)
    pieces = [np.zeros(int(0.5 * sr), dtype=np.float32)]
    for i in range(int(plan.get("plays") or 1)):     # "you will hear it twice" = in the recording
        if i:
            pieces.append(np.zeros(int(float(plan.get("repeat_gap") or 3) * sr), dtype=np.float32))
        pieces.append(one)
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
    parts, rendered, skipped = [], [], []
    for pl in plans:
        if pl["file"] in have:
            parts.append(have[pl["file"]])
            continue
        synth = synth or Synth()
        try:
            dur = render(pl, synth, a.out)
        except LangUnavailable as e:
            skipped.append("%s (%s)" % (pl["file"], e))
            continue
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
    for x in skipped[:5]:
        print("SKIPPED (voice/G2P not available on this runner):", x)
    print("parts: %d, rendered now: %d, skipped: %d" % (len(parts), len(rendered), len(skipped)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
