#!/usr/bin/env python3
"""d1-photo v2: the 50-photo proof run (owner order 6 §5) — OUR v2 pipeline
on 50 licence-clean photos, with an IDENTITY score, sharpness and (where a
clean original exists) PSNR/SSIM, plus the empty Remini column the owner
fills (see owner_actions/PHOTO_COMPARE_BN.md; then `manage.py
photo_ab_import <out> <remini>` loads the blind A/B vote in Owner Admin).

Set: tools/photo_eval/fetch_50.py -> sources_50.json (each file's Commons
page + licence; only Public domain / CC0).

  kind            damage (synthetic, known clean original)   pipeline (v2)
  portrait 01-05  ½ size + soft blur + JPEG q55                server HD ENHANCE (+ FACE LOCK)
  old 06-08,11,12 sepia, fade, scratches, dust, ½ size         server OLD-PHOTO RESTORE (+ FACE LOCK)
  blurry 09,10,13-15 Gaussian σ=2.2 + noise                    server HD ENHANCE (+ FACE LOCK)
  low light 16-20 + 4 CC0  gamma 2.0 × 0.45 + noise + JPEG     on-device LOW-LIGHT tool
  dark skin ×12   even: ½ size + JPEG / odd: low light         HD ENHANCE / LOW-LIGHT (+ FACE LOCK)
  group ×6        ½ size + JPEG                                server HD ENHANCE (+ FACE LOCK)
  old (REAL) ×8   none — real 1910s-1940s prints               server OLD-PHOTO RESTORE (+ FACE LOCK)

Identity = AuraFace cosine (Apache-2.0) between each CLEAN-original face and
the same face in the output (worst face); 1.0 = identical embedding, a
different person scores < ~0.35 on this set.

  python3 tools/photo_eval/run_eval_v2.py --src <dir with sources_50.json> --out <dir> \
     --ps-eval <compiled app/tool/ps_eval.dart> --upscale <realesr.onnx> --colorize <ddcolor.onnx> \
     --yunet <yunet.onnx> --auraface <auraface_glintr100.onnx> [--remini <folder>]
"""
import argparse
import importlib.util
import json
import os
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


E = _load("run_eval_v1", os.path.join(HERE, "run_eval.py"))
R = E.R
F = _load("facelock_eval", os.path.join(ROOT, "backend", "core", "photo_facelock.py"))

KIND_OF = {"01": "portrait", "02": "portrait", "03": "portrait", "04": "portrait", "05": "portrait",
           "06": "old", "07": "old", "08": "old", "11": "old", "12": "old",
           "09": "blurry", "10": "blurry", "13": "blurry", "14": "blurry", "15": "blurry",
           "16": "low_light", "17": "low_light", "18": "low_light", "19": "low_light", "20": "low_light"}


def kind_of(row, idx):
    n = row["file"][:2]
    if n in KIND_OF:
        return KIND_OF[n]
    k = row["kind"]
    if k == "low_light_cc0":
        return "low_light"
    return k


def identity(clean, out, a):
    """Worst AuraFace cosine over the clean image's faces (None = no face)."""
    try:
        fc = F.detect(clean, a.yunet)
    except F.FaceLockUnavailable:
        return None
    if not fc:
        return None
    fo = F.detect(out, a.yunet, min_score=0.6)
    sx, sy = out.shape[1] / clean.shape[1], out.shape[0] / clean.shape[0]
    worst = 1.0
    for f in fc:
        m = F._match(f, fo, sx, sy)
        if m is None:
            return 0.0
        worst = min(worst, F.similarity(F.embed(clean, f, a.auraface), F.embed(out, m, a.auraface)))
    return round(worst, 3)


def pipeline(kind, dmg, a, sess, work, seed):
    t = time.perf_counter()
    info = {}
    if kind in ("portrait", "blurry", "group") or (kind == "dark_skin" and seed % 2 == 0):
        faces = F.detect(dmg, a.yunet)
        out, info = R.enhance_rgb(dmg, sess["up"], faces, "free")
        out, rep = F.face_lock(dmg, out, a.yunet, faces, embed_path=a.auraface)
        info = {"path": "server_hd", "tiles": info.get("tiles"), "face_lock": rep["action"],
                "restored": rep["restored"]}
    elif kind in ("old", "old_real"):
        out, info = R.old_restore_rgb(dmg, colorize=True, faces=E.faces(dmg),
                                      up_sess=sess["up"], color_sess=sess["dd"])
        out, rep = F.face_lock(dmg, out, a.yunet,
                               embed_path=a.auraface)
        info = {"path": "server_old", "colorized": info["colorized"], "face_lock": rep["action"],
                "restored": rep["restored"]}
    else:   # low light (incl. dark skin odd)
        out, ms = E.ps_eval(a.ps_eval, dmg, "lowlight", E.faces(dmg), work)
        info = {"path": "phone_lowlight", "classic_ms": ms}
    info["ms"] = round((time.perf_counter() - t) * 1000)
    return out, info


def main():
    ap = argparse.ArgumentParser()
    for k in ("src", "out", "ps-eval", "upscale", "colorize", "yunet", "auraface"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--remini", default="")
    a = ap.parse_args()
    rows = json.load(open(os.path.join(a.src, "sources_50.json")))
    for d in ("inputs", "assisto"):
        os.makedirs(os.path.join(a.out, d), exist_ok=True)
    work = os.path.join(a.out, "_work")
    os.makedirs(work, exist_ok=True)
    sess = {"up": R._lean_session(a.upscale), "dd": R._lean_session(a.colorize)}
    results, sheet_rows = [], []
    for idx, row in enumerate(rows):
        name = row["file"]
        p = os.path.join(a.src, name)
        if not os.path.exists(p):
            continue
        kind = kind_of(row, idx)
        clean = R._fit(E.f32(Image.open(p)), E.LONG)
        h, w = clean.shape[:2]
        seed = int(name[:2])
        if kind == "old_real":
            dmg = clean
        elif kind == "dark_skin":
            dmg = E.damage(clean, "portrait" if seed % 2 == 0 else "low_light", seed)
        elif kind == "group":
            dmg = E.damage(clean, "portrait", seed)
        else:
            dmg = E.damage(clean, kind, seed)
        E.u8(dmg).save(os.path.join(a.out, "inputs", name), quality=92)
        out, info = pipeline(kind, dmg, a, sess, work, seed)
        E.u8(out).save(os.path.join(a.out, "assisto", name), quality=92)
        ref = clean
        cmp = {"damaged": E.resize(dmg, w, h), "assisto": E.resize(out, w, h)}
        rem = None
        if a.remini and os.path.isdir(a.remini):
            hit = [x for x in os.listdir(a.remini) if x.split("_")[0] == name[:2]]
            if hit:
                rem = E.f32(Image.open(os.path.join(a.remini, hit[0])))
                cmp["remini"] = E.resize(rem, w, h)
        m = {}
        for k, v in cmp.items():
            m[k] = {"sharp": round(E.sharpness(v)), "identity": identity(ref, v, a)}
            if kind != "old_real":
                m[k].update(psnr=round(E.psnr(v, ref), 2), ssim=round(E.ssim(v, ref), 4))
        m["clean"] = {"sharp": round(E.sharpness(clean))}
        results.append({"photo": name, "kind": kind, "licence": row["licence"], "page": row.get("page", ""),
                        "metrics": m, "run": info})
        cap = lambda k: ("PSNR %.1f " % m[k]["psnr"] if "psnr" in m[k] else "") + (  # noqa: E731
            "ID %.2f" % m[k]["identity"] if m[k]["identity"] is not None else "")
        sheet_rows.append({"name": name, "cat": kind, "imgs": [clean, dmg, out, rem],
                           "caps": ["sharp %d" % m["clean"]["sharp"], cap("damaged"), cap("assisto"),
                                    cap("remini") if "remini" in m else ""]})
        print(name, kind, m["damaged"].get("psnr"), "->", m["assisto"].get("psnr"),
              "ID", m["assisto"]["identity"], info, flush=True)
    for i in range(0, len(sheet_rows), 5):
        E.sheet(sheet_rows[i:i + 5], os.path.join(a.out, "sheet50_%02d.jpg" % (i // 5 + 1)))
    summ = {}
    for kind in sorted({r["kind"] for r in results}):
        rs = [r for r in results if r["kind"] == kind]
        s = {"n": len(rs)}
        for k in ("damaged", "assisto", "remini"):
            vs = [r["metrics"][k] for r in rs if k in r["metrics"]]
            if not vs:
                continue
            s[k] = {}
            for q in ("psnr", "ssim", "sharp", "identity"):
                xs = [v[q] for v in vs if v.get(q) is not None]
                if xs:
                    s[k][q] = round(float(np.mean(xs)), 3)
            ids = [v["identity"] for v in vs if v.get("identity") is not None]
            if ids:
                s[k]["identity_min"] = round(min(ids), 3)
        s["clean_sharp"] = round(float(np.mean([r["metrics"]["clean"]["sharp"] for r in rs])))
        s["ms_mean"] = round(float(np.mean([r["run"]["ms"] for r in rs])))
        s["face_lock_restored"] = sum(1 for r in rs if r["run"].get("restored"))
        summ[kind] = s
    json.dump({"summary": summ, "photos": results}, open(os.path.join(a.out, "results50.json"), "w"),
              indent=1)
    print(json.dumps(summ, indent=1))


if __name__ == "__main__":
    main()
