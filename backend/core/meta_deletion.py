"""
meta_deletion.py — bizauto: Meta's "Data Deletion Request Callback" (required
for App Review of pages_messaging / instagram_manage_comments / ...).

Meta POSTs `signed_request=<b64url sig>.<b64url json>` (HMAC-SHA256 with the
app secret, Owner Admin -> Integrations -> meta_app). We delete what Assisto
holds about that Meta user — every chat / comment thread with that id (and
its messages, by cascade) — and answer {url, confirmation_code}; the url is
a public status page Meta shows the person.

Kept on purpose: a STOP (BizOptOut "psid:<id>") — deleting it would let a
business message the person again; it holds only the opaque id.

    POST bizagent/meta/data-deletion          (public; signature = auth)
    GET  bizagent/meta/data-deletion/status?code=...
"""
import base64
import hashlib
import hmac
import json
import logging

from django.conf import settings
from django.http import HttpResponse, JsonResponse
from django.utils.html import escape
from django.views.decorators.csrf import csrf_exempt

log = logging.getLogger("assisto.meta_deletion")
MAX_BODY = 8192


def _b64d(s):
    s = str(s or "")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def parse_signed_request(signed, secret):
    """The payload dict when the signature is valid, else None. Pure."""
    if not signed or not secret or "." not in str(signed):
        return None
    sig_b64, body_b64 = str(signed).split(".", 1)
    try:
        sig = _b64d(sig_b64)
        data = json.loads(_b64d(body_b64).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, TypeError):
        return None
    if not isinstance(data, dict) or str(data.get("algorithm", "")).upper() != "HMAC-SHA256":
        return None
    want = hmac.new(secret.encode(), body_b64.encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(sig, want):
        return None
    return data


def make_signed_request(payload, secret):
    """The inverse (tests + the owner's self-check)."""
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
    sig = hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(sig).decode().rstrip("=") + "." + body


def confirmation_code(user_id, issued_at):
    k = (settings.SECRET_KEY + ":meta-deletion").encode()
    return "del-" + hmac.new(k, ("%s|%s" % (user_id, issued_at)).encode(),
                             hashlib.sha256).hexdigest()[:12]


def delete_for(user_id):
    """Delete every chat / comment thread of this Meta user. Returns counts."""
    from .models import ChatThread
    uid = str(user_id or "").strip()
    if not uid:
        return {"threads": 0}
    qs = ChatThread.objects.filter(external_user_id__in=[uid, "comment:" + uid])
    n = qs.count()
    qs.delete()
    return {"threads": n}


def _status_url(request, code):
    base = (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/")
    return "%s/api/v1/bizagent/meta/data-deletion/status?code=%s" % (base, code)


@csrf_exempt
def data_deletion(request):
    if request.method != "POST":
        return HttpResponse(status=405)
    if len(request.body or b"") > MAX_BODY:
        return HttpResponse("too large", status=413)
    from . import bizagent_service as S
    secret = (S.meta_app() or {}).get("app_secret") or ""
    data = parse_signed_request(request.POST.get("signed_request"), secret)
    if data is None:
        return JsonResponse({"error": "bad_signed_request"}, status=400)
    uid = str(data.get("user_id") or "")
    res = delete_for(uid)
    code = confirmation_code(uid, data.get("issued_at", ""))
    log.info("meta data deletion: %s threads (code %s)", res["threads"], code)
    return JsonResponse({"url": _status_url(request, code), "confirmation_code": code})


_PAGE = ("<!doctype html><html lang=\"bn\"><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
         "<title>Assisto</title><style>body{font-family:system-ui,sans-serif;max-width:34rem;"
         "margin:2rem auto;padding:0 1rem;line-height:1.6}</style></head><body>"
         "<h1>ডেটা মুছে ফেলা হয়েছে / Data deleted</h1>"
         "<p>অনুরোধ নম্বর / Request: <b>%s</b></p>"
         "<p>Facebook / Instagram থেকে আসা আপনার সব চ্যাট ও কমেন্ট Assisto থেকে মুছে ফেলা হয়েছে। "
         "প্রশ্ন থাকলে: support@lifeassisto.com</p>"
         "<p>All chats and comments Assisto received about you from Facebook / Instagram "
         "were deleted. Questions: support@lifeassisto.com</p></body></html>")


def data_deletion_status(request):
    code = (request.GET.get("code") or "")[:40]
    if not code.startswith("del-"):
        return HttpResponse("not found", status=404)
    return HttpResponse(_PAGE % escape(code), content_type="text/html; charset=utf-8")
