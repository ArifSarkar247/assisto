#!/usr/bin/env python3
"""d1-photo v2: build the 50-photo licence-clean test set.

  20 originals of the p2/d1 set (.phaseB/photo_studio_eval/sources.json)
+ 12 official portraits of the 118th US Congress (US federal works = public
     domain), chosen as the DARKEST skin tones among the candidates (mean
     face-skin lightness L* from YuNet face boxes) — the owner asked for dark
     skin tones explicitly;
+  8 real OLD photographs, Harris & Ewing collection (public domain);
+  6 GROUP photographs (Commons "Group photographs of men", public-domain files only);
+  4 CC0 photos (Category:CC-Zero) for extra low-light cases (darkened synthetically).

Every file's licence is read from Commons' own extmetadata (LicenseShortName)
and only "Public domain" / "CC0" is accepted. Writes <out>/sources_50.json and
downloads 960-px thumbnails, one request per second.

  python3 tools/photo_eval/fetch_50.py <out dir> <yunet.onnx>
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

UA = "AssistoPhotoEval/1.0 (licence-clean test set; https://lifeassisto.com)"
API = "https://commons.wikimedia.org/w/api.php"
HERE = os.path.dirname(os.path.abspath(__file__))
OK_LIC = ("Public domain", "CC0")


def api(params):
    q = urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(API + "?" + q, headers={"User-Agent": UA})
    for i in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except Exception:
            time.sleep(3 * (i + 1))
    return {}


def members(cat, limit=80):
    d = api({"action": "query", "generator": "categorymembers", "gcmtitle": cat, "gcmtype": "file",
             "gcmlimit": limit, "prop": "imageinfo", "iiprop": "url|extmetadata|size",
             "iiurlwidth": 960})
    out = []
    for p in sorted((d.get("query", {}).get("pages", {}) or {}).values(), key=lambda p: p["title"]):
        ii = (p.get("imageinfo") or [{}])[0]
        lic = ((ii.get("extmetadata") or {}).get("LicenseShortName") or {}).get("value", "")
        if lic in OK_LIC and ii.get("thumburl", "").lower().split("?")[0].endswith((".jpg", ".jpeg", ".png")):
            out.append({"title": p["title"], "licence": lic, "page": ii.get("descriptionurl", ""),
                        "thumb": ii["thumburl"]})
    return out


def download(url, path):
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return True
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for i in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            with open(path, "wb") as fh:
                fh.write(data)
            time.sleep(1)
            return True
        except Exception:
            time.sleep(5 * (i + 1))
    return False


def skin_l(path, yunet):
    import cv2
    import numpy as np
    img = cv2.imread(path)
    if img is None:
        return None
    det = cv2.FaceDetectorYN.create(yunet, "", (img.shape[1], img.shape[0]), 0.8)
    _, f = det.detect(img)
    if f is None or not len(f):
        return None
    x, y, w, h = [int(v) for v in f[0][:4]]
    roi = img[y + h // 4:y + 3 * h // 4, x + w // 4:x + 3 * w // 4]
    if roi.size == 0:
        return None
    return float(cv2.cvtColor(roi, cv2.COLOR_BGR2LAB)[..., 0].mean() * 100 / 255)


def main():
    out, yunet = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    base = json.load(open(os.path.join(HERE, "..", "..", ".phaseB", "photo_studio_eval", "sources.json")))
    rows = []
    for i, s in enumerate(base, 1):
        kind = {"portrait": "portrait"}.get(s["kind"], "scene")
        rows.append({**s, "file": s["file"], "set": "d1-20"})
        download(s["thumb"], os.path.join(out, s["file"]))
    n = len(rows)
    # dark skin tones
    cands = members("Category:Official portraits of members of the 118th United States Congress", 120)
    scored = []
    for c in cands[:60]:
        p = os.path.join(out, "_cand_%s.jpg" % abs(hash(c["title"])))
        if download(c["thumb"], p):
            L = skin_l(p, yunet)
            if L is not None:
                scored.append((L, c, p))
    scored.sort(key=lambda t: t[0])
    known = {r["title"] for r in rows}
    for L, c, p in [t for t in scored if t[1]["title"] not in known][:12]:
        n += 1
        f = "%02d_darkskin.jpg" % n
        os.replace(p, os.path.join(out, f))
        rows.append({"file": f, "kind": "dark_skin", "title": c["title"], "licence": c["licence"],
                     "page": c["page"], "thumb": c["thumb"], "skin_L": round(L, 1), "set": "d1-50"})
    for name in os.listdir(out):
        if name.startswith("_cand_"):
            os.remove(os.path.join(out, name))
    for cat, kind, k in (("Category:Portrait photographs in the Harris & Ewing Collection", "old_real", 8),
                         ("Category:Group photographs of men", "group", 6),
                         ("Category:CC-Zero", "low_light_cc0", 4)):
        got = 0
        for c in members(cat, 80):
            if got >= k:
                break
            n += 1
            f = "%02d_%s.jpg" % (n, kind)
            if download(c["thumb"], os.path.join(out, f)):
                rows.append({"file": f, "kind": kind, "title": c["title"], "licence": c["licence"],
                             "page": c["page"], "thumb": c["thumb"], "set": "d1-50"})
                got += 1
            else:
                n -= 1
    json.dump(rows, open(os.path.join(out, "sources_50.json"), "w"), indent=1, ensure_ascii=False)
    print(len(rows), "photos")


if __name__ == "__main__":
    main()
