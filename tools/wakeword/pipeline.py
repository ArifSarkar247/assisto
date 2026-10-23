#!/usr/bin/env python3
""""Hey Assisto" wake-word training pipeline (openWakeWord-style head on a
frozen speech-embedding extractor). Runs in GitHub Actions
(.github/workflows/wakeword-train.yml); NEVER run a full training on the
shared dev box — only `--tiny` (a few clips, a few steps, no downloads).

  python3 tools/wakeword/pipeline.py --work /tmp/ww --config tools/wakeword/config.json all
  python3 tools/wakeword/pipeline.py --work /tmp/ww --tiny all          # smoke
  python3 tools/wakeword/pipeline.py --work /tmp/ww --config c.json embed_key   # cache key

Stages: features -> synth -> prepare -> embed -> train -> evaluate -> package
  embed     every embedding the run needs, computed ONCE (frozen extractor) and
            cached by the workflow: training streams + clip windows, validation
            and test streams, false-reject clips. Real recordings (if any) go to
            emb_real/ which is never cached or uploaded.
  train     one classifier per seed (config "seeds"), hard-negative mining,
            checkpoint selection on validation.
  evaluate  thresholds on validation only; FA / 10 h per test set (+ 95 % upper
            bound) and FRR per level for EVERY seed and for the seed ensemble;
            the shipped candidate is chosen on validation.
Output (work/out/): assisto_wake.onnx + feature model + manifest.json +
MODEL_CARD.md + eval_report.{json,md} + licences.json.
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

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ww import audio, datasets, embed, evaluate, synth  # noqa: E402
from ww.detector import COOLDOWN_MS, LEVELS, PATIENCE  # noqa: E402
from ww.features import (HOP, MEL_CONTEXT, MEL_WINDOW, FeatureSpec,  # noqa: E402
                         make_fake_e2e, write_spec)
from ww.model import FramePool, Scorer, WakeNet, train  # noqa: E402

OWW_RELEASE = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/"

DEFAULTS = {
    "frames": 16, "smooth_k": 2, "hidden": 64,
    "train": {"steps": 20000, "batch": 512, "lr": 0.001, "warmup": 500, "lr_min_frac": 0.05,
              "max_neg_weight": 30.0, "ema": 0.999, "l2": 1e-5, "mine_at": [0.3, 0.5, 0.7],
              "mine_k": 30000, "mine_frac": 0.4, "clip_frac": 0.25, "eval_every": 1000,
              "select_after": 0.3},
    "seeds": [1234, 2025, 7],
    "ensemble": True,
    "features": {"backend": "e2e"},
    "oww_feature_licence_confirmed": False,
    "tts": {"kokoro": True, "espeak": True, "piper": False, "piper_voices": [],
            "n_pos_train": 6000, "n_pos_test": 1000, "n_neg_tts": 6000, "n_neg_tts_test": 600},
    "augment_rounds": 2, "neg_augment_rounds": 2,
    "data": {"fleurs_bn_hours": 8.0, "fleurs_hi_hours": 3.0, "fleurs_bn_dev_hours": 2.5,
             "librispeech_hours": 4.0, "librispeech_test_hours": 2.0, "musan_files": 2500,
             "musan_speech_files": 300, "eval_bn_hours": 10.0, "eval_tv_hours": 10.0,
             "tv_en_train_hours": 4.0},
    "thresholds": {"target_fa_per_hour": 0.1, "low_offset": 1.0, "high_mult": 5.0,
                   "margin": 0.0, "temperature_target": 3.0},
    "target_fr": 0.10,
    "target_fa_per_10h": 1.0,
    "min_test_hours": 20.0,
    "real_clips": {"dir": "", "test_speaker_frac": 0.3},
    "seed": 1234, "tiny": False,
}

TINY = {
    "hidden": 16, "seeds": [1, 2],
    "train": {"steps": 200, "batch": 64, "warmup": 20, "eval_every": 50, "mine_k": 200,
              "mine_at": [0.5]},
    "features": {"backend": "fake"},
    "tts": {"kokoro": False, "espeak": True, "piper": False, "piper_voices": [],
            "n_pos_train": 6, "n_pos_test": 6, "n_neg_tts": 6, "n_neg_tts_test": 4},
    "augment_rounds": 1, "neg_augment_rounds": 1, "min_test_hours": 0.0, "tiny": True,
}

# Embedding files whose content depends on the config subsets below (cache key).
EMBED_CFG_KEYS = ("frames", "features", "tts", "augment_rounds", "neg_augment_rounds", "data",
                  "seed", "tiny")
EMBED_CODE = ("ww/audio.py", "ww/augment.py", "ww/datasets.py", "ww/embed.py", "ww/features.py",
              "ww/synth.py", "rebuild_features.py")


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


def embed_key(cfg) -> str:
    h = hashlib.sha256()
    h.update(json.dumps({k: cfg.get(k) for k in EMBED_CFG_KEYS}, sort_keys=True).encode())
    for f in EMBED_CODE:
        p = os.path.join(HERE, f)
        if os.path.exists(p):
            with open(p, "rb") as fh:
                h.update(fh.read())
    return h.hexdigest()[:24]


class Ctx:
    def __init__(self, work, cfg):
        self.work, self.cfg = work, cfg
        for d in ("features", "clips", "prepared", "emb", "emb_real", "model", "out", "downloads"):
            os.makedirs(self.p(d), exist_ok=True)

    def p(self, *a):
        return os.path.join(self.work, *a)

    def spec(self) -> FeatureSpec:
        with open(self.p("features", "spec.json")) as f:
            return FeatureSpec.load(json.load(f), self.p("features"))

    def spec_window(self) -> int:
        s = self.spec()
        return s.window_samples if s.backend == "e2e" else MEL_WINDOW * 160 + MEL_CONTEXT

    def prep(self, name, mmap=True):
        return np.load(self.p("prepared", name + ".npy"), mmap_mode="r" if mmap else None)

    def sub_frames(self):
        return self.cfg["frames"] - int(self.cfg.get("smooth_k", 1)) + 1


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


PREPARED = ("bn_train", "hi_train", "en_train", "val_bn", "eval_bn", "eval_tv_src", "eval_en",
            "musan_train", "musan_val", "musan_eval", "mspeech_train", "mspeech_val",
            "mspeech_eval", "rir_train", "rir_val", "rir_eval")


def stage_prepare(c: Ctx):
    pd = c.p("prepared")
    rp = os.path.join(pd, "report.json")
    if c.cfg["tiny"]:
        r = np.random.default_rng(0)

        def noise(sec):
            x = r.standard_normal(int(sec * audio.SR)).astype(np.float32)
            x = np.cumsum(x) * 0.02  # brown-ish
            x -= np.convolve(x, np.ones(400) / 400, mode="same")
            return (np.clip(x / (np.abs(x).max() + 1e-9) * 0.3, -1, 1) * 32767).astype(np.int16)
        for name, sec in (("bn_train", 60), ("hi_train", 20), ("en_train", 20), ("val_bn", 40),
                          ("eval_bn", 60), ("eval_tv_src", 40), ("eval_en", 20),
                          ("musan_train", 40), ("musan_val", 20), ("musan_eval", 20),
                          ("mspeech_train", 30), ("mspeech_val", 20), ("mspeech_eval", 20)):
            np.save(os.path.join(pd, name + ".npy"), noise(sec))
        g = np.random.default_rng(1)
        for part in ("train", "val", "eval"):
            hs = [audio.synthetic_rir(g) for _ in range(4)]
            np.save(os.path.join(pd, f"rir_{part}.npy"),
                    np.stack([np.pad(h, (0, max(0, 4000 - len(h))))[:4000] for h in hs]).astype(np.float16))
        _wj({"tiny": True}, rp)
        return
    if os.path.exists(rp) and not _rj(rp).get("tiny") and all(
            os.path.exists(os.path.join(pd, n + ".npy")) for n in PREPARED):
        log("prepare: already done —", _rj(rp))
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

    def drop(key):
        f = os.path.join(dl, os.path.basename(datasets.SOURCES[key]["url"]))
        if os.path.exists(f):
            os.remove(f)

    if not os.path.exists(os.path.join(pd, "mspeech_eval.npy")):
        rep["musan"] = datasets.musan_split(get("musan"), pd, max_files=d["musan_files"],
                                            speech_files=d["musan_speech_files"])
        log("musan:", rep["musan"])
        drop("musan")  # 11 GB: keep only the prepared subset
    if not os.path.exists(os.path.join(pd, "rir_eval.npy")):
        rep["sim_rir"] = datasets.rir_bank(get("sim_rir"), pd)
        log("sim_rir:", rep["sim_rir"])
        drop("sim_rir")
    save("bn_train", datasets.archive_to_stream(get("fleurs_bn"), d["fleurs_bn_hours"], seed=1))
    drop("fleurs_bn")
    save("hi_train", datasets.archive_to_stream(get("fleurs_hi"), d["fleurs_hi_hours"], seed=11))
    drop("fleurs_hi")
    save("en_train", datasets.archive_to_stream(get("librispeech_dev"), d["librispeech_hours"], seed=2))
    drop("librispeech_dev")
    save("val_bn", datasets.archive_to_stream(get("fleurs_bn_dev"), d["fleurs_bn_dev_hours"], seed=4))
    save("eval_bn", datasets.archive_to_stream(get("slr53_bn"), d["eval_bn_hours"], seed=5))
    drop("slr53_bn")
    save("eval_tv_src", datasets.archive_to_stream(get("slr53_bn_1"), d["eval_tv_hours"], seed=6))
    drop("slr53_bn_1")
    save("eval_en", datasets.archive_to_stream(get("librispeech_test"), d["librispeech_test_hours"], seed=7))
    for part in ("train", "val", "eval"):
        for tag in ("musan", "mspeech"):
            rep[f"{tag}_{part}"] = round(len(c.prep(f"{tag}_{part}")) / audio.SR / 3600, 3)
    _wj(rep, rp)


def _clips(c: Ctx, sub, base=None):
    d = os.path.join(base, sub) if base else c.p("clips", sub)
    return [audio.read_audio(f) for f in sorted(glob.glob(os.path.join(d, "*.wav")))]


def _hours(n_samples):
    return n_samples / audio.SR / 3600


# ---- real recordings (owner_actions/WAKEWORD_RECORDING_BN.md) ------------------

def real_clip_index(root: str, test_frac: float) -> dict:
    """root/pos/<speaker>/<condition>/*.wav and root/neg/<speaker>/*.wav.
    Speakers are split train/test by a stable hash (never by clip)."""
    out = {"train_pos": [], "test_pos": {}, "train_neg": [], "test_neg": [], "speakers": {}}
    if not root or not os.path.isdir(root):
        return out
    for kind in ("pos", "neg"):
        for spk in sorted(os.listdir(os.path.join(root, kind))) if os.path.isdir(os.path.join(root, kind)) else []:
            test = (zlib.crc32(spk.encode()) % 1000) < int(test_frac * 1000)
            out["speakers"][spk] = "test" if test else "train"
            for f in sorted(glob.glob(os.path.join(root, kind, spk, "**", "*.wav"), recursive=True)):
                cond = os.path.relpath(os.path.dirname(f), os.path.join(root, kind, spk)).split(os.sep)[0]
                if kind == "pos":
                    if test:
                        out["test_pos"].setdefault(cond if cond != "." else "all", []).append(f)
                    else:
                        out["train_pos"].append(f)
                else:
                    (out["test_neg"] if test else out["train_neg"]).append(f)
    return out


def stage_embed(c: Ctx):
    ed = c.p("emb")
    info_p = os.path.join(ed, "info.json")
    key = embed_key(c.cfg)
    spec = c.spec()
    fr = c.cfg["frames"]
    sw = c.spec_window()
    seed = int(c.cfg["seed"])
    rounds, nrounds = c.cfg["augment_rounds"], c.cfg["neg_augment_rounds"]
    if os.path.exists(info_p) and _rj(info_p).get("key") == key:
        log("embed: cached embeddings match key", key)
        info = _rj(info_p)
    else:
        info = {"key": key, "hours": {}, "counts": {}}
        t0 = time.time()
        rir_tr, rir_va, rir_ev = c.prep("rir_train", False), c.prep("rir_val", False), c.prep("rir_eval", False)
        mus = {p: c.prep(f"musan_{p}", False) for p in ("train", "val", "eval")}
        msp = {p: c.prep(f"mspeech_{p}", False) for p in ("train", "val", "eval")}
        d = c.cfg["data"]

        def stream(name, arr, dtype):
            e, _ = embed.stream_embeddings(spec, np.asarray(arr), dtype=dtype)
            np.save(os.path.join(ed, name + ".npy"), e)
            info["hours"][name] = round(_hours(len(arr)), 3)
            info["counts"][name] = int(len(e))
            log(f"embed {name}: {info['hours'][name]} h -> {len(e)} frames ({time.time() - t0:.0f}s)")

        # -- training negatives (float16) ----------------------------------------
        bn = c.prep("bn_train", False)
        hi = c.prep("hi_train", False)
        tv_en_cap = int(d.get("tv_en_train_hours", 4.0) * 3600 * audio.SR)
        streams = {
            "s_bn": bn, "s_hi": hi, "s_en": c.prep("en_train", False), "s_mspeech": msp["train"],
            "s_musan": np.asarray(mus["train"][: int(d.get("musan_train_stream_hours", 6.0) * 3600 * audio.SR)]),
            "s_tv_bn": datasets.tv_like_mix(bn, mus["train"], seed=31, rirs=rir_tr),
            "s_tv_hi": datasets.tv_like_mix(hi, mus["train"], seed=32, rirs=rir_tr),
            "s_tv_en": datasets.tv_like_mix(np.asarray(msp["train"][:tv_en_cap]), mus["train"],
                                            seed=33, rirs=rir_tr),
        }
        for name, arr in streams.items():
            stream(name, arr, np.float16)
        del streams
        info["train_streams"] = ["s_bn", "s_hi", "s_en", "s_mspeech", "s_musan", "s_tv_bn",
                                 "s_tv_hi", "s_tv_en"]
        noise_tr = [mus["train"], msp["train"]]  # music/noise OR TV-like speech underneath
        aug_tr = dict(dist=(0.3, 3.0), snr=(0.0, 20.0), p_rir=0.8, p_real_rir=0.5, p_band=0.15)
        pos = embed.clip_windows(spec, _clips(c, "pos_train"), noise_tr, fr, seed * 10 + 1,
                                 rounds=rounds, rirs=rir_tr, background=[mus["train"]],
                                 spec_window=sw, **aug_tr)
        np.save(os.path.join(ed, "pos_train.npy"), pos)
        negc = embed.clip_windows(spec, _clips(c, "neg_train"), noise_tr, fr, seed * 10 + 2,
                                  rounds=nrounds, rirs=rir_tr, background=[mus["train"]],
                                  spec_window=sw, **aug_tr)
        np.save(os.path.join(ed, "neg_clips.npy"), negc)
        info["counts"].update({"pos_train": len(pos), "neg_clips": len(negc)})
        log(f"embed clips: pos={len(pos)} neg={len(negc)} ({time.time() - t0:.0f}s)")

        # -- validation (float32) -------------------------------------------------
        pos_test = _clips(c, "pos_test")
        aug_va = dict(dist=(1.0, 2.0), snr=(5.0, 15.0), p_rir=1.0, p_real_rir=0.0)
        pv = embed.clip_windows(spec, pos_test[::2], [mus["val"], msp["val"]], fr, seed * 10 + 3,
                                rounds=1, rirs=rir_va, background=[mus["val"]], dtype=np.float32,
                                spec_window=sw, **aug_va)
        np.save(os.path.join(ed, "pos_val.npy"), pv)
        val_bn = c.prep("val_bn", False)
        vals = {"v_bn": val_bn,
                "v_tv_bn": datasets.tv_like_mix(val_bn, mus["val"], seed=41, rirs=rir_va),
                "v_tv_en": datasets.tv_like_mix(msp["val"], mus["val"], seed=42, rirs=rir_va),
                "v_tts": datasets.clips_stream(_clips(c, "neg_test"), seed=43)}
        for name, arr in vals.items():
            stream(name, arr, np.float32)
        info["val_streams"] = list(vals)

        # -- test sets (float32) — never used for any choice ----------------------
        eb = c.prep("eval_bn", False)
        tests = {"eval_bn": eb,
                 "eval_tv": datasets.tv_like_mix(c.prep("eval_tv_src", False), mus["eval"], seed=51,
                                                 rirs=rir_ev),
                 "eval_en": c.prep("eval_en", False),
                 "eval_tv_en": datasets.tv_like_mix(msp["eval"], mus["eval"], seed=52, rirs=rir_ev)}
        for name, arr in tests.items():
            stream(name, arr, np.float32)
        info["test_streams"] = list(tests)
        test = pos_test[1::2]
        bg = np.asarray(eb[: 3600 * audio.SR])
        frr_sets = {
            # same definitions as ww2 (comparable numbers)
            "synthetic_far_field_1_2m": dict(noise=mus["eval"], aug=dict(dist=(1.0, 2.0), snr=(5.0, 15.0),
                                                                          p_rir=1.0)),
            "synthetic_near_0_3_0_8m": dict(noise=mus["eval"], aug=dict(dist=(0.3, 0.8), snr=(15.0, 30.0),
                                                                         p_rir=1.0)),
            # new: simulated-room bank (eval rooms) + TV-like speech or music underneath
            "sim_room_tv_on_5_15db": dict(noise=[mus["eval"], msp["eval"]],
                                          aug=dict(snr=(5.0, 15.0), p_rir=1.0, p_real_rir=1.0)),
        }
        for k, (name, fs) in enumerate(frr_sets.items()):
            r = embed.frr_clips(spec, test, seed * 10 + 5 + k, noise=fs["noise"], rirs=rir_ev,
                                aug=fs["aug"], background=bg)
            np.savez(os.path.join(ed, f"frr_{name}.npz"), **r)
            info["counts"]["frr_" + name] = int(len(r["offsets"]) - 1)
        info["frr_sets"] = list(frr_sets)
        # small audio kept WITH the cached embeddings so real-clip ingestion works on a cache hit
        np.save(os.path.join(ed, "aux_noise.npy"), np.asarray(mus["train"][: 1800 * audio.SR]))
        np.save(os.path.join(ed, "aux_rir.npy"), rir_tr)
        np.save(os.path.join(ed, "aux_bg.npy"), np.asarray(eb[: 600 * audio.SR]))
        info["seconds"] = round(time.time() - t0)
        _wj(info, info_p)
        log(f"embed done in {info['seconds']}s")
    # -- real recordings: never cached, never uploaded ----------------------------
    rc = c.cfg.get("real_clips") or {}
    idx = real_clip_index(rc.get("dir", ""), float(rc.get("test_speaker_frac", 0.3)))
    rd = c.p("emb_real")
    rinfo = {"speakers": idx["speakers"], "frr_sets": [], "neg_hours": 0.0}
    if idx["speakers"]:
        mus_tr, rir_tr = _emb(c, "aux_noise"), _emb(c, "aux_rir")
        load = lambda fs: [audio.read_audio(f) for f in fs]  # noqa: E731
        aug_tr = dict(dist=(0.3, 2.0), snr=(5.0, 25.0), p_rir=0.3, p_real_rir=0.5)
        if idx["train_pos"]:
            np.save(os.path.join(rd, "pos_real.npy"), embed.clip_windows(
                spec, load(idx["train_pos"]), [mus_tr], fr, seed * 10 + 7, rounds=3, rirs=rir_tr,
                spec_window=sw, **aug_tr))
        if idx["train_neg"]:
            np.save(os.path.join(rd, "neg_real.npy"), embed.stream_embeddings(
                spec, datasets.clips_stream(load(idx["train_neg"]), seed=8), dtype=np.float16)[0])
        bg = _emb(c, "aux_bg")
        for cond, fs in sorted(idx["test_pos"].items()):
            r = embed.frr_clips(spec, load(fs), seed * 10 + 9, aug=None, background=np.asarray(bg))
            np.savez(os.path.join(rd, f"frr_real_{cond}.npz"), **r)
            rinfo["frr_sets"].append(f"real_{cond}")
        if idx["test_neg"]:
            s = datasets.clips_stream(load(idx["test_neg"]), seed=10, gap_s=(0.2, 0.5))
            np.save(os.path.join(rd, "t_real_neg.npy"), embed.stream_embeddings(spec, s)[0])
            rinfo["neg_hours"] = round(_hours(len(s)), 3)
        log("real clips:", {k: (len(v) if isinstance(v, (list, dict)) else v) for k, v in idx.items()})
    _wj(rinfo, os.path.join(rd, "info.json"))


def _emb(c: Ctx, name, mmap=False):
    return np.load(c.p("emb", name + ".npy"), mmap_mode="r" if mmap else None)


def _real(c: Ctx, name):
    p = c.p("emb_real", name)
    return np.load(p) if os.path.exists(p) else None


class Val:
    """Validation data + the checkpoint-selection metric: positive recall at the
    lowest logit whose validation false accepts/hour <= target (patience 1)."""

    def __init__(self, c: Ctx):
        info = _rj(c.p("emb", "info.json"))
        self.streams = {n: _emb(c, n) for n in info["val_streams"]}
        self.hours = sum(info["hours"][n] for n in info["val_streams"])
        self.pos = _emb(c, "pos_val").astype(np.float32)
        self.frames = c.cfg["frames"]
        self.target = c.cfg["thresholds"]["target_fa_per_hour"]

    def logits(self, scorer: Scorer, cache=None):
        return [scorer.stream_logits(e, cache, ("val", n)) for n, e in self.streams.items()], \
            scorer.window_logits(self.pos)

    def __call__(self, net: WakeNet) -> dict:
        sc = Scorer([net], self.frames)
        vl, pl = self.logits(sc)
        limit = self.target * self.hours
        allv = np.concatenate(vl)
        lo, hi = float(np.quantile(allv, 0.995)), float(allv.max()) + 0.01
        if evaluate_count(vl, lo) <= limit:
            hi = lo
        for _ in range(30):  # bisection on the (near-monotone) FA count
            mid = 0.5 * (lo + hi)
            if evaluate_count(vl, mid) <= limit:
                hi = mid
            else:
                lo = mid
        rec = float((pl >= hi).mean()) if len(pl) else 0.0
        return {"val_L_at_target": round(hi, 3), "val_recall_at_target": round(rec, 4),
                "val_max_neg_logit": round(float(allv.max()), 3), "select": rec}


def evaluate_count(val_logits, L):
    return sum(evaluate.count_fast(v, L, 1) for v in val_logits)


def stage_train(c: Ctx):
    info = _rj(c.p("emb", "info.json"))
    sub = c.sub_frames()
    pos_sets = [_emb(c, "pos_train")]
    neg_sets = [_emb(c, "neg_clips")]
    for nm, lst in (("pos_real.npy", pos_sets),):
        r = _real(c, nm)
        if r is not None:
            lst.append(r)
    streams = [_emb(c, n) for n in info["train_streams"]]
    r = _real(c, "neg_real.npy")
    if r is not None:
        streams.append(r)
    pos = FramePool.from_parts(pos_sets, [], sub)
    neg = FramePool.from_parts(neg_sets, streams, sub)
    del streams
    log(f"train pools: pos windows={len(pos)} neg windows={len(neg)} (sub-window {sub} frames)")
    val = Val(c)
    hists = {}
    for s in c.cfg["seeds"]:
        t0 = time.time()
        net = WakeNet(sub, 96, c.cfg["hidden"], seed=int(s))
        tc = dict(c.cfg["train"], seed=int(s))
        h = train(net, pos, neg, tc, val_fn=val, log=lambda row, s=s: log(f"seed {s}", row))
        h["seconds"] = round(time.time() - t0)
        net.save_npz(c.p("model", f"net_seed{s}.npz"))
        hists[str(s)] = h
        log(f"seed {s}: chosen step {h['chosen_step']} in {h['seconds']}s")
    _wj(hists, c.p("model", "train_history.json"))


def _candidates(c: Ctx):
    fr = c.cfg["frames"]
    members = {str(s): WakeNet.load_npz(c.p("model", f"net_seed{s}.npz")) for s in c.cfg["seeds"]}
    cands = {f"seed_{s}": Scorer([m], fr) for s, m in members.items()}
    if c.cfg.get("ensemble") and len(members) > 1:
        cands["ensemble"] = Scorer(list(members.values()), fr)
    return cands


def evaluate_candidate(c: Ctx, sc: Scorer, val: Val, tests: dict, test_hours: dict, frr: dict,
                       cache: dict, real: dict) -> dict:
    tcfg = c.cfg["thresholds"]
    vl, pl = val.logits(sc, cache)
    pick = evaluate.pick_thresholds_logit(vl, val.hours, pl, tcfg["target_fa_per_hour"],
                                          tcfg["low_offset"], tcfg["high_mult"], margin=tcfg["margin"])
    L = pick["logits"]
    sc.T = evaluate.temperature_for(L["normal"], tcfg["temperature_target"])
    th = evaluate.thresholds_from_logits(L, sc.T)
    rep = {"thresholds": th, "threshold_logits": {k: round(v, 4) for k, v in L.items()},
           "temperature": round(sc.T, 6), "validation_hours": round(val.hours, 3),
           "false_accepts": {}, "false_rejects": {}}
    vs = [sc.to_score(v) for v in vl]
    rep["validation"] = {"false_accepts": evaluate.false_accepts(vs, th, val.hours),
                         "recall_far_field_windows": {
                             lv: round(float((sc.to_score(pl) >= th[lv]).mean()), 4) for lv in LEVELS}}
    fa_examples = {}
    for name, e in tests.items():
        s = sc.to_score(sc.stream_logits(e, cache, ("test", name)))
        rep["false_accepts"][name] = evaluate.false_accepts(s, th, test_hours[name])
        fa_examples[name] = [round((f + c.cfg["frames"]) * HOP / audio.SR, 1)  # approx. seconds
                             for f in evaluate.fire_frames(s, th["normal"], 1)][:20]
    rep["fa_times_s_normal"] = fa_examples  # diagnostics only (seconds into the test stream)
    for name, d in frr.items():
        rep["false_rejects"][name] = evaluate.false_rejects(sc, d, th, c.cfg["frames"])
    for name, d in real.get("frr", {}).items():
        rep["false_rejects"][name] = evaluate.false_rejects(sc, d, th, c.cfg["frames"])
    if real.get("neg") is not None:
        s = sc.to_score(sc.stream_logits(real["neg"]))
        rep["false_accepts"]["real_test_speakers"] = evaluate.false_accepts(s, th, real["neg_hours"])
    rep["validation_curve"] = [r for r in pick["curve"] if r["fa"] <= 50][::4]
    return rep


def _targets(c: Ctx, rep: dict) -> dict:
    fa = rep["false_accepts"]
    lim = c.cfg["target_fa_per_10h"]
    tot_h = sum(fa[n]["normal"]["hours"] for n in ("eval_bn", "eval_tv", "eval_en", "eval_tv_en") if n in fa)
    bn = fa["eval_bn"]["normal"]["per_10h"]
    tv = fa["eval_tv"]["normal"]["per_10h"]
    fr = rep["false_rejects"]["synthetic_far_field_1_2m"]["normal"]["false_reject_rate"]
    return {
        "false_accepts_per_10h_lt": lim, "false_reject_lt": c.cfg["target_fr"],
        "test_negative_hours": round(tot_h, 2), "min_test_hours": c.cfg["min_test_hours"],
        "met_normal_bangla_fa": bn is not None and bn < lim,
        "met_normal_tv_fa": tv is not None and tv < lim,
        "met_normal_fr_far_field": fr is not None and fr < c.cfg["target_fr"],
        "met_test_hours": tot_h >= c.cfg["min_test_hours"],
        "note": "False rejects are measured on SYNTHETIC far-field speech; confirm on a real phone "
                "(owner_actions/PHONE_TEST_CHECKLIST.md, owner_actions/WAKEWORD_RECORDING_BN.md). "
                "0 false accepts in 10 h still allows a true rate up to ~3 per 10 h (95% bound).",
    }


def stage_evaluate(c: Ctx):
    info = _rj(c.p("emb", "info.json"))
    val = Val(c)
    tests = {n: _emb(c, n) for n in info["test_streams"]}
    test_hours = {n: info["hours"][n] for n in info["test_streams"]}
    frr = {}
    for n in info["frr_sets"]:
        z = np.load(c.p("emb", f"frr_{n}.npz"))
        frr[n] = {k: z[k] for k in z.files}
    rinfo = _rj(c.p("emb_real", "info.json")) if os.path.exists(c.p("emb_real", "info.json")) else {}
    real = {"frr": {}, "neg": _real(c, "t_real_neg.npy"), "neg_hours": rinfo.get("neg_hours", 0.0)}
    for n in rinfo.get("frr_sets", []):
        z = np.load(c.p("emb_real", f"frr_{n}.npz"))
        real["frr"][n] = {k: z[k] for k in z.files}
    cache: dict = {}
    reps = {}
    for name, sc in _candidates(c).items():
        t0 = time.time()
        reps[name] = evaluate_candidate(c, sc, val, tests, test_hours, frr, cache, real)
        reps[name]["targets"] = _targets(c, reps[name])
        sc.save_npz(c.p("model", f"scorer_{name}.npz"))
        log(f"evaluated {name} in {time.time() - t0:.0f}s: th={reps[name]['thresholds']} "
            f"FA/10h normal={ {k: v['normal']['per_10h'] for k, v in reps[name]['false_accepts'].items()} } "
            f"FRR far={reps[name]['false_rejects']['synthetic_far_field_1_2m']['normal']['false_reject_rate']}")
    # ship candidate chosen on VALIDATION only: best far-field window recall at Normal
    def vkey(n):
        r = reps[n]["validation"]
        return (r["recall_far_field_windows"]["normal"], -r["false_accepts"]["normal"]["false_accepts"],
                n == "ensemble")
    chosen = max(reps, key=vkey)
    seeds_summary = _seed_summary(reps)
    report = dict(reps[chosen])
    report.update({"chosen": chosen, "chosen_by": "validation far-field recall at Normal",
                   "candidates": {n: {k: reps[n][k] for k in ("thresholds", "temperature",
                                                                 "false_accepts", "false_rejects",
                                                                 "validation", "targets")}
                                  for n in reps},
                   "seed_variance": seeds_summary, "patience": PATIENCE, "cooldown_ms": COOLDOWN_MS,
                   "smooth_k": c.cfg.get("smooth_k", 1), "embed_info": info,
                   "real_clip_speakers": len(rinfo.get("speakers", {}))})
    _wj(report, c.p("model", "eval_report.json"))
    log("chosen candidate:", chosen)


def _seed_summary(reps: dict) -> dict:
    seeds = [n for n in reps if n.startswith("seed_")]
    out = {}
    if not seeds:
        return out
    for lv in LEVELS:
        row = {}
        for st in reps[seeds[0]]["false_accepts"]:
            v = [reps[s]["false_accepts"][st][lv]["per_10h"] for s in seeds]
            row["fa_per_10h_" + st] = {"mean": round(float(np.mean(v)), 3), "sd": round(float(np.std(v)), 3),
                                       "min": min(v), "max": max(v)}
        for st in reps[seeds[0]]["false_rejects"]:
            v = [reps[s]["false_rejects"][st][lv]["false_reject_rate"] for s in seeds]
            row["frr_" + st] = {"mean": round(float(np.mean(v)), 4), "sd": round(float(np.std(v)), 4),
                                "min": min(v), "max": max(v)}
        out[lv] = row
    return out


def _fa_table(rep, title):
    L = [f"### {title}", "", "| test set | hours | level | false accepts | per 10 h | 95% upper / 10 h |",
         "|---|---|---|---|---|---|"]
    for name, by in rep["false_accepts"].items():
        for lv in LEVELS:
            r = by[lv]
            L.append(f"| {name} | {r['hours']} | {lv} | {r['false_accepts']} | {r['per_10h']} | "
                     f"{r.get('per_10h_upper95')} |")
    L += ["", "| false-reject set | level | clips | detected | FRR |", "|---|---|---|---|---|"]
    for name, by in rep["false_rejects"].items():
        for lv in LEVELS:
            r = by[lv]
            L.append(f"| {name} | {lv} | {r['clips']} | {r['detected']} | {r['false_reject_rate']} |")
    return L


def _report_md(rep: dict, cfg: dict) -> str:
    L = ["# Hey Assisto — evaluation report", "",
         f"Generated {_dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} by tools/wakeword/pipeline.py"
         + (" (TINY SMOKE RUN — numbers are meaningless)" if cfg["tiny"] else ""), "",
         f"Shipped candidate: **{rep['chosen']}** (chosen by {rep['chosen_by']}). Thresholds "
         f"(validation only, {rep['validation_hours']} h): {rep['thresholds']} = logits "
         f"{rep['threshold_logits']} / T {rep['temperature']}; app patience {rep['patience']}; in-graph "
         f"smoothing k={rep['smooth_k']} frames; cooldown {rep['cooldown_ms']} ms.", ""]
    t = rep["targets"]
    L += ["## Targets (shipped candidate, Normal)", "",
          f"- Plain Bangla (eval_bn) < {t['false_accepts_per_10h_lt']} FA / 10 h -> {'MET' if t['met_normal_bangla_fa'] else 'NOT MET'}",
          f"- TV-like Bangla + music (eval_tv) < {t['false_accepts_per_10h_lt']} FA / 10 h -> {'MET' if t['met_normal_tv_fa'] else 'NOT MET'}",
          f"- Far-field 1-2 m (synthetic) FRR < {int(cfg['target_fr'] * 100)}% -> {'MET' if t['met_normal_fr_far_field'] else 'NOT MET'}",
          f"- Test negative hours {t['test_negative_hours']} >= {t['min_test_hours']} -> {'MET' if t['met_test_hours'] else 'NOT MET'}",
          f"- {t['note']}", ""]
    L += _fa_table(rep, f"Shipped candidate: {rep['chosen']}")
    L += ["", "## Every candidate (Normal level)", "",
          "| candidate | thresholds | " + " | ".join(f"{n} FA/10h" for n in rep["false_accepts"])
          + " | " + " | ".join(f"FRR {n}" for n in rep["false_rejects"]) + " |",
          "|---|---|" + "---|" * (len(rep["false_accepts"]) + len(rep["false_rejects"]))]
    for n, r in rep["candidates"].items():
        L.append(f"| {n} | {r['thresholds']['normal']} | "
                 + " | ".join(str(r['false_accepts'][s]['normal']['per_10h']) for s in rep["false_accepts"])
                 + " | " + " | ".join(str(r['false_rejects'][s]['normal']['false_reject_rate'])
                                      for s in rep["false_rejects"]) + " |")
    L += ["", "## Seed variance (single-seed models; mean ± sd [min..max])", ""]
    for lv, row in rep["seed_variance"].items():
        L.append(f"- **{lv}**: " + "; ".join(f"{k} {v['mean']} ± {v['sd']} [{v['min']}..{v['max']}]"
                                            for k, v in row.items()))
    L += ["", "Embedding hours: `" + json.dumps(rep["embed_info"].get("hours", {})) + "`"]
    return "\n".join(L) + "\n"


def stage_package(c: Ctx):
    out = c.p("out")
    spec = c.spec()
    rep = _rj(c.p("model", "eval_report.json"))
    sc = Scorer.load_npz(c.p("model", f"scorer_{rep['chosen']}.npz"))
    wake = c.p("model", "assisto_wake.onnx")
    sc.to_onnx(wake)
    # the exported graph must reproduce the evaluated scores
    import onnxruntime as ort
    sess = ort.InferenceSession(wake, providers=["CPUExecutionProvider"])
    x = _emb(c, "pos_val").astype(np.float32)[:256]
    if len(x):
        got = sess.run(None, {"input": x})[0][:, 0]
        one = sess.run(None, {"input": x[:1]})[0]
        rep["onnx_check"] = {"max_abs_diff_vs_numpy": float(np.max(np.abs(got - sc.predict(x)))),
                             "batch1_shape": list(one.shape), "ort": ort.__version__}
        log("onnx check:", rep["onnx_check"])
        if rep["onnx_check"]["max_abs_diff_vs_numpy"] > 1e-4:
            raise SystemExit("exported classifier does not match the evaluated one")
    files = [("wake", wake, "assisto_wake.onnx")]
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
    tg = rep["targets"]
    manifest = {
        "version": _dt.datetime.now(_dt.timezone.utc).strftime("%Y.%m.%d.%H%M"), "engine": "openwakeword",
        "feature_backend": spec.backend, "window_samples": spec.window_samples, "hop_samples": HOP,
        "frames": c.cfg["frames"], "files": entries, "thresholds": rep["thresholds"],
        "patience": PATIENCE, "cooldown_ms": COOLDOWN_MS,
        "classifier": {"candidate": rep["chosen"], "members": len(sc.members), "smooth_k": sc.k,
                       "temperature": sc.T},
        "licence_cleared": cleared,
        # licence AND the measured test targets. Integrators: do not copy a build with
        # ship_ready=false into backend/core/wakeword_models/.
        "ship_ready": bool(cleared and tg["met_normal_bangla_fa"] and tg["met_normal_tv_fa"]
                           and tg["met_normal_fr_far_field"] and tg["met_test_hours"]),
        "licence_notes": {"features": feat_note, "piper_used": bool(t.get("piper")),
                          "tiny_smoke": bool(c.cfg["tiny"]),
                          "real_recordings_speakers": rep.get("real_clip_speakers", 0)},
        "eval": {"false_accepts": rep["false_accepts"], "false_rejects": rep["false_rejects"],
                 "targets": tg},
    }
    _wj(manifest, os.path.join(out, "manifest.json"))
    _wj(rep, os.path.join(out, "eval_report.json"))
    _wt(os.path.join(out, "eval_report.md"), _report_md(rep, c.cfg))
    _wj({"datasets": datasets.SOURCES, "tts": t, "features": feat_note},
        os.path.join(out, "licences.json"))
    card = _rt(os.path.join(HERE, "MODEL_CARD.md"))
    _wt(os.path.join(out, "MODEL_CARD.md"),
        card + "\n\n---\n\n## This build\n\n```json\n" + json.dumps(
            {k: manifest[k] for k in ("version", "feature_backend", "thresholds", "classifier",
                                      "licence_cleared", "ship_ready", "licence_notes")},
            indent=1) + "\n```\n")
    log("packaged ->", out, "licence_cleared=", cleared, "ship_ready=", manifest["ship_ready"])


STAGES = {"features": stage_features, "synth": stage_synth, "prepare": stage_prepare,
          "embed": stage_embed, "train": stage_train, "evaluate": stage_evaluate,
          "package": stage_package}
ALIASES = {"windows": "embed"}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--config", default="")
    ap.add_argument("--tiny", action="store_true")
    ap.add_argument("stages", nargs="+", help="|".join(STAGES) + "|all|embed_key")
    a = ap.parse_args(argv)
    cfg = json.loads(json.dumps(DEFAULTS))
    if a.config:
        deep_update(cfg, _rj(a.config))
    if a.tiny:
        deep_update(cfg, TINY)
    if a.stages == ["embed_key"]:
        print(embed_key(cfg))
        return
    c = Ctx(a.work, cfg)
    _wj(cfg, c.p("config.used.json"))
    names = list(STAGES) if a.stages == ["all"] else [ALIASES.get(n, n) for n in a.stages]
    for n in names:
        t0 = time.time()
        log("stage", n)
        STAGES[n](c)
        log(f"stage {n} done in {time.time() - t0:.0f}s")


if __name__ == "__main__":
    main()
