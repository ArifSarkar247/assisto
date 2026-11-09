#!/usr/bin/env python3
"""Render the clips of a TTS plan with ONE engine (CI only; each engine has its own venv).

    python tools/lp/tts/synth.py --engine kokoro --plan work/plan.json --clips work/clips
    python tools/lp/tts/synth.py --engine melo   --plan work/plan.json --clips work/clips

Writes <clips>/<clip>.wav (mono, 24 kHz, 16-bit). Existing files are kept (cache). A failed clip is
reported and skipped; assemble.py then uses the fallback voice (AU) or fails loudly (others).
Kokoro: Apache-2.0, hexgrad/Kokoro-82M. MeloTTS: MIT, myshell-ai/MeloTTS-English. No voice cloning.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

SR = 24000


def to_24k(src: str, dst: str):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", src, "-ac", "1", "-ar", str(SR),
                    "-sample_fmt", "s16", dst], check=True)


def run_kokoro(todo: dict, out: str) -> dict:
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline
    pipes = {}
    fails = {}
    for i, (cid, c) in enumerate(todo.items()):
        try:
            lang = c["lang"]
            if lang not in pipes:
                pipes[lang] = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M")
            chunks = [a for _, _, a in pipes[lang](c["text"], voice=c["voice"], speed=1.0)]
            audio = np.concatenate([np.asarray(a, dtype=np.float32) for a in chunks])
            sf.write(os.path.join(out, cid + ".wav"), audio, SR, subtype="PCM_16")
        except Exception as e:  # noqa: BLE001
            fails[cid] = repr(e)[:300]
        if i % 50 == 0:
            print(f"kokoro {i + 1}/{len(todo)}", flush=True)
    return fails


def run_melo(todo: dict, out: str) -> dict:
    from melo.api import TTS
    model = TTS(language="EN", device="cpu")
    spk = model.hps.data.spk2id
    fails = {}
    with tempfile.TemporaryDirectory() as td:
        for cid, c in todo.items():
            try:
                tmp = os.path.join(td, "x.wav")
                model.tts_to_file(c["text"], spk[c["voice"]], tmp, speed=1.0)
                to_24k(tmp, os.path.join(out, cid + ".wav"))
            except Exception as e:  # noqa: BLE001
                fails[cid] = repr(e)[:300]
    return fails


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=["kokoro", "melo"])
    ap.add_argument("--plan", required=True)
    ap.add_argument("--clips", required=True)
    a = ap.parse_args(argv)
    plan = json.load(open(a.plan, encoding="utf-8"))
    os.makedirs(a.clips, exist_ok=True)
    todo = {cid: c for cid, c in plan["clips"].items()
            if c["engine"] == a.engine and not os.path.exists(os.path.join(a.clips, cid + ".wav"))}
    print(f"{a.engine}: {len(todo)} clips to render", flush=True)
    t0 = time.time()
    fails = (run_kokoro if a.engine == "kokoro" else run_melo)(todo, a.clips) if todo else {}
    rep = {"engine": a.engine, "rendered": len(todo) - len(fails), "failed": fails,
           "seconds": round(time.time() - t0, 1)}
    json.dump(rep, open(os.path.join(a.clips, f"_synth_{a.engine}.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in rep.items() if k != "failed"}), f"failed={len(fails)}")
    if fails:
        print("first failure:", next(iter(fails.values())), file=sys.stderr)
        # Kokoro carries the narrator and GB/US voices: any failure is fatal. MeloTTS (AU) is
        # optional: assemble.py falls back to a labelled GB voice for missing AU clips.
        if a.engine == "kokoro":
            sys.exit(1)


if __name__ == "__main__":
    main()
