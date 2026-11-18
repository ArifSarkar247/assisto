"""cctvdet3: fine-tune YOLOX-Nano into a BANGLADESH VEHICLE model for the
Shop Box (CI only: .github/workflows/cctv-vehicle-train.yml; CPU, ~3 h).

WHY: on real Bangladeshi street photos the stock COCO models miss most local
vehicles (frame-level recall of CNG / rickshaw / leguna / bike well under
50 %, night far lower — tools/e2e/cctv_vehicle_frames.py, CI run 42744814212):
COCO has no CNG, rickshaw or leguna. This trains on photos that have them.

WHAT
  start   YOLOX-Nano COCO weights (Megvii release 0.1.1rc0, Apache-2.0,
          SHA-256 pinned in the workflow), YOLOX 0.3.0 code (Apache-2.0).
  data    the Sylhet set's train/ folders ONLY (cctv_real_set.py, CC BY 4.0);
          its valid/ = calibration, test/ = held-out, and BanglaRoad (Dhaka /
          Sirajganj, CC BY 4.0) = an independent held-out set never used here.
  negatives (cctvdet3 round 2) licensed COCO train2017 pictures with NO
          vehicle at all (indoor, people, animals, streets without cars) —
          the first model, trained on street photos only, called empty
          spots, night lights and walking people "vehicles"; train2017 is
          never used by the accuracy harness (val2017), so held-out stays clean.
  labels  the 11 local classes mapped to the COCO ids the box already reports
          (cctv_real_set.TO_COCO): the model drops in for shopbox/person.py
          (same 416 input, same 85-wide output, same decoding).
  augment CCTV-like: scale / crop / flip, colour jitter, grey IR + gamma,
          blur, sensor noise, JPEG; letterbox 416 with 114 (YOLOX's own).
  output  assisto_vehicle_bd_nano.onnx (+ .sha256) as a CI artifact; the
          Shop Box fetches it only after it is published at the pinned URL
          (shopbox/model_fetch.BD_VEHICLE_MODEL_*), never committed.

Faces are never a class: vehicles only.
"""
import argparse
import hashlib
import math
import os
import random
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import cctv_real_set as RS  # noqa: E402

SIZE = 416


def build_model(num_classes=80):
    from yolox.models import YOLOPAFPN, YOLOX, YOLOXHead
    in_ch = [256, 512, 1024]
    backbone = YOLOPAFPN(0.33, 0.25, in_channels=in_ch, act="silu", depthwise=True)
    head = YOLOXHead(num_classes, 0.25, in_channels=in_ch, act="silu", depthwise=True)
    m = YOLOX(backbone, head)
    import torch.nn as nn
    for mod in m.modules():
        if isinstance(mod, nn.BatchNorm2d):
            mod.eps = 1e-3
            mod.momentum = 0.03
    return m


def augment(img, boxes, rnd):
    """img 360x640 BGR uint8, boxes [(cls, x1, y1, x2, y2) norm] ->
    (416x416 float32 CHW, labels [n, 5] = cls, cx, cy, w, h in pixels)."""
    import cv2
    h, w = img.shape[:2]
    b = np.array([[x1 * w, y1 * h, x2 * w, y2 * h] for _, x1, y1, x2, y2 in boxes], np.float32).reshape(-1, 4)
    c = np.array([cl for cl, *_ in boxes], np.float32)
    # random crop (zoom in, like a CCTV framing or the zone "second look")
    if rnd.random() < 0.6:
        s = rnd.uniform(0.45, 1.0)
        cw, ch = int(w * s), int(h * s)
        x0, y0 = rnd.randint(0, w - cw), rnd.randint(0, h - ch)
        img = img[y0:y0 + ch, x0:x0 + cw]
        b = b - np.array([x0, y0, x0, y0], np.float32)
        ob = b.copy()
        b[:, [0, 2]] = b[:, [0, 2]].clip(0, cw)
        b[:, [1, 3]] = b[:, [1, 3]].clip(0, ch)
        area0 = (ob[:, 2] - ob[:, 0]) * (ob[:, 3] - ob[:, 1])
        area1 = (b[:, 2] - b[:, 0]) * (b[:, 3] - b[:, 1])
        keep = (area1 > 0.35 * np.maximum(area0, 1e-6)) & (b[:, 2] - b[:, 0] > 3) & (b[:, 3] - b[:, 1] > 3)
        b, c = b[keep], c[keep]
        h, w = img.shape[:2]
    if rnd.random() < 0.5:
        img = img[:, ::-1]
        b = b[:, [2, 1, 0, 3]].copy()
        b[:, 0] = w - b[:, 0]
        b[:, 2] = w - b[:, 2]
    img = np.ascontiguousarray(img)
    # colour / light
    f = img.astype(np.float32)
    r = rnd.random()
    if r < 0.25:                                   # grey IR night camera
        g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
        g = 255.0 * np.power(g / 255.0, rnd.uniform(1.0, 1.8)) * rnd.uniform(0.6, 1.0)
        f = np.repeat(g[..., None], 3, axis=2)
    else:
        hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[..., 0] = (hsv[..., 0] + rnd.uniform(-8, 8)) % 180
        hsv[..., 1] *= rnd.uniform(0.6, 1.4)
        hsv[..., 2] *= rnd.uniform(0.55, 1.35)
        f = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2BGR).astype(np.float32)
    if rnd.random() < 0.2:
        f = cv2.GaussianBlur(f, (0, 0), rnd.uniform(0.6, 1.6))
    if rnd.random() < 0.6:
        f = f + np.random.default_rng(rnd.randrange(1 << 30)).normal(0, rnd.uniform(2, 9), f.shape[:2])[..., None]
    u8 = np.clip(f, 0, 255).astype(np.uint8)
    if rnd.random() < 0.6:
        ok, enc = cv2.imencode(".jpg", u8, [cv2.IMWRITE_JPEG_QUALITY, rnd.randint(35, 85)])
        u8 = cv2.imdecode(enc, cv2.IMREAD_COLOR)
    # letterbox exactly like shopbox/person._letterbox
    rr = min(SIZE / h, SIZE / w)
    nh, nw = int(round(h * rr)), int(round(w * rr))
    canvas = np.full((SIZE, SIZE, 3), 114, np.uint8)
    canvas[:nh, :nw] = cv2.resize(u8, (nw, nh), interpolation=cv2.INTER_LINEAR)
    b = b * rr
    lab = np.zeros((len(b), 5), np.float32)
    if len(b):
        lab[:, 0] = c
        lab[:, 1] = (b[:, 0] + b[:, 2]) / 2
        lab[:, 2] = (b[:, 1] + b[:, 3]) / 2
        lab[:, 3] = b[:, 2] - b[:, 0]
        lab[:, 4] = b[:, 3] - b[:, 1]
        lab = lab[(lab[:, 3] > 2) & (lab[:, 4] > 2)]
    return canvas.transpose(2, 0, 1).astype(np.float32), lab


COCO_VEHICLE_CATS = {2, 3, 4, 5, 6, 7, 8, 9}     # bicycle .. boat: never in a negative


def coco_negatives(ann_path, cache, n, workers=16):
    """n licensed COCO train2017 pictures without any vehicle -> [(path, [])]."""
    import json
    import urllib.request
    from concurrent.futures import ThreadPoolExecutor
    import cv2
    sys.path.insert(0, HERE)
    import cctv_accuracy as CA
    os.makedirs(cache, exist_ok=True)
    ann = json.load(open(ann_path))
    has_veh = {a["image_id"] for a in ann["annotations"] if a["category_id"] in COCO_VEHICLE_CATS}
    ims = [im for im in ann["images"] if im.get("license") in CA.OK_LICENCES and im["id"] not in has_veh]
    del ann
    random.Random(20261117).shuffle(ims)
    ims = ims[: int(n * 1.2)]

    def one(im):
        p = os.path.join(cache, "neg_%d.jpg" % im["id"])
        if os.path.exists(p):
            return p
        try:
            with urllib.request.urlopen(im["coco_url"], timeout=30) as r:
                data = r.read()
            img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
            if img is None:
                return None
            h, w = img.shape[:2]
            s = 640.0 / max(h, w)
            cv2.imwrite(p, cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA),
                        [cv2.IMWRITE_JPEG_QUALITY, 92])
            return p
        except Exception:
            return None

    with ThreadPoolExecutor(workers) as ex:
        got = [p for p in ex.map(one, ims) if p]
    return [(p, []) for p in got[:n]]


def batches(items, bs, rnd, max_obj=120):
    import cv2
    import torch
    while True:
        rnd.shuffle(items)
        for i in range(0, len(items) - bs + 1, bs):
            imgs, labs = [], []
            for path, boxes in items[i:i + bs]:
                img = cv2.imread(path)
                x, lab = augment(img, boxes, rnd)
                imgs.append(x)
                labs.append(lab[:max_obj])
            t = np.zeros((bs, max_obj, 5), np.float32)
            for j, lab in enumerate(labs):
                t[j, :len(lab)] = lab
            yield torch.from_numpy(np.stack(imgs)), torch.from_numpy(t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", required=True)
    ap.add_argument("--cache", default="/tmp/sylhet_train")
    ap.add_argument("--out", default="assisto_vehicle_bd_nano.onnx")
    ap.add_argument("--minutes", type=float, default=180.0)
    ap.add_argument("--bs", type=int, default=16)
    ap.add_argument("--smoke", action="store_true")
    ap.add_argument("--neg-ann", default="", help="instances_train2017.json (vehicle-free negatives)")
    ap.add_argument("--neg", type=int, default=1500)
    a = ap.parse_args()
    import torch
    torch.set_num_threads(max(1, os.cpu_count() or 4))
    torch.manual_seed(20261110)
    rnd = random.Random(20261110)
    t0 = time.time()
    items = RS.train_members(a.cache)
    items = [it for it in items if it[1]]
    print("train photos %d (%.0fs)" % (len(items), time.time() - t0), flush=True)
    if a.neg_ann and a.neg > 0:
        negs = coco_negatives(a.neg_ann, a.cache + "_neg", 64 if a.smoke else a.neg)
        print("vehicle-free negatives %d (%.0fs)" % (len(negs), time.time() - t0), flush=True)
        items += negs
    if a.smoke:
        items = items[:48] + [it for it in items if not it[1]][:16]
    model = build_model()
    ck = torch.load(a.weights, map_location="cpu")
    model.load_state_dict(ck["model"] if "model" in ck else ck)
    model.train()
    ema = build_model()
    ema.load_state_dict(model.state_dict())
    ema.eval()
    for p in ema.parameters():
        p.requires_grad_(False)
    g_bn, g_w, g_b = [], [], []
    for mod in model.modules():
        if hasattr(mod, "bias") and isinstance(mod.bias, torch.nn.Parameter):
            g_b.append(mod.bias)
        if isinstance(mod, torch.nn.BatchNorm2d):
            g_bn.append(mod.weight)
        elif hasattr(mod, "weight") and isinstance(mod.weight, torch.nn.Parameter):
            g_w.append(mod.weight)
    base_lr = 0.01 * a.bs / 64
    opt = torch.optim.SGD(g_bn, lr=base_lr, momentum=0.9, nesterov=True)
    opt.add_param_group({"params": g_w, "weight_decay": 5e-4})
    opt.add_param_group({"params": g_b})
    gen = batches(items, a.bs, rnd)
    # measure the speed, then fit the run into the time budget
    it, total, warm = 0, None, 200
    budget = a.minutes * 60.0
    t_train = time.time()
    hist = []
    while True:
        x, y = next(gen)
        if total is None and it == 20:
            per = (time.time() - t_train) / 20.0
            total = max(60, int((budget - (time.time() - t_train)) / per) + 20)
            if a.smoke:
                total = 30
            print("%.2f s/iter -> %d iterations (%.1f epochs)" % (per, total, total * a.bs / len(items)),
                  flush=True)
        T = total or 10 ** 9
        lr = base_lr * (it + 1) / warm if it < warm else \
            base_lr * (0.05 + 0.95 * 0.5 * (1 + math.cos(math.pi * (it - warm) / max(1, T - warm))))
        for g in opt.param_groups:
            g["lr"] = lr
        out = model(x, y)
        loss = out["total_loss"]
        opt.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 10.0)
        opt.step()
        d = 0.9998 * (1 - math.exp(-(it + 1) / 2000.0))
        with torch.no_grad():
            msd = model.state_dict()
            for k, v in ema.state_dict().items():
                if v.dtype.is_floating_point:
                    v.mul_(d).add_(msd[k].detach(), alpha=1 - d)
                else:
                    v.copy_(msd[k])
        hist.append(float(loss))
        it += 1
        if it % 50 == 0:
            print("iter %d/%s loss %.3f (iou %.3f obj %.3f cls %.3f) lr %.5f %.0f min" % (
                it, total, sum(hist[-50:]) / len(hist[-50:]), float(out["iou_loss"]),
                float(out["conf_loss"]), float(out["cls_loss"]), lr, (time.time() - t0) / 60), flush=True)
        if total is not None and it >= total:
            break
    ema.head.decode_in_inference = False
    ema.eval()
    dummy = torch.zeros(1, 3, SIZE, SIZE)
    torch.onnx.export(ema, dummy, a.out, input_names=["images"], output_names=["output"],
                      opset_version=11, do_constant_folding=True)
    h = hashlib.sha256(open(a.out, "rb").read()).hexdigest()
    open(a.out + ".sha256", "w").write("%s  %s\n" % (h, os.path.basename(a.out)))
    print("MODEL %s %d bytes sha256 %s (%d iterations, %.0f min)" % (
        a.out, os.path.getsize(a.out), h, it, (time.time() - t0) / 60), flush=True)


if __name__ == "__main__":
    main()
