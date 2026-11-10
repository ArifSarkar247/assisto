"""cctvdet3: a REAL Bangladeshi street-scene vehicle set for the CCTV
accuracy harness (CI only; nothing downloaded is committed).

SOURCE (licence CC BY 4.0, public, no login):
  Rahman A., Munim Shahriar S., Awsaf S.A., Jahan I., Ferdous J.,
  Chowdhury M.J.U. (Leading University, Sylhet) — "Multi-Class Vehicle
  Detection Dataset for Dense and Heterogeneous Urban Traffic in Bangladesh",
  Mendeley Data v2, DOI 10.17632/tx6699m24b.2,
  https://data.mendeley.com/datasets/tx6699m24b/2 — 1280 x 720 street-level
  photos of Sylhet traffic, day and night, hand-labelled boxes (YOLO txt) for
  11 classes: Bicycle, Bike, Bus, CNGRickshaw, Car, CycleRickshaw, Leguna,
  Microbus, Pickup, Truck, VanRickshaw.
  Changes made (CC BY 4.0 asks us to say so): resized to 640 x 360, JPEG
  re-encoded with camera noise; some scenarios paste a rectangular crop of
  one photo's vehicle into another photo of the same set.

The archive is 8.6 GB; we read ONLY the images we use, by HTTP range
requests into the public zip (its central directory, then each member) —
a few hundred MB on a CI runner.

SPLIT: every image is CALIBRATION or HELD-OUT by a hash of its name, so
thresholds are tuned on one half and the reported numbers come from the
other half only.
"""
import hashlib
import io
import os
import random
import threading
import zipfile
from concurrent.futures import ThreadPoolExecutor

import numpy as np

SOURCE = {
    "name": "Multi-Class Vehicle Detection Dataset for Dense and Heterogeneous Urban Traffic in Bangladesh",
    "authors": "Rahman A., Munim Shahriar S., Awsaf S.A., Jahan I., Ferdous J., Chowdhury M.J.U. (Leading University)",
    "doi": "10.17632/tx6699m24b.2",
    "url": "https://data.mendeley.com/datasets/tx6699m24b/2",
    "licence": "CC BY 4.0",
    "changes": "resized to 640x360, camera noise + JPEG; rectangular vehicle crops pasted between photos of the same set in some scenarios",
}
ZIP_URL = ("https://data.mendeley.com/public-files/datasets/tx6699m24b/files/"
           "8a584d53-f142-481d-9622-65ea04171a3b/file_downloaded")
ROOT_DIR = "Vehicle_Detection_Dataset_New/"
NAMES = ["Bicycle", "Bike", "Bus", "CNGRickshaw", "Car", "CycleRickshaw", "Leguna",
         "Microbus", "Pickup", "Truck", "VanRickshaw"]
W, H = 640, 360


def split_of(key):
    """'cal' or 'held' — fixed by the name, never by the result."""
    return "cal" if hashlib.sha256(key.encode()).digest()[0] % 2 == 0 else "held"


class RangeFile(io.RawIOBase):
    """A seekable read-only file over HTTP range requests (the S3 link the
    public URL redirects to expires after 5 minutes: re-resolved on 403)."""

    def __init__(self, url):
        import requests
        self._rq = requests
        self.src = url
        self._lock = threading.Lock()
        self._resolve()
        r = self._get(0, 0)
        self.size = int(r.headers["Content-Range"].split("/")[1])
        self.pos = 0

    def _resolve(self):
        r = self._rq.get(self.src, allow_redirects=False, timeout=60)
        self.url = r.headers.get("location", self.src)

    def _get(self, a, b):
        for attempt in range(6):
            try:
                r = self._rq.get(self.url, headers={"Range": "bytes=%d-%d" % (a, b)}, timeout=120)
                if r.status_code in (403, 400):
                    with self._lock:
                        self._resolve()
                    continue
                if r.status_code == 206:
                    return r
            except Exception:
                pass
            import time
            time.sleep(3 * (attempt + 1))
        raise IOError("range read failed")

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, o, whence=0):
        self.pos = o if whence == 0 else (self.pos + o if whence == 1 else self.size + o)
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        b = self._get(self.pos, min(self.size, self.pos + n) - 1).content
        self.pos += len(b)
        return b

    def readinto(self, buf):
        d = self.read(len(buf))
        buf[:len(d)] = d
        return len(d)

    def read_member(self, info):
        """One member's bytes with two range requests (thread-safe)."""
        hdr = self._get(info.header_offset, info.header_offset + 29).content
        nlen = int.from_bytes(hdr[26:28], "little")
        xlen = int.from_bytes(hdr[28:30], "little")
        a = info.header_offset + 30 + nlen + xlen
        raw = self._get(a, a + info.compress_size - 1).content
        if info.compress_type == zipfile.ZIP_STORED:
            return raw
        import zlib
        return zlib.decompress(raw, -15)


def parse_labels(txt):
    """YOLO txt -> [(class_name, x1, y1, x2, y2)] normalised."""
    out = []
    for line in txt.splitlines():
        p = line.split()
        if len(p) < 5:
            continue
        try:
            c, cx, cy, w, h = int(p[0]), float(p[1]), float(p[2]), float(p[3]), float(p[4])
        except ValueError:
            continue
        if not 0 <= c < len(NAMES):
            continue
        out.append((NAMES[c], max(0.0, cx - w / 2), max(0.0, cy - h / 2),
                    min(1.0, cx + w / 2), min(1.0, cy + h / 2)))
    return out


def load(n_day, n_night, cache, seed=20261110, workers=8):
    """-> [{"key", "light": day|night, "split": cal|held, "img" (640x360
    BGR uint8), "boxes": [(cls, x1, y1, x2, y2)]}] — only photos with at
    least one CCTV-size vehicle (box height >= 8 % of the frame)."""
    import cv2
    os.makedirs(cache, exist_ok=True)
    rf = RangeFile(ZIP_URL)
    z = zipfile.ZipFile(io.BufferedReader(rf, 1 << 16))
    infos = {i.filename: i for i in z.infolist()}
    picks = []
    rnd = random.Random(seed)
    for light, n in (("day", n_day), ("night", n_night)):
        pre = ROOT_DIR + "%s_images_dataset/" % light
        imgs = sorted(k for k in infos if k.startswith(pre) and k.endswith(".jpg"))
        rnd.shuffle(imgs)
        picks += [(light, k) for k in imgs[: int(n * 1.6)]]

    def one(item):
        light, k = item
        key = k[len(ROOT_DIR):]
        safe = hashlib.sha1(key.encode()).hexdigest()
        jp, tp = os.path.join(cache, safe + ".jpg"), os.path.join(cache, safe + ".txt")
        lab = k.replace("/images/", "/labels/")[:-4] + ".txt"
        try:
            if not os.path.exists(tp):
                if lab not in infos:
                    return None
                txt = rf.read_member(infos[lab]).decode("utf-8", "replace")
                boxes = parse_labels(txt)
                if not any(b[4] - b[2] >= 0.08 for b in boxes):
                    open(tp, "w").write(txt)
                    return None
                open(jp, "wb").write(rf.read_member(infos[k]))
                open(tp, "w").write(txt)
            boxes = parse_labels(open(tp).read())
            if not os.path.exists(jp) or not any(b[4] - b[2] >= 0.08 for b in boxes):
                return None
            img = cv2.imdecode(np.frombuffer(open(jp, "rb").read(), np.uint8), cv2.IMREAD_COLOR)
            if img is None:
                return None
            img = cv2.resize(img, (W, H), interpolation=cv2.INTER_AREA)
            return {"key": key, "light": light, "split": split_of(key), "img": img,
                    "boxes": boxes}
        except Exception:
            return None

    with ThreadPoolExecutor(workers) as ex:
        got = [g for g in ex.map(one, picks) if g is not None]
    out = []
    for light, n in (("day", n_day), ("night", n_night)):
        out += [g for g in got if g["light"] == light][:n]
    return out


def vehicle_crop(item, box, margin=0.12):
    """A RECTANGULAR crop of one labelled vehicle with its own surroundings
    (road, shadow, light) and a feathered edge — not a polygon cut-out.
    -> (patch float32 HxWx3, alpha float32 HxW, (fx1, fy1, fx2, fy2) = the
    vehicle's box inside the patch, normalised)."""
    import cv2
    _, x1, y1, x2, y2 = box
    bw, bh = x2 - x1, y2 - y1
    X1, Y1 = max(0.0, x1 - bw * margin), max(0.0, y1 - bh * margin)
    X2, Y2 = min(1.0, x2 + bw * margin), min(1.0, y2 + bh * margin)
    a, b, c, d = int(X1 * W), int(Y1 * H), int(np.ceil(X2 * W)), int(np.ceil(Y2 * H))
    patch = item["img"][b:d, a:c].astype(np.float32)
    ph, pw = patch.shape[:2]
    alpha = np.ones((ph, pw), np.float32)
    f = max(2, int(min(ph, pw) * 0.08))
    ramp = np.linspace(0.0, 1.0, f, dtype=np.float32)
    alpha[:f] *= ramp[:, None]
    alpha[-f:] *= ramp[::-1][:, None]
    alpha[:, :f] *= ramp[None, :]
    alpha[:, -f:] *= ramp[::-1][None, :]
    alpha = cv2.GaussianBlur(alpha, (0, 0), 1.0)
    inner = ((x1 - X1) / (X2 - X1), (y1 - Y1) / (Y2 - Y1), (x2 - X1) / (X2 - X1),
             (y2 - Y1) / (Y2 - Y1))
    return patch, alpha, inner


def blend(frame, crop, cx, cy):
    """Paste `crop` (vehicle_crop) centred at normalised (cx, cy) into the
    float frame; -> the vehicle's box in the frame (normalised) or None."""
    patch, alpha, inner = crop
    ph, pw = alpha.shape
    x0, y0 = int(cx * W - pw / 2), int(cy * H - ph / 2)
    xa, xb, ya, yb = max(0, x0), min(W, x0 + pw), max(0, y0), min(H, y0 + ph)
    if xb <= xa or yb <= ya:
        return None
    al = alpha[ya - y0:yb - y0, xa - x0:xb - x0][..., None]
    roi = frame[ya:yb, xa:xb]
    roi[:] = roi * (1 - al) + patch[ya - y0:yb - y0, xa - x0:xb - x0] * al
    return ((x0 + inner[0] * pw) / W, (y0 + inner[1] * ph) / H,
            (x0 + inner[2] * pw) / W, (y0 + inner[3] * ph) / H)


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    i = ix * iy
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 0.0
