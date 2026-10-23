"""
photo_facelock.py — d1-photo v2: FACE LOCK ("your face stays yours").

After EVERY AI output that started from a user's photo (HD enhance, old-photo
restore, colorize, deblur, prompt edits from Gemini / OpenAI / Flux …):

  1. find the faces in the ORIGINAL and in the OUTPUT with YuNet
     (OpenCV Zoo face_detection_yunet_2023mar, MIT licence, 230 KB; 5
     landmarks: eyes, nose tip, mouth corners);
  2. per original face, compare the landmark GEOMETRY with the output face at
     the same place: similarity transform (scale + rotation + shift) removed,
     RMS residual in inter-ocular units -> identity score 0..1;
  3. score below the threshold (or the face is gone) -> paste the ORIGINAL face
     back: Poisson seamless blending (OpenCV seamlessClone) after matching
     its light and colour (Lab mean/std) to the output around it.

  2b. IDENTITY: AuraFace-v1 (fal.ai, Apache-2.0, ArcFace-style ResNet-100
     trained on a COMMERCIALLY licensed dataset — its glintr100.onnx sha256
     a7933ea5… is NOT InsightFace's antelopev2 file 4ab1d643…) on the
     112x112 aligned face: cosine similarity original vs output. Geometry
     alone could not tell two different people apart (d1 test: two Congress
     portraits of different men differ by only 0.027 IOD), the embedding can.

Licences: YuNet weights MIT (opencv_zoo LICENSE), AuraFace Apache-2.0,
OpenCV Apache-2.0. NOT used: InsightFace packs (non-commercial) — note the
AuraFace repo ALSO carries byte-identical copies of InsightFace's
scrfd_10g_bnkps / 2d106det / genderage files: those stay unused.

Pure functions (numpy + cv2 only, no Django) so the worker, the eval tool and
tests share them. cv2 / the model missing -> FaceLockUnavailable (callers
decide honestly; never a fake "locked" badge).
"""
import math

THRESHOLD_RMS = 0.085      # inter-ocular units; same face under SR/denoise: 0.01-0.04
SIM_THRESHOLD = 0.60       # AuraFace cosine: same person (other photo) >= ~0.6, different < ~0.3
# ArcFace 112x112 reference landmarks (eyes, nose, mouth corners)
_REF = ((38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366),
        (41.5493, 92.3655), (70.7299, 92.2041))
DETECT_LONG = 1280         # detection runs on a copy at most this big
MIN_SCORE = 0.70


class FaceLockUnavailable(Exception):
    pass


_DET = {}


def _cv2():
    try:
        import cv2
        return cv2
    except Exception:
        raise FaceLockUnavailable("opencv_missing")


def detect(rgb, model_path, min_score=0.75):
    """Faces in an RGB float image (0..1): [{box:[x,y,w,h] px, pts:[[x,y]*5], score}]."""
    import numpy as np
    cv2 = _cv2()
    if not model_path:
        raise FaceLockUnavailable("model_missing")
    h, w = rgb.shape[:2]
    f = min(1.0, DETECT_LONG / max(w, h))
    small = cv2.resize(rgb, (max(1, round(w * f)), max(1, round(h * f))),
                       interpolation=cv2.INTER_AREA) if f < 1 else rgb
    bgr = cv2.cvtColor((np.clip(small, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    key = model_path
    det = _DET.get(key)
    if det is None:
        try:
            det = cv2.FaceDetectorYN.create(model_path, "", (320, 320), min_score, 0.3, 50)
        except Exception as e:
            raise FaceLockUnavailable("detector:%s" % type(e).__name__)
        _DET[key] = det
    det.setScoreThreshold(min_score)
    det.setInputSize((bgr.shape[1], bgr.shape[0]))
    _ok, res = det.detect(bgr)
    out = []
    for r in (res if res is not None else []):
        r = [float(v) / f for v in r[:14]] + [float(r[14])]
        out.append({"box": r[0:4], "pts": [[r[4 + 2 * i], r[5 + 2 * i]] for i in range(5)],
                    "score": r[14]})
    out.sort(key=lambda d: -d["box"][2] * d["box"][3])
    return out


def landmark_rms(a, b):
    """RMS residual (inter-ocular units of `a`) after the best similarity
    transform mapping b onto a. 5x2 point lists."""
    import numpy as np
    A, B = np.asarray(a, float), np.asarray(b, float)
    iod = float(np.linalg.norm(A[0] - A[1]))
    if iod < 1e-6:
        return 9.0
    ca, cb = A.mean(0), B.mean(0)
    A0, B0 = A - ca, B - cb
    nb = float((B0 ** 2).sum())
    if nb < 1e-9:
        return 9.0
    # complex-number closed form of the 2-D similarity Procrustes fit
    za = A0[:, 0] + 1j * A0[:, 1]
    zb = B0[:, 0] + 1j * B0[:, 1]
    s = (np.conj(zb) @ za) / (np.conj(zb) @ zb)
    res = za - s * zb
    return float(math.sqrt(float(np.mean(np.abs(res) ** 2)))) / iod


_EMB = {}


def _embedder(path):
    s = _EMB.get(path)
    if s is None:
        import onnxruntime as ort
        o = ort.SessionOptions()
        o.intra_op_num_threads = 1
        s = ort.InferenceSession(path, o, providers=["CPUExecutionProvider"])
        _EMB[path] = s
    return s


def embed(rgb, face, path):
    """512-d L2-normalised AuraFace embedding of one detected face."""
    import numpy as np
    cv2 = _cv2()
    src = np.asarray(face["pts"], np.float32)
    M, _ = cv2.estimateAffinePartial2D(src, np.asarray(_REF, np.float32), method=cv2.LMEDS)
    if M is None:
        raise FaceLockUnavailable("align")
    crop = cv2.warpAffine((np.clip(rgb, 0, 1) * 255).astype(np.uint8), M, (112, 112),
                          borderValue=0).astype(np.float32)
    x = ((crop - 127.5) / 127.5).transpose(2, 0, 1)[None]
    sess = _embedder(path)
    v = sess.run(None, {sess.get_inputs()[0].name: x})[0][0]
    return v / (np.linalg.norm(v) + 1e-9)


def similarity(a, b):
    import numpy as np
    return float(np.dot(a, b))


def score_of(rms):
    return max(0.0, min(1.0, 1.0 - rms / 0.25))


def _match(face, cands, sx, sy):
    """Output face at the original face's place (centre distance < 0.6 w)."""
    x, y, w, h = face["box"]
    cx, cy = (x + w / 2) * sx, (y + h / 2) * sy
    best, bd = None, 1e9
    for c in cands:
        X, Y, W, H = c["box"]
        d = math.hypot(X + W / 2 - cx, Y + H / 2 - cy)
        if d < bd:
            best, bd = c, d
    if best is None or bd > 0.6 * w * sx:
        return None
    return best


def _colour_match(src, ref):
    """Match `src` (uint8 BGR) to `ref`'s Lab mean/std (light + colour)."""
    import numpy as np
    cv2 = _cv2()
    a = cv2.cvtColor(src, cv2.COLOR_BGR2LAB).astype(np.float32)
    b = cv2.cvtColor(ref, cv2.COLOR_BGR2LAB).astype(np.float32)
    for c in range(3):
        ma, sa = a[..., c].mean(), a[..., c].std() + 1e-3
        mb, sb = b[..., c].mean(), b[..., c].std() + 1e-3
        k = min(1.5, max(0.67, sb / sa))
        a[..., c] = (a[..., c] - ma) * k + mb
    return cv2.cvtColor(np.clip(a, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)


def paste_original_face(orig, out, face, sx, sy, grow=1.45):
    """Seamlessly paste the ORIGINAL face region into `out` (both RGB 0..1)."""
    import numpy as np
    cv2 = _cv2()
    H, W = out.shape[:2]
    x, y, w, h = face["box"]
    cx, cy = x + w / 2, y + h / 2
    rw, rh = w * grow, h * grow * 1.1
    x0, y0 = max(0, int(cx - rw / 2)), max(0, int(cy - rh / 2))
    x1, y1 = min(orig.shape[1], int(cx + rw / 2)), min(orig.shape[0], int(cy + rh / 2))
    if x1 - x0 < 8 or y1 - y0 < 8:
        return out
    crop = orig[y0:y1, x0:x1]
    tw, th = max(8, round((x1 - x0) * sx)), max(8, round((y1 - y0) * sy))
    tx, ty = round(x0 * sx), round(y0 * sy)
    tw, th = min(tw, W - tx - 1), min(th, H - ty - 1)
    if tw < 8 or th < 8:
        return out
    src = cv2.cvtColor((np.clip(cv2.resize(crop, (tw, th), interpolation=cv2.INTER_CUBIC), 0, 1)
                        * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    dst = cv2.cvtColor((np.clip(out, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)
    src = _colour_match(src, dst[ty:ty + th, tx:tx + tw])
    mask = np.zeros((th, tw), np.uint8)
    cv2.ellipse(mask, (tw // 2, th // 2), (max(2, int(tw * 0.42)), max(2, int(th * 0.46))),
                0, 0, 360, 255, -1)
    centre = (tx + tw // 2, ty + th // 2)
    try:
        blended = cv2.seamlessClone(src, dst, mask, centre, cv2.NORMAL_CLONE)
    except Exception:
        # tiny / border faces: feathered alpha paste instead
        m = cv2.GaussianBlur(mask, (0, 0), max(1.0, tw / 20)).astype(np.float32)[..., None] / 255.0
        roi = dst[ty:ty + th, tx:tx + tw].astype(np.float32)
        dst[ty:ty + th, tx:tx + tw] = (src * m + roi * (1 - m)).astype(np.uint8)
        blended = dst
    return cv2.cvtColor(blended, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def face_lock(orig, out, model_path, faces_orig=None, threshold=THRESHOLD_RMS,
              embed_path=None, sim_threshold=SIM_THRESHOLD):
    """Check every original face in `out`; paste it back where identity
    drifted (geometry OR embedding) or the face is gone. Returns (out, report).
    The reported score is the embedding similarity when the embedder is
    installed (`method: "auraface"`), else the geometry score."""
    faces_orig = faces_orig if faces_orig is not None else detect(orig, model_path)
    rep = {"faces": len(faces_orig), "kept": 0, "restored": 0, "min_score": None,
           "action": "no_faces" if not faces_orig else "kept", "scores": [],
           "method": "auraface" if embed_path else "geometry"}
    if not faces_orig:
        return out, rep
    sx = out.shape[1] / orig.shape[1]
    sy = out.shape[0] / orig.shape[0]
    cands = detect(out, model_path, min_score=0.6)
    def measure(face_out, emb0):
        if face_out is None:
            return 0.0, False
        rms = landmark_rms(f["pts"], face_out["pts"])
        if emb0 is not None:
            sim = similarity(emb0, embed(out, face_out, embed_path))
            return sim, (rms <= threshold and sim >= sim_threshold)
        return score_of(rms), rms <= threshold

    for f in faces_orig:
        emb0 = embed(orig, f, embed_path) if embed_path else None
        sc, ok = measure(_match(f, cands, sx, sy), emb0)
        if ok:
            rep["kept"] += 1
        else:
            out = paste_original_face(orig, out, f, sx, sy)
            rep["restored"] += 1
            # re-measure after the paste (honest score of what we deliver)
            sc, _ok = measure(_match(f, detect(out, model_path, min_score=0.6), sx, sy), emb0)
        rep["scores"].append(round(sc, 3))
    rep["min_score"] = min(rep["scores"]) if rep["scores"] else None
    if rep["restored"]:
        rep["action"] = "restored_original_face"
    return out, rep
