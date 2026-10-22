#!/usr/bin/env python3
""""Hey Assisto" wake-word training pipeline (openWakeWord-style head on a
frozen speech-embedding extractor). Runs in GitHub Actions
(.github/workflows/wakeword-train.yml); NEVER run a full training on the
shared dev box — only `--tiny` (a few clips, a few steps, no downloads).

  python3 tools/wakeword/pipeline.py --work /tmp/ww --config tools/wakeword/config.json all
  python3 tools/wakeword/pipeline.py --work /tmp/ww --tiny all          # smoke

Stages: features -> synth -> prepare -> windows -> train -> evaluate -> package
Output (work/out/): assisto_wake.onnx + feature model(s) + manifest.json +
MODEL_CARD.md + eval_report.{json,md} + licences.json. Copy that folder into
backend/core/wakeword_models/ (see tools/wakeword/README.md).
"""
from __future__ import annotations

import argparse
import datetime as _dt
import glob
import hashlib
import json
import os
import random
import shutil
import sys
import time
import zlib

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ww import audio, augment, datasets, evaluate, synth  # noqa: E402
from ww.detector import LEVELS, PATIENCE, COOLDOWN_MS  # noqa: E402
from ww.features import (HOP, MEL_CONTEXT, MEL_WINDOW, FeatureSpec,  # noqa: E402
                         StreamingFeatures, make_fake_e2e, write_spec)
from ww.model import WakeNet  # noqa: E402

OWW_RELEASE = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/"

DEFAULTS = {
    "frames": 16, "hidden": 64, "steps": 6000, "batch": 512, "lr": 0.001, "max_neg_weight": 30.0,
    "features": {"backend": "e2e"},
    "oww_feature_licence_confirmed": False,
    "tts": {"kokoro": True, "espeak": True, "piper": False, "piper_voices": [],
            "n_pos_train": 6000, "n_pos_test": 600, "n_neg_tts": 3000, "n_neg_tts_test": 300},
    "augment_rounds": 2, "stream_stride": 3,
    "data": {"fleurs_bn_hours": 8.0, "fleurs_bn_dev_hours": 2.5, "librispeech_hours": 4.0,
             "librispeech_test_hours": 2.0, "musan_files": 2500, "eval_bn_hours": 12.0},
    "target_fa_per_hour": 0.1, "target_fr": 0.10,
    "real_positive_dir": "",
    "seed": 1234, "tiny": False,
}

TINY = {
    "steps": 150, "batch": 64, "hidden": 16,
    "features": {"backend": "fake"},
    "tts": {"kokoro": False, "espeak": True, "piper": False, "piper_voices": [],
            "n_pos_train": 6, "n_pos_test": 3, "n_neg_tts": 6, "n_neg_tts_test": 3},
    "augment_rounds": 1, "stream_stride": 2, "tiny": True,
}


def log(*a):
    print(f"[ww {time.strftime('%H:%M:%S')}]", *a, flush=True)


def deep_update(d, u):
    for k, v in u.items():
        d[k] = deep_update(dict(d.get(k) or {}), v) if isinstance(v, dict) else v
    return d


def _rj(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _wj(obj, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


def _rt(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _wt(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class Ctx:
    def __init__(self, work, cfg):
        self.work, self.cfg = work, cfg
        self.rng = np.random.default_rng(cfg["seed"])
        self.prng = random.Random(cfg["seed"])
        for d in ("features", "clips", "prepared", "windows", "model", "out", "downloads"):
            os.makedirs(self.p(d), exist_ok=True)

    def p(self, *a):
        return os.path.join(self.work, *a)

    def spec(self) -> FeatureSpec:
        with open(self.p("features", "spec.json")) as f:
            return FeatureSpec.load(json.load(f), self.p("features"))

    def spec_window(self) -> int:
        s = self.spec()
        return s.window_samples if s.backend == "e2e" else MEL_WINDOW * 160 + MEL_CONTEXT


# ---- stages -------------------------------------------------------------------

def stage_features(c: Ctx):
    be = c.cfg["features"]["backend"]
    d = c.p("features")
    if be == "fake":
        make_fake_e2e(os.path.join(d, "fake_e2e.onnx"), window_samples=2560)
        spec = FeatureSpec("e2e", e2e_path="fake_e2e.onnx", window_samples=2560)
    elif be == "oww":
        for n in ("melspectrogram.onnx", "embedding_model.onnx"):
            datasets.download(OWW_RELEASE + n, os.path.join(d, n))
        spec = FeatureSpec("oww", mel_path="melspectrogram.onnx", embed_path="embedding_model.onnx")
    elif be == "e2e":
        # Built by rebuild_features.py from Google's Apache-2.0 speech_embedding
        # (run by the workflow in its own TensorFlow venv before this stage).
        info_p = os.path.join(d, "e2e_info.json")
        if not os.path.exists(info_p):
            raise SystemExit("features: e2e model missing — run rebuild_features.py first")
        info = _rj(info_p)
        spec = FeatureSpec("e2e", e2e_path=info["file"], window_samples=int(info["window_samples"]))
    else:
        raise SystemExit("unknown backend " + be)
    write_spec(os.path.join(d, "spec.json"), spec)
    log("features ready:", spec)


def _gen(c: Ctx, sub, n, positive):
    t = c.cfg["tts"]
    out = c.p("clips", sub)
    if os.path.isdir(out) and len(glob.glob(out + "/*.wav")) >= n:
        return
    shutil.rmtree(out, ignore_errors=True)
    rng = random.Random(zlib.crc32(f"{sub}:{c.cfg['seed']}".encode()))
    paths = []
    engines = [e for e in ("kokoro", "piper", "espeak") if t.get(e)]
    share = max(1, n // max(1, len(engines)))
    if t.get("kokoro"):
        paths += synth.kokoro_clips(out, share, positive, rng)
    if t.get("piper"):
        voices = [(v["model"], int(v.get("speakers", 1))) for v in t.get("piper_voices", [])]
        paths += synth.piper_clips(out, share, positive, rng, voices)
    if t.get("espeak"):
        paths += synth.espeak_clips(out, n - len(paths), positive, rng)
    if not paths and c.cfg["tiny"]:
        paths = synth.tone_clips(out, n, rng, positive)
    log(f"synth {sub}: {len(paths)} clips (engines={engines})")
    if not paths:
        raise SystemExit(f"synth {sub}: no TTS engine produced audio")


def stage_synth(c: Ctx):
    t = c.cfg["tts"]
    _gen(c, "pos_train", t["n_pos_train"], True)
    _gen(c, "pos_test", t["n_pos_test"], True)
    _gen(c, "neg_train", t["n_neg_tts"], False)
    _gen(c, "neg_test", t["n_neg_tts_test"], False)
    rp = c.cfg.get("real_positive_dir")
    if rp and os.path.isdir(rp):
        dst = c.p("clips", "pos_real")
        os.makedirs(dst, exist_ok=True)
        for i, f in enumerate(sorted(glob.glob(os.path.join(rp, "*.wav")))):
            audio.write_wav(os.path.join(dst, f"real_{i:05d}.wav"), audio.read_audio(f))


def stage_prepare(c: Ctx):
    pd = c.p("prepared")
    if c.cfg["tiny"]:
        # no downloads: coloured noise + tone babble as "background"
        r = c.rng
        def noise(sec):
            x = r.standard_normal(int(sec * audio.SR)).astype(np.float32)
            x = np.cumsum(x) * 0.02  # brown-ish
            x -= np.convolve(x, np.ones(400) / 400, mode="same")
            return (np.clip(x / (np.abs(x).max() + 1e-9) * 0.3, -1, 1) * 32767).astype(np.int16)
        for name, sec in (("neg_train", 120), ("val_bn", 60), ("eval_bn", 90), ("eval_tv", 60),
                          ("eval_en", 30), ("musan_train", 60), ("musan_eval", 30)):
            np.save(os.path.join(pd, name + ".npy"), noise(sec))
        _wj({"tiny": True}, os.path.join(pd, "report.json"))
        return
    d = c.cfg["data"]
    dl = c.p("downloads")
    rep = {}

    def get(key):
        s = datasets.SOURCES[key]
        return datasets.download(s["url"], os.path.join(dl, os.path.basename(s["url"])))

    def save(name, arr):
        np.save(os.path.join(pd, name + ".npy"), arr)
        rep[name] = round(len(arr) / audio.SR / 3600, 3)
        log(f"prepared {name}: {rep[name]} h")

    if not os.path.exists(os.path.join(pd, "musan_train.npy")):
        rep["musan"] = datasets.musan_split(get("musan"), pd, max_files=d["musan_files"])
        os.remove(os.path.join(dl, "musan.tar.gz"))  # 11 GB: keep only the prepared subset
    music = np.load(os.path.join(pd, "musan_train.npy"))
    bn = datasets.archive_to_stream(get("fleurs_bn"), d["fleurs_bn_hours"], seed=1)
    en = datasets.archive_to_stream(get("librispeech_dev"), d["librispeech_hours"], seed=2)
    tv = datasets.tv_like_mix(bn[: len(bn) // 3], music, seed=3)
    save("neg_train", np.concatenate([bn, en, tv, music]))
    save("val_bn", datasets.archive_to_stream(get("fleurs_bn_dev"), d["fleurs_bn_dev_hours"], seed=4))
    eval_bn = datasets.archive_to_stream(get("slr53_bn"), d["eval_bn_hours"], seed=5)
    save("eval_bn", eval_bn)
    music_eval = np.load(os.path.join(pd, "musan_eval.npy"))
    save("eval_tv", datasets.tv_like_mix(eval_bn[: 2 * 3600 * audio.SR], music_eval, seed=6))
    save("eval_en", datasets.archive_to_stream(get("librispeech_test"), d["librispeech_test_hours"], seed=7))
    _wj(rep, os.path.join(pd, "report.json"))


def _clips(c: Ctx, sub):
    return [audio.read_audio(f) for f in sorted(glob.glob(c.p("clips", sub, "*.wav")))]


def stage_windows(c: Ctx):
    fx = StreamingFeatures(c.spec())
    fr, sw = c.cfg["frames"], c.spec_window()
    noise = np.load(c.p("prepared", "musan_train.npy")).astype(np.float32) / 32768.0
    neg_stream = np.load(c.p("prepared", "neg_train.npy"))
    rounds = c.cfg["augment_rounds"]
    pos = _clips(c, "pos_train") + _clips(c, "pos_real") * 3
    np.save(c.p("windows", "pos_train.npy"),
            augment.clip_windows(fx, c.rng, pos, noise, fr, sw, rounds=rounds).astype(np.float16))
    negs = [augment.clip_windows(fx, c.rng, _clips(c, "neg_train"), noise, fr, sw, rounds=rounds),
            augment.stream_windows(fx, neg_stream, fr, stride=c.cfg["stream_stride"]).astype(np.float32)]
    neg = np.concatenate([n for n in negs if len(n)]).astype(np.float16)
    np.save(c.p("windows", "neg_train.npy"), neg)
    np.save(c.p("windows", "pos_val.npy"),
            augment.clip_windows(fx, c.rng, _clips(c, "pos_test")[::2], noise, fr, sw, rounds=1,
                                 dist=(1.0, 2.0), snr=(5.0, 15.0)).astype(np.float16))
    log(f"windows: pos={len(np.load(c.p('windows', 'pos_train.npy')))} neg={len(neg)}")


def stage_train(c: Ctx):
    pos = np.load(c.p("windows", "pos_train.npy")).astype(np.float32)
    neg = np.load(c.p("windows", "neg_train.npy"))
    pv = np.load(c.p("windows", "pos_val.npy")).astype(np.float32)
    net = WakeNet(c.cfg["frames"], 96, c.cfg["hidden"], seed=c.cfg["seed"])
    # float16 negatives are cast per batch inside fit (via fancy indexing)
    hist = net.fit(pos, neg, steps=c.cfg["steps"], batch=c.cfg["batch"], lr=c.cfg["lr"],
                   max_neg_weight=c.cfg["max_neg_weight"], seed=c.cfg["seed"], log=log,
                   val=(pv, neg[:: max(1, len(neg) // 20000)].astype(np.float32)))
    net.save_npz(c.p("model", "net.npz"))
    net.to_onnx(c.p("model", "assisto_wake.onnx"))
    _wj(hist, c.p("model", "train_history.json"))


def stage_evaluate(c: Ctx):
    fx = StreamingFeatures(c.spec())
    net = WakeNet.load_npz(c.p("model", "net.npz"))
    fr = c.cfg["frames"]
    hours = lambda a: len(a) / audio.SR / 3600  # noqa: E731
    val = np.load(c.p("prepared", "val_bn.npy"))
    neg_test = _clips(c, "neg_test")
    val_neg = np.concatenate([val] + [(np.pad(x, (audio.SR, audio.SR)) * 32767).astype(np.int16)
                                      for x in neg_test])
    val_sc = evaluate.stream_scores(fx, net, val_neg, fr)
    pv = np.load(c.p("windows", "pos_val.npy")).astype(np.float32)
    pick = evaluate.pick_thresholds(val_sc, hours(val_neg), net.predict(pv), c.cfg["target_fa_per_hour"])
    th = pick["thresholds"]
    log("thresholds (validation):", th)
    report = {"thresholds": th, "validation_hours": round(hours(val_neg), 3), "false_accepts": {},
              "false_rejects": {}, "patience": PATIENCE, "cooldown_ms": COOLDOWN_MS}
    for name in ("eval_bn", "eval_tv", "eval_en"):
        s = np.load(c.p("prepared", name + ".npy"))
        report["false_accepts"][name] = evaluate.false_accepts(
            evaluate.stream_scores(fx, net, s, fr), th, hours(s))
        log(name, report["false_accepts"][name])
    noise_eval = np.load(c.p("prepared", "musan_eval.npy")).astype(np.float32) / 32768.0
    bg = np.load(c.p("prepared", "eval_bn.npy")).astype(np.float32) / 32768.0
    test = _clips(c, "pos_test")[1::2]
    far = evaluate.far_field_positives(c.rng, test, noise_eval)
    report["false_rejects"]["synthetic_far_field_1_2m"] = evaluate.false_rejects(
        fx, net, far, bg, fr, th, c.rng)
    near = evaluate.far_field_positives(c.rng, test, noise_eval, dist=(0.3, 0.8), snr=(15, 30))
    report["false_rejects"]["synthetic_near_0_3_0_8m"] = evaluate.false_rejects(
        fx, net, near, bg, fr, th, c.rng)
    real = _clips(c, "pos_real")
    if real:
        report["false_rejects"]["real_recordings_in_training"] = evaluate.false_rejects(
            fx, net, real, bg, fr, th, c.rng)
    report["targets"] = {
        "false_accepts_per_10h_bangla_lt": 1.0, "false_reject_lt": c.cfg["target_fr"],
        "met_normal_bangla_fa": (report["false_accepts"]["eval_bn"]["normal"]["per_10h"] or 0) < 1.0,
        "met_normal_fr_far_field":
            (report["false_rejects"]["synthetic_far_field_1_2m"]["normal"]["false_reject_rate"] or 1) < c.cfg["target_fr"],
        "note": "False rejects are measured on SYNTHETIC far-field speech; confirm on a real phone "
                "(owner_actions/PHONE_TEST_CHECKLIST.md).",
    }
    report["validation_curve"] = pick["curve"][::5]
    _wj(report, c.p("model", "eval_report.json"))


def _report_md(rep: dict, cfg: dict, prep: dict) -> str:
    L = ["# Hey Assisto — evaluation report", "",
         f"Generated {_dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by tools/wakeword/pipeline.py"
         + (" (TINY SMOKE RUN — numbers are meaningless)" if cfg["tiny"] else ""), "",
         f"Thresholds (picked on validation only): {rep['thresholds']}; patience {rep['patience']}; "
         f"cooldown {rep['cooldown_ms']} ms", "", "## False accepts (streaming, 80 ms frames)", "",
         "| set | hours | level | false accepts | per 10 h |", "|---|---|---|---|---|"]
    for name, by in rep["false_accepts"].items():
        for lv in LEVELS:
            r = by[lv]
            L.append(f"| {name} | {r['hours']} | {lv} | {r['false_accepts']} | {r['per_10h']} |")
    L += ["", "## False rejects", "", "| set | level | clips | detected | false-reject rate |",
          "|---|---|---|---|---|"]
    for name, by in rep["false_rejects"].items():
        for lv in LEVELS:
            r = by[lv]
            L.append(f"| {name} | {lv} | {r['clips']} | {r['detected']} | {r['false_reject_rate']} |")
    t = rep["targets"]
    L += ["", "## Targets", "",
          f"- Bangla background, Normal: < 1 false accept per 10 h -> {'MET' if t['met_normal_bangla_fa'] else 'NOT MET'}",
          f"- Far-field 1-2 m (synthetic), Normal: false rejects < {int(cfg['target_fr'] * 100)}% -> "
          f"{'MET' if t['met_normal_fr_far_field'] else 'NOT MET'}",
          f"- {t['note']}", "", "Prepared data (hours): `" + json.dumps(prep) + "`"]
    return "\n".join(L) + "\n"


def stage_package(c: Ctx):
    out = c.p("out")
    spec = c.spec()
    rep = _rj(c.p("model", "eval_report.json"))
    prep = _rj(c.p("prepared", "report.json"))
    files = [("wake", c.p("model", "assisto_wake.onnx"), "assisto_wake.onnx")]
    if spec.backend == "oww":
        files += [("mel", spec.mel_path, "oww_melspectrogram.onnx"),
                  ("embed", spec.embed_path, "oww_embedding.onnx")]
    else:
        files += [("e2e", spec.e2e_path, "assisto_embed_e2e.onnx")]
    entries = []
    for role, src, name in files:
        shutil.copyfile(src, os.path.join(out, name))
        entries.append({"role": role, "name": name, "sha256": sha256(src), "size": os.path.getsize(src)})
    t = c.cfg["tts"]
    train_sources_ok = all(datasets.SOURCES[k]["commercial_ok"] for k in datasets.SOURCES)
    if spec.backend == "e2e" and c.cfg["features"]["backend"] == "e2e":
        feat_ok, feat_note = True, "Google speech_embedding (Apache-2.0) rebuilt by rebuild_features.py"
    elif spec.backend == "oww":
        feat_ok = bool(c.cfg.get("oww_feature_licence_confirmed"))
        feat_note = ("openWakeWord v0.5.1 melspectrogram/embedding ONNX — commercial licence "
                     + ("CONFIRMED by the maintainer (config flag)" if feat_ok else "UNCONFIRMED"))
    else:
        feat_ok, feat_note = False, "FAKE test extractor (smoke run) — never ship"
    cleared = bool(feat_ok and train_sources_ok and not t.get("piper") and not c.cfg["tiny"])
    manifest = {
        "version": _dt.datetime.now(_dt.timezone.utc).strftime("%Y.%m.%d.%H%M"), "engine": "openwakeword",
        "feature_backend": spec.backend, "window_samples": spec.window_samples, "hop_samples": HOP,
        "frames": c.cfg["frames"], "files": entries, "thresholds": rep["thresholds"],
        "patience": PATIENCE, "cooldown_ms": COOLDOWN_MS,
        "licence_cleared": cleared,
        "licence_notes": {"features": feat_note,
                          "piper_used": bool(t.get("piper")),
                          "tiny_smoke": bool(c.cfg["tiny"])},
        "eval": {"false_accepts": rep["false_accepts"], "false_rejects": rep["false_rejects"],
                 "targets": rep["targets"]},
    }
    _wj(manifest, os.path.join(out, "manifest.json"))
    _wj(rep, os.path.join(out, "eval_report.json"))
    _wt(os.path.join(out, "eval_report.md"), _report_md(rep, c.cfg, prep))
    _wj({"datasets": datasets.SOURCES, "tts": t, "features": feat_note},
        os.path.join(out, "licences.json"))
    card = _rt(os.path.join(os.path.dirname(os.path.abspath(__file__)), "MODEL_CARD.md"))
    _wt(os.path.join(out, "MODEL_CARD.md"),
        card + "\n\n---\n\n## This build\n\n```json\n" + json.dumps(
            {k: manifest[k] for k in ("version", "feature_backend", "thresholds", "licence_cleared",
                                      "licence_notes")}, indent=1) + "\n```\n")
    log("packaged ->", out, "licence_cleared=", cleared)


STAGES = {"features": stage_features, "synth": stage_synth, "prepare": stage_prepare,
          "windows": stage_windows, "train": stage_train, "evaluate": stage_evaluate,
          "package": stage_package}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--config", default="")
    ap.add_argument("--tiny", action="store_true")
    ap.add_argument("stages", nargs="+", help="|".join(STAGES) + "|all")
    a = ap.parse_args(argv)
    cfg = json.loads(json.dumps(DEFAULTS))
    if a.config:
        deep_update(cfg, _rj(a.config))
    if a.tiny:
        deep_update(cfg, TINY)
    c = Ctx(a.work, cfg)
    _wj(cfg, c.p("config.used.json"))
    names = list(STAGES) if a.stages == ["all"] else a.stages
    for n in names:
        t0 = time.time()
        log("stage", n)
        STAGES[n](c)
        log(f"stage {n} done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
