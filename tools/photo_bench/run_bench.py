#!/usr/bin/env python3
"""photo-final BENCHMARK — the same portraits through every Photo Studio
enhance provider, side by side, with seconds, cost and an identity score.

Set (licence records: .phaseB/d1_eval/sources_50.json — Wikimedia Commons,
Public domain / CC0 only):
  01, 04 portrait · 21, 25, 29 dark skin · 33, 36 real old photos (1910s-40s)
  41, 44 group · 47 low light (CC0)
Cheap-phone / WhatsApp damage is simulated on the clean originals so the
"before" is realistic (½ size + soft blur + JPEG q55; low light = gamma 2 x
0.45 + noise); real old photos are used as they are.
--extra <file>  adds any photo as-is (e.g. the owner's own Photo Studio
upload — the integrator copies it from the server; never committed).

Providers:
  local_clean    our CPU pipeline WITHOUT Real-ESRGAN (Lanczos + unsharp +
                 look stage) = the server default while realesrgan_allowed is
                 off — FREE, always run. Downloads nothing.
  local_worker   the same pipeline WITH the installed Real-ESRGAN ONNX — only
                 with --realesrgan (weights licence grey; owner decision).
  replicate      only with --paid --realesrgan and env REPLICATE_API_TOKEN +
                 REPLICATE_ESRGAN_VERSION — costs money. GFPGAN never.
  runpod         only with --paid --realesrgan and env RUNPOD_API_KEY + RUNPOD_ENDPOINT_ID.
  fal_face       only with --paid and env FAL_KEY + FAL_FACE=topaz|crystal.
  fal_ultra      only with --paid and env FAL_KEY (clarityai/crystal-upscaler).
NO non-commercial weights are ever downloaded by this script.
Every result goes through FACE LOCK (YuNet + AuraFace) like on the server.

  backend venv:  python3 tools/photo_bench/run_bench.py --inputs <dir with 01_portrait.jpg …> \
                   --out owner_actions/photo_bench [--extra owner.jpg] [--paid]
"""
import argparse
import io
import json
import os
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SET = [("01_portrait.jpg", "portrait"), ("04_portrait.jpg", "portrait"),
       ("21_darkskin.jpg", "dark_skin"), ("25_darkskin.jpg", "dark_skin"),
       ("29_darkskin.jpg", "dark_skin_low_light"), ("33_old_real.jpg", "old_real"),
       ("36_old_real.jpg", "old_real"), ("41_group.jpg", "group"), ("44_group.jpg", "group"),
       ("47_low_light_cc0.jpg", "low_light")]


def setup_django(models, media):
    sys.path.insert(0, os.path.join(ROOT, "backend"))
    import django
    from django.conf import settings
    if not settings.configured:
        settings.configure(PHOTO_MODEL_DIR=models, MEDIA_ROOT=media, USE_TZ=True,
                           TIME_ZONE="Asia/Dhaka", INSTALLED_APPS=[], SECRET_KEY="bench")
        django.setup()


def f32(im):
    return np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0


def u8(a):
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")


def jpeg_bytes(a, q=90):
    b = io.BytesIO()
    u8(a).save(b, "JPEG", quality=q)
    return b.getvalue()


def damage(clean, kind, seed):
    rng = np.random.default_rng(seed)
    h, w = clean.shape[:2]
    if kind in ("portrait", "dark_skin", "group"):
        small = u8(clean).resize((w // 2, h // 2), Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.8))
        b = io.BytesIO()
        small.save(b, "JPEG", quality=55)       # WhatsApp-like
        return b.getvalue()
    if kind in ("low_light", "dark_skin_low_light"):
        a = (clean ** 2.0) * 0.45 + rng.normal(0, 7 / 255, clean.shape).astype(np.float32)
        return jpeg_bytes(a, 70)
    return jpeg_bytes(clean, 92)                # real old photo: as it is


def identity(FL, yunet, aura, ref, out):
    """Worst-face AuraFace cosine between the reference and the output."""
    try:
        f0 = FL.detect(ref, yunet)
        if not f0:
            return None
        f1 = FL.detect(out, yunet, min_score=0.6)
        sx, sy = out.shape[1] / ref.shape[1], out.shape[0] / ref.shape[0]
        sims = []
        for f in f0:
            m = FL._match(f, f1, sx, sy)
            if m is None:
                sims.append(0.0)
                continue
            sims.append(FL.similarity(FL.embed(ref, f, aura), FL.embed(out, m, aura)))
        return round(min(sims), 3)
    except Exception:
        return None


def sharp(a):
    import cv2
    y = (a @ np.asarray([0.299, 0.587, 0.114], np.float32) * 255).astype(np.float32)
    return round(float(cv2.Laplacian(y, cv2.CV_32F).var()), 1)


def label(im, text):
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, im.width, 22], fill=(0, 0, 0))
    d.text((6, 5), text, fill=(255, 255, 255))
    return im


def sheet(tiles, path, h=420):
    ims = []
    for t, img in tiles:
        im = u8(img) if isinstance(img, np.ndarray) else img
        im = im.resize((max(1, round(im.width * h / im.height)), h), Image.LANCZOS)
        ims.append(label(im, t))
    W = sum(i.width for i in ims) + 6 * (len(ims) - 1)
    o = Image.new("RGB", (W, h), (255, 255, 255))
    x = 0
    for i in ims:
        o.paste(i, (x, 0))
        x += i.width + 6
    o.save(path, "JPEG", quality=80)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inputs", required=True)
    ap.add_argument("--out", default=os.path.join(ROOT, "owner_actions", "photo_bench"))
    ap.add_argument("--models", default=os.path.join(ROOT, "backend", "core", "photo_models"))
    ap.add_argument("--extra", action="append", default=[])
    ap.add_argument("--paid", action="store_true", help="also run paid providers whose keys are in env")
    ap.add_argument("--realesrgan", action="store_true",
                    help="also run the Real-ESRGAN paths (licence-grey weights, owner decision)")
    ap.add_argument("--only", default="", help="comma list of file names")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    media = os.path.join(a.out, ".media_tmp")
    setup_django(a.models, media)
    from core import photo_facelock as FL
    from core import photo_final as PFN
    from core import photo_models as PM
    from core import photo_restore as R
    from core.logic import photo_studio as PS
    yunet, aura = PM.server_model("server_face"), PM.server_model("server_face_id")
    ps = PS.normalize_cfg({})
    providers = ["local_clean"]
    if a.realesrgan:
        providers.append("local_worker")
    if a.paid:
        if a.realesrgan and os.environ.get("REPLICATE_API_TOKEN") and os.environ.get("REPLICATE_ESRGAN_VERSION"):
            providers.append("replicate")
        if a.realesrgan and os.environ.get("RUNPOD_API_KEY") and os.environ.get("RUNPOD_ENDPOINT_ID"):
            providers.append("runpod")
        if os.environ.get("FAL_KEY") and os.environ.get("FAL_FACE") in ("topaz", "crystal"):
            providers.append("fal_face")
        if os.environ.get("FAL_KEY"):
            providers.append("fal_ultra")
    man = PM.load_manifest() or {"files": []}

    def role_path(role):
        return next((os.path.join(PM.model_dir(), f["name"]) for f in man["files"]
                     if f["role"] == role), None)
    clean_paths = {"upscale": None, "server_face": yunet, "segment": role_path("segment")}

    items = [(n, k) for n, k in SET if not a.only or n in a.only.split(",")]
    items += [(p, "extra") for p in a.extra]
    rows = []
    for idx, (name, kind) in enumerate(items):
        path = name if kind == "extra" else os.path.join(a.inputs, name)
        if not os.path.isfile(path):
            print("skip (missing)", path)
            continue
        clean = f32(Image.open(path))
        raw = open(path, "rb").read() if kind == "extra" else damage(clean, kind, idx)
        inp = R._decode(raw)
        ref = clean if kind != "extra" else inp
        tiles = [("original (clean)", clean)] if kind != "extra" else []
        tiles.append(("input", inp))
        row = {"file": os.path.basename(name), "kind": kind, "input_px": list(inp.shape[1::-1]),
               "runs": []}
        for prov in providers:
            for preset in ("natural", "strong"):
                if prov == "fal_ultra" and preset == "strong":
                    continue
                t0 = time.monotonic()
                cost, err, out = 0.0, "", None
                try:
                    if prov == "local_clean":
                        ob, steps = PFN.local_enhance(raw, preset=preset, blur=preset == "strong",
                                                      max_mp=ps["max_input_mp"], paths=clean_paths)
                    elif prov == "local_worker":
                        rg = dict(clean_paths, upscale=role_path("upscale"))
                        ob, steps = PFN.local_enhance(raw, preset=preset, blur=preset == "strong",
                                                      max_mp=ps["max_input_mp"], paths=rg)
                    elif prov == "fal_face":
                        from core.logic import photo_final as PF
                        ch = os.environ["FAL_FACE"]
                        conf = {"name": "fal_face", "token": os.environ["FAL_KEY"], "choice": ch,
                                "endpoint": PF.FAL_FACE_ENDPOINTS[ch],
                                "flat": 0.08 if ch == "topaz" else 0.0,
                                "usd_per_mp": 0.0 if ch == "topaz" else 0.016,
                                "est": 0.08, "usd_per_s": 0.0, "version": "bench"}
                        ob, cost, _s, steps = PFN._run_fal_face(conf, raw, preset=preset,
                                                                blur=preset == "strong", ps=ps, timeout=180)
                    elif prov == "replicate":
                        conf = {"name": "replicate", "token": os.environ["REPLICATE_API_TOKEN"],
                                "upscale_version": os.environ["REPLICATE_ESRGAN_VERSION"],
                                "usd_per_s": float(os.environ.get("REPLICATE_USD_PER_S", "0.000975")),
                                "est": 0.01, "version": "bench"}
                        ob, cost, _s, steps = PFN._run_replicate(conf, raw, preset=preset,
                                                                 blur=preset == "strong", ps=ps, timeout=180)
                    elif prov == "runpod":
                        conf = {"name": "runpod_serverless", "token": os.environ["RUNPOD_API_KEY"],
                                "endpoint": os.environ["RUNPOD_ENDPOINT_ID"],
                                "usd_per_s": float(os.environ.get("RUNPOD_USD_PER_S", "0.00019")),
                                "est": 0.01, "version": "bench"}
                        ob, cost, _s, steps = PFN._run_runpod(conf, raw, preset=preset,
                                                              blur=preset == "strong", ps=ps, timeout=180)
                    else:
                        os.environ.setdefault("FAL_MODEL", PFN.DEFAULT_ULTRA_MODEL)
                        PFN.ultra_conf = lambda: {"token": os.environ["FAL_KEY"],
                                                  "model": os.environ["FAL_MODEL"],
                                                  "usd_per_mp": 0.016, "flat": 0.0, "scale": 2, "in_mp": 1.0}
                        ob, cost, steps = _ultra_no_db(PFN, raw)
                    out = R._decode(ob)
                    lock_rep = {}
                    if yunet:
                        try:
                            out, lock_rep = FL.face_lock(inp, out, yunet, embed_path=aura)
                        except FL.FaceLockUnavailable:
                            pass
                except Exception as e:  # noqa: BLE001 — report honestly, keep going
                    err = "%s:%s" % (type(e).__name__, str(e)[:80])
                    steps, lock_rep = {}, {}
                sec = round(time.monotonic() - t0, 1)
                run = {"provider": prov, "preset": preset, "seconds": sec, "cost_usd": round(cost, 5),
                       "error": err}
                if out is not None:
                    run.update(identity=identity(FL, yunet, aura, ref, out) if (yunet and aura) else None,
                               sharpness=sharp(out), out_px=list(out.shape[1::-1]),
                               face_lock=lock_rep.get("action"),
                               steps={k: steps.get(k) for k in ("faces", "global_ai", "faces_crisp",
                                                                "bg_blur", "face_tone", "detail")
                                      if isinstance(steps, dict) and k in steps})
                    tiles.append(("%s %s %.0fs $%.4f" % (prov, preset, sec, cost), out))
                row["runs"].append(run)
                print(name, prov, preset, sec, run.get("identity"), err)
        row["sharpness_input"] = sharp(inp)
        sheet(tiles, os.path.join(a.out, "bench_%s" % os.path.basename(name).rsplit(".", 1)[0] + ".jpg"))
        rows.append(row)
    with open(os.path.join(a.out, "results.json"), "w") as fh:
        json.dump({"providers": providers, "rows": rows,
                   "note": "identity = AuraFace cosine vs the clean original (worst face); "
                           "1.0 identical, a different person < ~0.35"}, fh, indent=1)
    import shutil
    shutil.rmtree(media, ignore_errors=True)


def _ultra_no_db(PFN, raw):
    """fal.ai Ultra HD without the DB log (bench only)."""
    import base64
    import json as js
    conf = PFN.ultra_conf()
    r = PFN._http().post("https://fal.run/%s" % conf["model"], timeout=180,
                         headers={"Authorization": "Key %s" % conf["token"],
                                  "Content-Type": "application/json"},
                         data=js.dumps({"image_url": "data:image/jpeg;base64," + base64.b64encode(raw).decode(),
                                        "scale_factor": 2}))
    j = r.json()
    img = j.get("image") or (j.get("images") or [{}])[0]
    out = PFN._get_image(img.get("url"), 180)
    w, h = Image.open(io.BytesIO(out)).size
    return out, w * h / 1e6 * conf["usd_per_mp"], {}


if __name__ == "__main__":
    main()
