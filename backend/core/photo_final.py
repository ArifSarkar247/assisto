"""
photo_final.py — Photo Studio FINAL (owner order 24 Oct 2026, "beat Remini
without losing money"): the server-side PROVIDER SWITCH for HD enhance and
Ultra HD, the result cache, the global daily spend cap, the per-image
provider log, the free-enhance counters per account AND device, and the
improved local pipeline (core/photo_look.py).

The phone NEVER calls an AI provider: it uploads to our Django server, the
photo worker (deploy/photo_worker) picks the provider from server config:

  provider            integration slug          what runs there
  local_worker        (none — our CPU, cost 0)  YuNet faces -> Real-ESRGAN face
                                                detail -> skin/tone/bg-blur look
  replicate           photo_enhance_replicate   Real-ESRGAN x2 (nightmareai) +
                                                OPTIONAL GFPGAN v1.4 (legal switch
                                                `face_restore_gfpgan`, OFF) + look
  runpod_serverless   photo_runpod              any handler with our contract
                                                (tools/photo_train/serve_handler.py)
  assisto_face        photo_assisto_face        our own fine-tuned model (Phase 2),
                                                same RunPod contract
  ultra (fal.ai)      photo_fal                 Ultra HD upscaler (Premium only)

Keys only from Owner Admin → Integrations (encrypted DB) — never git/env in
the repo. Every HTTP call goes through `_http()` (mocked in tests).
Every remote image must be https, must decode, and goes through FACE LOCK
(photo_worker) before anyone sees it.
"""
import base64
import hashlib
import io
import json
import os
import time
from datetime import datetime, time as dtime, timedelta

from django.utils import timezone

from .logic import photo_final as PF

SLUGS = {"replicate": "photo_enhance_replicate", "runpod_serverless": "photo_runpod",
         "assisto_face": "photo_assisto_face"}
ULTRA_SLUG = "photo_fal"
DEFAULT_ULTRA_MODEL = "fal-ai/crystal-upscaler"
DATA_URI_MAX = 256 * 1024       # Replicate: bigger inputs go through the Files API
POLL_EVERY_S = 1.5
SMALL_PHOTO_PX = 400 * 400      # <= this gets the whole-image Real-ESRGAN on our CPU (~10 tiles)


class ProviderFailed(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = str(code)[:100]


class SpendCapWait(Exception):
    """Today's paid-provider budget is used: the job waits until `until`."""
    def __init__(self, until):
        super().__init__("spend_cap")
        self.until = until


def _http():
    import requests
    return requests


def _num(v):
    try:
        return max(0.0, float(v or 0))
    except (TypeError, ValueError):
        return 0.0


def _ps():
    from . import photo_studio_service as S
    return S.ps_cfg()


# ------------------------------------------------------------------ provider config
def _integration(slug):
    from . import integrations
    try:
        if not integrations.is_enabled(slug):
            return None
        return integrations.get(slug) or {}
    except Exception:
        return None


def provider_conf(name):
    """Normalised config of a PAID provider, or None when not usable (no key,
    no model/endpoint, or no cost estimate — we never run what we can't price)."""
    slug = SLUGS.get(name)
    c = _integration(slug) if slug else None
    if not c:
        return None
    est = _num(c.get("cost_per_image_usd"))
    if est <= 0:
        return None
    if name == "replicate":
        if not (c.get("api_token") and c.get("upscale_version")):
            return None
        return {"name": name, "token": c["api_token"], "upscale_version": c["upscale_version"].strip(),
                "face_version": str(c.get("face_version") or "").strip(),
                "usd_per_s": _num(c.get("usd_per_second")), "est": est,
                "version": c["upscale_version"].strip()[:40]}
    if not (c.get("api_key") and c.get("endpoint_id")):
        return None
    return {"name": name, "token": c["api_key"], "endpoint": str(c["endpoint_id"]).strip(),
            "usd_per_s": _num(c.get("usd_per_second")), "est": est,
            "version": str(c.get("model_version") or c["endpoint_id"]).strip()[:40]}


def configured():
    return {n for n in PF.PAID_PROVIDERS if provider_conf(n)}


def ultra_conf():
    c = _integration(ULTRA_SLUG)
    if not c or not c.get("api_key"):
        return None
    per_mp = _num(c.get("usd_per_megapixel"))
    flat = _num(c.get("cost_per_image_usd"))
    if per_mp <= 0 and flat <= 0:
        return None
    return {"token": c["api_key"], "model": str(c.get("model") or DEFAULT_ULTRA_MODEL).strip(),
            "usd_per_mp": per_mp, "flat": flat,
            "scale": int(_num(c.get("scale")) or 2), "in_mp": _num(c.get("input_mp")) or 1.0}


def ultra_cost_usd(conf):
    """Worst-case price of one Ultra HD image: output MP x price (input capped
    at `in_mp`, x scale^2), or the flat per-image price — whichever is higher."""
    if not conf:
        return 0.0
    out_mp = conf["in_mp"] * conf["scale"] ** 2
    return round(max(conf["flat"], out_mp * conf["usd_per_mp"]), 6)


# ------------------------------------------------------------------ device + usage
def device_key(raw_id):
    v = str(raw_id or "").strip()
    if len(v) < 8:
        return ""
    return hashlib.sha256(("assisto-photo-dev:" + v).encode()).hexdigest()[:64]


def _gift_q(user, dkey):
    from django.db.models import Q
    from .models import PhotoStudioJob
    q = Q(user=user)
    if dkey:
        q |= Q(device_key=dkey)
    return (PhotoStudioJob.objects.filter(q, feature="enhance_server", funding="gift")
            .exclude(status__in=("refused", "expired", "failed")))


def enhance_usage(user, dkey=""):
    """Counters for logic.photo_studio.free_enhance_options — per account OR
    device (a reinstall / second account on the same phone sees the same)."""
    from django.db.models import Q
    from .models import PhotoStudioJob
    from . import photo_studio_service as S
    g = _gift_q(user, dkey)
    week_ago = timezone.now() - timedelta(days=7)
    q = Q(user=user)
    if dkey:
        q |= Q(device_key=dkey)
    today = (PhotoStudioJob.objects.filter(q, feature="enhance_server",
                                           created_at__date=timezone.localdate())
             .exclude(status__in=("refused", "expired")).count())
    return {"lifetime_free": g.filter(flags__free_kind="lifetime").count(),
            "week_free": g.filter(flags__free_kind="week", created_at__gte=week_ago).count(),
            "enhance_today": today,
            "ads_live": bool(S._ad_units().get("_configured"))}


def _month_start():
    now = timezone.localtime()
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def ultra_quota_for(user, conf=None):
    from . import billing, photo_studio_service as S
    conf = conf if conf is not None else ultra_conf()
    plan = S.plan_of(user)
    if plan == "free" or not conf:
        return 0
    c = billing.cfg()
    row = (c.get("plans") or {}).get(plan) or {}
    net = PF.plan_net_bdt(row.get("price", 0), c.get("play_fee", 0.15), c.get("vat", 0.0),
                          c.get("gateway_fee", 0.0))
    return PF.ultra_quota(plan_net_bdt_=net, budget_pct=S.ps_cfg(c)["ultra_hd_budget_pct"],
                          cost_usd=ultra_cost_usd(conf), usd_bdt=c["usd_bdt"])


def ultra_usage(user):
    from .models import PhotoStudioJob
    used = (PhotoStudioJob.objects.filter(user=user, feature="ultra_hd",
                                          created_at__gte=_month_start())
            .exclude(status__in=("refused", "expired", "failed")).count())
    return {"ultra_month": used, "ultra_quota": ultra_quota_for(user)}


# ------------------------------------------------------------------ spend + log
def spent_today_usd():
    from django.db.models import Sum
    from .models import PhotoProviderRun
    v = PhotoProviderRun.objects.filter(created_at__date=timezone.localdate()).aggregate(
        s=Sum("cost_usd"))["s"]
    return float(v or 0.0)


def _next_midnight():
    tz = timezone.get_current_timezone()
    d = timezone.localdate() + timedelta(days=1)
    return timezone.make_aware(datetime.combine(d, dtime(0, 0, 5)), tz)


def _log(job, provider, *, ok, cost=0.0, seconds=0.0, cache_hit=False, key="", result="",
         error="", fallback_from="", version="", preset="", steps=None):
    from .models import PhotoProviderRun
    return PhotoProviderRun.objects.create(
        job=job, user=getattr(job, "user", None), feature=getattr(job, "feature", ""),
        provider=provider, model_version=str(version)[:120], preset=preset, ok=ok,
        cache_hit=cache_hit, fallback_from=fallback_from, cost_usd=float(cost or 0),
        seconds=round(float(seconds or 0), 2), cache_key=key, result_name=result,
        error=str(error)[:120], steps=steps or {})


def _cached(key):
    from .models import PhotoProviderRun
    from . import photo_studio_service as S
    for r in PhotoProviderRun.objects.filter(cache_key=key, ok=True).exclude(result_name="")[:3]:
        try:
            with open(S._media_path(r.result_name), "rb") as fh:
                return fh.read(), r
        except OSError:
            continue
    return None, None


def provider_log(limit=50):
    from .models import PhotoProviderRun
    return PhotoProviderRun.objects.select_related("user").order_by("-created_at")[:limit]


def provider_summary(days=7):
    from django.db.models import Avg, Count, Sum
    from .models import PhotoProviderRun
    since = timezone.now() - timedelta(days=days)
    rows = (PhotoProviderRun.objects.filter(created_at__gte=since).values("provider")
            .annotate(n=Count("id"), cost=Sum("cost_usd"), sec=Avg("seconds")))
    hits = dict(PhotoProviderRun.objects.filter(created_at__gte=since, cache_hit=True)
                .values_list("provider").annotate(n=Count("id")))
    fails = dict(PhotoProviderRun.objects.filter(created_at__gte=since, ok=False)
                 .values_list("provider").annotate(n=Count("id")))
    return [{"provider": r["provider"], "runs": r["n"], "cost_usd": round(r["cost"] or 0, 4),
             "avg_s": round(r["sec"] or 0, 1), "cache_hits": hits.get(r["provider"], 0),
             "failed": fails.get(r["provider"], 0)} for r in rows]


# ------------------------------------------------------------------ capability (app)
def capability(user, lang="bn"):
    """What REALLY works right now — the app shows only this (no dead button)."""
    from . import photo_studio_service as S
    ps = _ps()
    conf_u = ultra_conf()
    paid = configured()
    return {
        "presets": list(PF.PRESETS),
        "providers": sorted(paid),          # paid providers connected (names only)
        "face_restore": bool("replicate" in paid and ps["face_restore_gfpgan"]
                             and (provider_conf("replicate") or {}).get("face_version")),
        "bg_blur": _local_models_ok(("segment",)),
        "face_lock": _local_models_ok(("server_face",)),
        "ultra_hd": {"available": bool(conf_u), "premium_only": True,
                     "quota": ultra_quota_for(user, conf_u) if conf_u and not S.is_free(user) else 0},
    }


def _local_models_ok(roles):
    from . import photo_models as PM
    try:
        return all(PM.server_model(r) for r in roles)
    except Exception:
        return False


# ------------------------------------------------------------------ local pipeline
def _fit_mp(rgb, max_mp):
    from . import photo_restore as R
    h, w = rgb.shape[:2]
    tw, th = PF.fit_mp(w, h, max_mp)
    return rgb if (tw, th) == (w, h) else R._resize(rgb, tw, th)


def local_enhance(raw, *, preset="natural", blur=False, max_mp=2, paths=None, session=None,
                  faces=None):
    """Our free CPU pipeline: <= 2 MP -> YuNet faces -> small-photo Real-ESRGAN
    (existing enhance_rgb) -> face detail + skin + tone + optional bg blur.
    Returns (jpeg bytes, steps)."""
    from . import photo_facelock as FL
    from . import photo_look as LK
    from . import photo_models as PM
    from . import photo_restore as R
    paths = paths or {r: PM.server_model(r) for r in ("upscale", "server_face", "segment")}
    session = session or R._session
    t0 = time.monotonic()
    rgb = _fit_mp(R._decode(raw), max_mp)
    if faces is None:
        faces = FL.detect(rgb, paths.get("server_face")) if paths.get("server_face") else []
    up = session(paths["upscale"]) if paths.get("upscale") else None
    steps = {"in": [int(rgb.shape[1]), int(rgb.shape[0])], "faces": len(faces)}
    out = rgb
    steps["global_ai"] = False
    if up is not None and rgb.shape[0] * rgb.shape[1] <= SMALL_PHOTO_PX:
        # small / old photos get real pixels (Real-ESRGAN x4 -> <= max_mp);
        # bigger ones keep their own pixels (CPU budget) — faces still get
        # the Real-ESRGAN face pass in the look stage
        ai = R.upscale_x4(rgb, up)
        out = _fit_mp(ai, max_mp)
        k = out.shape[1] / rgb.shape[1]
        faces = [{**f, "box": [v * k for v in f["box"]],
                  "pts": [[px * k, py * k] for px, py in f.get("pts") or []]} for f in faces]
        steps["global_ai"] = True
    seg = session(paths["segment"]) if (blur and paths.get("segment")) else None
    out, rep = LK.apply(out, faces, preset=preset, up_sess=up, seg_sess=seg, blur=blur,
                        upscale_x4=R.upscale_x4 if up is not None else None)
    steps.update(rep)
    steps["out"] = [int(out.shape[1]), int(out.shape[0])]
    steps["ms"] = int((time.monotonic() - t0) * 1000)
    return R._encode(out), steps


# ------------------------------------------------------------------ remote helpers
def _get_image(url, timeout):
    if not isinstance(url, str) or not url.startswith("https://"):
        raise ProviderFailed("no_image_url")
    g = _http().get(url, timeout=timeout)
    if g.status_code != 200 or not g.content:
        raise ProviderFailed("download_%d" % g.status_code)
    from . import photo_restore as R
    try:
        R._decode(g.content)        # never trust a remote image blindly
    except R.RestoreError:
        raise ProviderFailed("bad_image")
    return g.content


def _replicate_input(token, raw, timeout):
    if len(raw) <= DATA_URI_MAX:
        return "data:image/jpeg;base64," + base64.b64encode(raw).decode()
    r = _http().post("https://api.replicate.com/v1/files", timeout=timeout,
                     headers={"Authorization": "Bearer %s" % token},
                     files={"content": ("photo.jpg", raw, "image/jpeg")})
    if r.status_code not in (200, 201):
        raise ProviderFailed("files_http_%d" % r.status_code)
    url = ((r.json() or {}).get("urls") or {}).get("get")
    if not url:
        raise ProviderFailed("files_no_url")
    return url


def _replicate_predict(token, version, inp, timeout):
    """-> (output url, billed seconds). Waits up to 60 s in the POST, then polls."""
    rq = _http()
    hdr = {"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}
    r = rq.post("https://api.replicate.com/v1/predictions", timeout=timeout,
                headers={**hdr, "Prefer": "wait=60"},
                data=json.dumps({"version": version, "input": inp}))
    if r.status_code not in (200, 201):
        raise ProviderFailed("http_%d" % r.status_code)
    j = r.json() or {}
    t_end = time.monotonic() + timeout
    while j.get("status") in ("starting", "processing"):
        if time.monotonic() > t_end:
            raise ProviderFailed("timeout")
        time.sleep(POLL_EVERY_S)
        url = (j.get("urls") or {}).get("get")
        if not url:
            raise ProviderFailed("no_poll_url")
        g = rq.get(url, timeout=timeout, headers=hdr)
        if g.status_code != 200:
            raise ProviderFailed("poll_http_%d" % g.status_code)
        j = g.json() or {}
    if j.get("status") != "succeeded":
        raise ProviderFailed("status_%s" % (j.get("status") or "unknown"))
    out = j.get("output")
    if isinstance(out, list):
        out = out[0] if out else None
    sec = _num((j.get("metrics") or {}).get("predict_time"))
    return out, sec


def _blend_faces(base_rgb, face_rgb, faces, weight):
    """Fidelity blend: restored face pixels at `weight` inside soft ellipses."""
    import numpy as np
    from . import photo_look as LK
    from . import photo_restore as R
    if face_rgb.shape[:2] != base_rgb.shape[:2]:
        face_rgb = R._resize(face_rgb, base_rgb.shape[1], base_rgb.shape[0])
    m = LK.face_ellipses(base_rgb.shape, faces, grow=1.05)[..., None] * float(weight)
    return np.clip(base_rgb * (1 - m) + face_rgb * m, 0, 1).astype(np.float32)


def _run_replicate(conf, raw, *, preset, blur, ps, timeout):
    from . import photo_facelock as FL
    from . import photo_look as LK
    from . import photo_models as PM
    from . import photo_restore as R
    rgb = _fit_mp(R._decode(raw), ps["max_input_mp"])
    src = R._encode(rgb)
    inp_url = _replicate_input(conf["token"], src, timeout)
    secs = 0.0
    url, s = _replicate_predict(conf["token"], conf["upscale_version"],
                                {"image": inp_url, "scale": 2, "face_enhance": False}, timeout)
    secs += s
    up = R._decode(_get_image(url, timeout))
    steps = {"upscale": "real-esrgan x2", "face_restore": "off"}
    faces = []
    det = PM.server_model("server_face")
    if det:
        try:
            faces = FL.detect(up, det)
        except FL.FaceLockUnavailable:
            faces = []
    if faces and ps["face_restore_gfpgan"] and conf.get("face_version"):
        url, s = _replicate_predict(conf["token"], conf["face_version"],
                                    {"img": inp_url, "version": "v1.4", "scale": 2}, timeout)
        secs += s
        fr = R._decode(_get_image(url, timeout))
        w = ps["face_blend_strong_pct" if preset == "strong" else "face_blend_natural_pct"] / 100.0
        up = _blend_faces(up, fr, faces, w)
        steps["face_restore"] = "gfpgan v1.4 blend %d%%" % round(w * 100)
    seg = R._session(PM.server_model("segment")) if (blur and PM.server_model("segment")) else None
    out, rep = LK.apply(up, faces, preset=preset, seg_sess=seg, blur=blur, crisp=False)
    steps.update(rep)
    cost = PF.run_cost_usd(seconds=secs, usd_per_second=conf["usd_per_s"],
                           flat_usd=0.0 if conf["usd_per_s"] > 0 else conf["est"])
    return R._encode(out), cost, secs, steps


def _run_runpod(conf, raw, *, preset, blur, ps, timeout):
    """RunPod Serverless (per-second, scales to zero) — runsync, then poll."""
    from . import photo_restore as R
    rq = _http()
    rgb = _fit_mp(R._decode(raw), ps["max_input_mp"])
    body = {"input": {"image_b64": base64.b64encode(R._encode(rgb)).decode(),
                      "preset": preset, "bg_blur": bool(blur),
                      "face_blend": ps["face_blend_strong_pct" if preset == "strong"
                                       else "face_blend_natural_pct"] / 100.0}}
    hdr = {"Authorization": "Bearer %s" % conf["token"], "Content-Type": "application/json"}
    base = "https://api.runpod.ai/v2/%s" % conf["endpoint"]
    r = rq.post(base + "/runsync", timeout=timeout, headers=hdr, data=json.dumps(body))
    if r.status_code != 200:
        raise ProviderFailed("http_%d" % r.status_code)
    j = r.json() or {}
    t_end = time.monotonic() + timeout
    while j.get("status") in ("IN_QUEUE", "IN_PROGRESS"):
        if time.monotonic() > t_end:
            try:
                rq.post(base + "/cancel/%s" % j.get("id", ""), timeout=10, headers=hdr)
            except Exception:  # noqa: BLE001
                pass
            raise ProviderFailed("timeout")
        time.sleep(POLL_EVERY_S)
        g = rq.get(base + "/status/%s" % j.get("id", ""), timeout=timeout, headers=hdr)
        if g.status_code != 200:
            raise ProviderFailed("poll_http_%d" % g.status_code)
        j = g.json() or {}
    if j.get("status") != "COMPLETED":
        raise ProviderFailed("status_%s" % (j.get("status") or "unknown"))
    b64 = ((j.get("output") or {}).get("image_b64") or "")
    try:
        out = base64.b64decode(b64)
        R._decode(out)
    except Exception:
        raise ProviderFailed("bad_image")
    secs = _num(j.get("executionTime")) / 1000.0
    cost = PF.run_cost_usd(seconds=secs, usd_per_second=conf["usd_per_s"],
                           flat_usd=0.0 if conf["usd_per_s"] > 0 else conf["est"])
    return out, cost, secs, {"remote": conf["name"], "steps": (j.get("output") or {}).get("steps")}


_RUNNERS = {"replicate": _run_replicate, "runpod_serverless": _run_runpod,
            "assisto_face": _run_runpod}


# ------------------------------------------------------------------ enhance entry
def run_enhance(job, raw, item=None):
    """HD enhance on the provider picked for this user, with cache, spend cap,
    fallback and the per-image log. -> (bytes, cost_usd, report)."""
    ps = _ps()
    opts = job.options or {}
    preset = PF.preset_of(opts.get("strength"))
    blur = bool(opts.get("bg_blur"))
    timeout = ps["provider_timeout_s"]
    first = PF.pick_provider(job.user_id, ps, configured())
    photo_hash = hashlib.sha256(raw).hexdigest()
    extra = "blur" if blur else ""
    fallback_from = ""
    for prov in PF.chain(first):
        conf = provider_conf(prov) if prov != PF.LOCAL else None
        if prov != PF.LOCAL and conf is None:
            fallback_from = prov
            continue
        version = conf["version"] if conf else "local-2026.10"
        if prov == "replicate" and conf and ps["face_restore_gfpgan"] and conf.get("face_version"):
            version += "+gfpgan"
        key = PF.cache_key(photo_hash, preset, prov, version, extra)
        hit, _row = _cached(key)
        if hit:
            _log(job, prov, ok=True, cache_hit=True, key=key, version=version, preset=preset,
                 fallback_from=fallback_from)
            return hit, 0.0, {"path": prov, "cache_hit": True, "preset": preset}
        if conf is not None:
            if not PF.cap_allows(spent_today_usd(), conf["est"], ps["daily_spend_cap_usd"]):
                if not ps["cap_fallback_local"]:
                    raise SpendCapWait(_next_midnight())
                fallback_from = prov
                _log(job, prov, ok=False, error="spend_cap", version=version, preset=preset)
                continue
        t0 = time.monotonic()
        try:
            if prov == PF.LOCAL:
                out, steps = local_enhance(raw, preset=preset, blur=blur, max_mp=ps["max_input_mp"])
                cost, secs = 0.0, (time.monotonic() - t0)
            else:
                out, cost, _billed, steps = _RUNNERS[prov](conf, raw, preset=preset, blur=blur,
                                                           ps=ps, timeout=timeout)
                secs = time.monotonic() - t0
        except Exception as e:  # noqa: BLE001 — any provider error -> previous provider
            code = e.code if isinstance(e, ProviderFailed) else "crash:%s" % type(e).__name__
            _log(job, prov, ok=False, seconds=time.monotonic() - t0, error=code,
                 version=version, preset=preset, fallback_from=fallback_from)
            if prov == PF.LOCAL:
                raise ProviderFailed(code)
            fallback_from = prov
            continue
        from . import photo_studio_service as S
        name = S._save_bytes(out, "jpg")
        _log(job, prov, ok=True, cost=cost, seconds=secs, key=key, result=name,
             version=version, preset=preset, fallback_from=fallback_from, steps=_small(steps))
        return out, cost, {"path": prov, "preset": preset, "fallback_from": fallback_from,
                           "steps": _small(steps)}
    raise ProviderFailed("no_provider")


def _small(d):
    try:
        s = json.dumps(d, default=str)
        return json.loads(s) if len(s) < 2000 else {"truncated": True}
    except Exception:
        return {}


# ------------------------------------------------------------------ ultra entry
def run_ultra(job, raw):
    """Ultra HD on fal.ai (Premium; quota checked at funding). -> (bytes, cost, report)."""
    from . import photo_restore as R
    from . import photo_studio_service as S
    ps = _ps()
    conf = ultra_conf()
    if not conf:
        raise ProviderFailed("provider_missing")
    est = ultra_cost_usd(conf)
    rgb = _fit_mp(R._decode(raw), conf["in_mp"])
    src = R._encode(rgb)
    key = PF.cache_key(hashlib.sha256(raw).hexdigest(), "ultra", "fal", conf["model"],
                       "x%d" % conf["scale"])
    hit, _row = _cached(key)
    if hit:
        _log(job, "fal", ok=True, cache_hit=True, key=key, version=conf["model"], preset="ultra")
        return hit, 0.0, {"path": "fal", "cache_hit": True}
    if not PF.cap_allows(spent_today_usd(), est, ps["daily_spend_cap_usd"]):
        raise SpendCapWait(_next_midnight())
    t0 = time.monotonic()
    try:
        r = _http().post("https://fal.run/%s" % conf["model"], timeout=ps["provider_timeout_s"],
                         headers={"Authorization": "Key %s" % conf["token"],
                                  "Content-Type": "application/json"},
                         data=json.dumps({"image_url": "data:image/jpeg;base64,"
                                          + base64.b64encode(src).decode(),
                                          "scale_factor": conf["scale"]}))
        if r.status_code != 200:
            raise ProviderFailed("http_%d" % r.status_code)
        j = r.json() or {}
        img = j.get("image") or ((j.get("images") or [None])[0]) or {}
        out = _get_image(img.get("url") if isinstance(img, dict) else None, ps["provider_timeout_s"])
    except Exception as e:  # noqa: BLE001
        code = e.code if isinstance(e, ProviderFailed) else "crash:%s" % type(e).__name__
        _log(job, "fal", ok=False, seconds=time.monotonic() - t0, error=code,
             version=conf["model"], preset="ultra")
        raise ProviderFailed(code)
    from PIL import Image
    w, h = Image.open(io.BytesIO(out)).size        # real size (no decode cap)
    mp = w * h / 1e6
    cost = round(max(conf["flat"], mp * conf["usd_per_mp"]), 6)
    name = S._save_bytes(out, "jpg")
    _log(job, "fal", ok=True, cost=cost, seconds=time.monotonic() - t0, key=key, result=name,
         version=conf["model"], preset="ultra", steps={"out_mp": round(mp, 2)})
    return out, cost, {"path": "fal", "out_mp": round(mp, 2)}
