"""p2-photo: the on-device Photo Studio AI model (Real-ESRGAN restore/upscale).

The phone downloads the model ONCE on first use, from OUR server, then works
offline. Files + manifest.json live in core/photo_models/ (override:
settings.PHOTO_MODEL_DIR). They are produced by
tools/photo_model/convert_realesrgan.py (numpy + onnx only; a few seconds).

manifest.json = {"version": "2026.10.1", "kind": "upscale",
  "model": "realesr-general-x4v3", "licence": "...", "licence_cleared": true,
  "scale": 4, "tile": 144, "pad": 8,
  "files": [{"role": "upscale", "name": "x.onnx", "sha256": "…", "size": n}]}

Rules:
  * nothing is ever served unless the manifest says licence_cleared = true
    (see .phaseB/MODEL_LICENSES.md) AND every listed file exists with the
    listed size;
  * only names listed in the manifest can be fetched (no path traversal);
  * HTTP Range (single range, RFC 9110) so an interrupted download resumes;
    ETag = the file's sha256 so If-Range never mixes two model versions.
"""
import json
import os
import re

from django.conf import settings
from django.http import Http404, HttpResponse, StreamingHttpResponse

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,80}\.onnx$")
_SHA_RE = re.compile(r"^[0-9a-f]{64}$")
_RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")
FILE_ROUTE = "/api/v1/photo-studio/model/"


def model_dir():
    return str(getattr(settings, "PHOTO_MODEL_DIR", "") or
               os.path.join(os.path.dirname(os.path.abspath(__file__)), "photo_models"))


def _int(v, default, lo, hi):
    try:
        return min(hi, max(lo, int(v)))
    except (TypeError, ValueError):
        return default


def load_manifest():
    """The installed manifest, validated; None when absent or invalid."""
    d = model_dir()
    try:
        with open(os.path.join(d, "manifest.json"), encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(m, dict) or m.get("kind") != "upscale":
        return None
    files = m.get("files")
    if not isinstance(files, list) or not files:
        return None
    out = []
    for e in files:
        if not isinstance(e, dict):
            return None
        name, sha = str(e.get("name", "")), str(e.get("sha256", "")).lower()
        if e.get("role") != "upscale" or not _NAME_RE.match(name) or not _SHA_RE.match(sha):
            return None
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            return None
        size = os.path.getsize(p)
        if int(e.get("size") or size) != size:
            return None
        out.append({"role": "upscale", "name": name, "sha256": sha, "size": size})
    return {
        "version": str(m.get("version") or ""),
        "model": str(m.get("model") or ""),
        "licence": str(m.get("licence") or ""),
        "licence_cleared": m.get("licence_cleared") is True,
        "scale": _int(m.get("scale"), 4, 1, 8),
        "tile": _int(m.get("tile"), 144, 16, 1024),
        "pad": _int(m.get("pad"), 8, 0, 64),
        "files": out,
    }


def client_manifest(request=None):
    """What the app needs to download + run the model (or why it can't)."""
    m = load_manifest()
    if not m:
        return {"available": False, "reason": "model_pending", "files": [], "version": ""}
    if not m["licence_cleared"]:
        return {"available": False, "reason": "licence_pending", "files": [],
                "version": m["version"]}
    files = []
    for e in m["files"]:
        path = FILE_ROUTE + e["name"]
        files.append({**e, "url": request.build_absolute_uri(path) if request is not None else path})
    return {"available": True, "reason": "", "version": m["version"], "model": m["model"],
            "licence": m["licence"], "scale": m["scale"], "tile": m["tile"], "pad": m["pad"],
            "files": files}


def _iter_range(path, start, length, chunk=64 * 1024):
    with open(path, "rb") as f:
        f.seek(start)
        left = length
        while left > 0:
            b = f.read(min(chunk, left))
            if not b:
                break
            left -= len(b)
            yield b


def parse_range(header, size):
    """-> (start, end) inclusive, None (serve whole file) or 'unsatisfiable'."""
    if not header:
        return None
    mt = _RANGE_RE.match(header.strip())
    if not mt:  # multi-range or another unit: serve the whole file (RFC allows)
        return None
    a, b = mt.group(1), mt.group(2)
    if a == "" and b == "":
        return None
    if a == "":  # suffix: last N bytes
        n = int(b)
        if n == 0:
            return "unsatisfiable"
        return (max(0, size - n), size - 1)
    start = int(a)
    end = size - 1 if b == "" else min(size - 1, int(b))
    if start >= size or end < start:
        return "unsatisfiable"
    return (start, end)


def serve_file(request, name):
    m = load_manifest()
    if not m or not m["licence_cleared"]:
        raise Http404
    entry = next((e for e in m["files"] if e["name"] == name), None)
    if entry is None:
        raise Http404
    path = os.path.join(model_dir(), name)
    size = entry["size"]
    etag = '"%s"' % entry["sha256"]
    rng = parse_range(request.META.get("HTTP_RANGE", ""), size)
    if_range = request.META.get("HTTP_IF_RANGE", "")
    if rng is not None and if_range and if_range.strip() != etag:
        rng = None  # a different version: start over with the whole file
    if rng == "unsatisfiable":
        resp = HttpResponse(status=416)
        resp["Content-Range"] = "bytes */%d" % size
    elif rng is None:
        resp = StreamingHttpResponse(_iter_range(path, 0, size),
                                     content_type="application/octet-stream")
        resp["Content-Length"] = str(size)
    else:
        start, end = rng
        resp = StreamingHttpResponse(_iter_range(path, start, end - start + 1),
                                     content_type="application/octet-stream", status=206)
        resp["Content-Length"] = str(end - start + 1)
        resp["Content-Range"] = "bytes %d-%d/%d" % (start, end, size)
    resp["Accept-Ranges"] = "bytes"
    resp["ETag"] = etag
    resp["Cache-Control"] = "public, max-age=86400"
    return resp
