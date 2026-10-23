"""
photo_worker.py — d1-photo v2: the Photo Studio WORKER (a separate process).

The API never runs heavy photo work: POST photo-studio/jobs/<id>/run only
checks funding, parks the photo and ENQUEUES a PhotoWorkItem (HTTP 202). The
`assisto-photo-worker` systemd service (deploy/photo_worker/, nice + CPUQuota +
MemoryMax so gunicorn never slows down) runs `manage.py photo_worker`, which
claims items (paid first, then oldest; SKIP LOCKED), executes them and the
FACE LOCK, and finishes the job exactly like the old inline path did:
  * success  -> result + watermarked preview saved, provider cost booked,
                flags.face_lock = {score, action}, status "done";
  * failure  -> funds kept for a retry (max 3 runs), then credits refunded;
  * the phone polls GET photo-studio/jobs/<id> (queue position while waiting).

Free users and paid users share the same open models on our CPU (free = cost 0
to us, just slower); a paid job jumps the queue, and when the owner connects a
GPU key the paid HD enhance runs there ("fast path", up to 4K).

Settings: PHOTO_WORKER (bool, set by deploy/photo_worker/install.sh in the
backend .env) — without it the worker-only features stay hidden and prompt
edits keep the old inline path. PHOTO_WORKER_INLINE (tests only) processes an
item right after enqueueing.
"""
import os
import socket
import time
import uuid

from django.conf import settings
from django.db import transaction
from django.utils import timezone

WORKER_ONLY = ("enhance_server", "colorize", "old_restore", "deblur")
MAX_RUNS = 3


def enabled():
    return bool(getattr(settings, "PHOTO_WORKER", False))


def inline():
    return bool(getattr(settings, "PHOTO_WORKER_INLINE", False))


def should_queue(feature):
    return feature in WORKER_ONLY or enabled()


def _queue_dir():
    d = getattr(settings, "PHOTO_QUEUE_DIR", "") or os.path.join(
        str(settings.MEDIA_ROOT), "photo_studio", "queue")
    os.makedirs(d, exist_ok=True)
    return d


# ------------------------------------------------------------------ API side
def enqueue(job, raw, face_boxes=None, params=None):
    from .models import PhotoWorkItem
    from . import photo_studio_service as S
    name = ""
    if raw:
        name = "%s.bin" % uuid.uuid4().hex
        with open(os.path.join(_queue_dir(), name), "wb") as fh:
            fh.write(raw)
    item, _ = PhotoWorkItem.objects.update_or_create(job=job, defaults={
        "state": "queued", "priority": 0 if S.is_free(job.user) else 10,
        "input_name": name, "face_boxes": face_boxes or [], "params": params or {},
        "claimed_by": "", "claimed_at": None, "finished_at": None, "error": ""})
    job.status = "queued"
    job.save(update_fields=["status"])
    if inline():
        process_item(item)
    return item


def queue_position(job):
    from .models import PhotoWorkItem
    it = PhotoWorkItem.objects.filter(job=job).first()
    if it is None or it.state != "queued":
        return 0
    return PhotoWorkItem.objects.filter(state="queued").filter(
        models_q_ahead(it)).count() + 1


def models_q_ahead(it):
    from django.db.models import Q
    return Q(priority__gt=it.priority) | Q(priority=it.priority, created_at__lt=it.created_at)


# ------------------------------------------------------------------ worker side
def claim(worker_id):
    from .models import PhotoWorkItem
    with transaction.atomic():
        it = (PhotoWorkItem.objects.select_for_update(skip_locked=True)
              .filter(state="queued").order_by("-priority", "created_at").first())
        if it is None:
            return None
        it.state = "running"
        it.claimed_by = worker_id[:40]
        it.claimed_at = timezone.now()
        it.attempts += 1
        it.save(update_fields=["state", "claimed_by", "claimed_at", "attempts"])
    return it


def requeue_stale(minutes=15):
    """A worker that died mid-job leaves 'running' rows: put them back."""
    from .models import PhotoWorkItem
    cut = timezone.now() - timezone.timedelta(minutes=minutes)
    return PhotoWorkItem.objects.filter(state="running", claimed_at__lt=cut).update(
        state="queued", claimed_by="")


def _read_input(item):
    if not item.input_name:
        return b""
    p = os.path.join(_queue_dir(), item.input_name)
    try:
        with open(p, "rb") as fh:
            return fh.read()
    except OSError:
        return b""


def _drop_input(item):
    if item.input_name:
        try:
            os.remove(os.path.join(_queue_dir(), item.input_name))
        except OSError:
            pass


class JobFailed(Exception):
    def __init__(self, code, busy=False):
        super().__init__(code)
        self.code, self.busy = code, busy


def _f32(raw):
    from . import photo_restore as R
    return R._decode(raw)


def _apply_face_lock(raw, out_bytes, report):
    """FACE LOCK on any encoded output. Returns encoded bytes."""
    from . import photo_facelock as FL
    from . import photo_models as PM
    from . import photo_restore as R
    model = PM.server_model("server_face")
    if not raw or not model:
        report["face_lock"] = {"action": "unavailable"}
        return out_bytes
    try:
        orig = _f32(raw)
        out = _f32(out_bytes)
        out, rep = FL.face_lock(orig, out, model, embed_path=PM.server_model("server_face_id"))
    except FL.FaceLockUnavailable as e:
        report["face_lock"] = {"action": "unavailable", "why": str(e)[:40]}
        return out_bytes
    report["face_lock"] = {k: rep[k] for k in ("faces", "kept", "restored", "min_score", "action",
                                               "method")}
    if rep["restored"] or out_bytes[:3] != b"\xff\xd8\xff":
        return R._encode(out)
    return out_bytes


def _execute(job, raw, item):
    """-> (encoded output, cost_usd, report). Raises JobFailed."""
    from . import photo_restore as R
    from . import photo_models as PM
    from . import photo_providers as PP
    from . import photo_studio_service as S
    from .logic import photo_studio as PS
    c = S._cfg()
    table = c["action_costs"].get(PS.FEATURE_ACTION.get(job.feature, "")) or {}
    report = {}
    f = job.feature
    try:
        if f == "enhance_server":
            gpu = R.gpu_enhance_conf() if not S.is_free(job.user) else None
            if gpu:
                out = R.gpu_enhance(raw, gpu)
                cost = R._num(gpu.get("cost_per_run_usd"))
                report["path"] = "gpu"
            else:
                from . import photo_facelock as FL
                rgb = R._decode(raw)
                faces = FL.detect(rgb, PM.server_model("server_face"))
                up = R._session(PM.server_model("upscale"))
                o, info = R.enhance_rgb(rgb, up, faces, "free" if S.is_free(job.user) else "premium")
                out, cost = R._encode(o), 0.0
                report.update(path="cpu", **{k: info[k] for k in ("global_ai", "out_size", "faces")})
        elif f in ("colorize", "old_restore"):
            paths = {r: PM.server_model(r) for r in ("upscale", "server_colorize")}
            out, info = R.process(f, raw, paths, faces=item.face_boxes,
                                  colorize=(job.options or {}).get("restore_colorize", True) is not False)
            cost = float(table.get("provider_cost") or 0)
            report["path"] = "cpu"
        elif f == "deblur":
            out, _info = R.run("deblur", raw, mime=_mime(raw))
            cost = max(R.status("deblur", "en")["cost_usd"], float(table.get("provider_cost") or 0))
            report["path"] = "gpu"
        else:   # cloud prompt edits / generate / enhance_cloud
            slug, conf, prov = S._active_provider(c)
            if not slug:
                raise JobFailed("provider_missing")
            out = PP.run(slug, conf, feature=f, image_bytes=raw, prompt=job.prompt, mime=_mime(raw))
            cost = max(prov, float(table.get("provider_cost") or 0))
            report["path"] = slug
    except R.RestoreBusy as e:
        raise JobFailed(str(e), busy=True)
    except (R.RestoreError, PP.ProviderError) as e:
        raise JobFailed(str(e)[:120])
    except JobFailed:
        raise
    except Exception as e:  # noqa: BLE001 — a short type code, never a path
        raise JobFailed("crash:%s" % type(e).__name__)
    if raw and f != "generate":
        out = _apply_face_lock(raw, out, report)
    return out, cost, report


def _mime(raw):
    return "image/png" if raw[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"


def process_item(item):
    """Run one claimed (or inline) item and finish its job."""
    from . import billing
    from . import photo_studio_service as S
    job = item.job
    raw = _read_input(item)
    if job.feature != "generate" and not raw:
        _fail(item, job, "no_image", busy=False, final=True)
        return
    t0 = time.monotonic()
    job.status = "running"
    job.runs += 1
    job.save(update_fields=["status", "runs"])
    try:
        out, cost_usd, report = _execute(job, raw, item)
    except JobFailed as e:
        _fail(item, job, e.code, busy=e.busy)
        return
    c = S._cfg()
    ext = "png" if out[:8] == b"\x89PNG\r\n\x1a\n" else "jpg"
    job.result_name = S._save_bytes(out, ext)
    prev = S.make_preview(out, S.ps_cfg(c)["preview_max_px"], watermark=S.is_free(job.user))
    if prev:
        job.preview_name = S._save_bytes(prev, "png")
    job.cost_bdt = float(cost_usd) * float(c["usd_bdt"])
    job.status = "done"
    job.done_at = timezone.now()
    job.error = ""
    flags = dict(job.flags or {})
    flags["ai_edited"] = True
    if report.get("face_lock"):
        flags["face_lock"] = report["face_lock"]
    flags["worker_path"] = report.get("path", "")
    job.flags = flags
    job.save()
    if job.cost_bdt:
        billing.record_cost("ai", job.cost_bdt)
    item.state = "done"
    item.finished_at = timezone.now()
    item.ms = int((time.monotonic() - t0) * 1000)
    item.error = ""
    item.save(update_fields=["state", "finished_at", "ms", "error"])
    _drop_input(item)


def _fail(item, job, code, busy=False, final=False):
    from . import photo_studio_service as S
    job.error = str(code)[:200]
    if busy:
        job.runs = max(0, job.runs - 1)          # a busy worker is not the user's attempt
    if final or (not busy and job.runs >= MAX_RUNS):
        job.status = "failed"
        if job.funding in ("credits", "pool") and job.credits_charged:
            S._refund(job.user, job.credits_charged, "photo:refund:%d" % job.pk)
        item.state = "failed"
        _drop_input(item)
    else:
        job.status = "funded"                    # funds kept: the phone may retry
        item.state = "failed"
    job.save(update_fields=["error", "status", "runs"])
    item.error = str(code)[:200]
    item.finished_at = timezone.now()
    item.save(update_fields=["state", "error", "finished_at"])


def loop(once=False, idle_sleep=1.0, stop=lambda: False):
    """The service main loop (manage.py photo_worker)."""
    wid = "%s:%d" % (socket.gethostname(), os.getpid())
    requeue_stale()
    done = 0
    while not stop():
        it = claim(wid)
        if it is None:
            if once:
                break
            time.sleep(idle_sleep)
            continue
        try:
            process_item(it)
        except Exception as e:  # noqa: BLE001 — never kill the loop on one job
            _fail(it, it.job, "crash:%s" % type(e).__name__)
        done += 1
        if once:
            break
    return done

