"""halaladz (owner order 23 Nov) — HalalAdz partner integration.

Three server-side pieces, all OFF while settings.HALALADZ_SHARED_SECRET is
empty (the secret lives only in the server's secrets env file):

  * LINK (Assisto -> HalalAdz): the user types the 8-character code HalalAdz
    shows them (or opens assisto://link-halaladz?code=CODE). Assisto's SERVER
    calls  POST {HALALADZ_API_BASE}/v1/integrations/assisto/link
    with body {"code": CODE, "assisto_user_id": "<id>"} (compact JSON) and the
    headers
        X-Assisto-Timestamp: <unix seconds>
        X-Assisto-Signature: hex(HMAC-SHA256(secret, "<ts>.<raw body>"))
    HalalAdz answers 200 {"hz_account_id": "...", "display_name": "..."}.
  * NOTIFY (HalalAdz -> Assisto): POST /api/integrations/halaladz/notify,
    header X-HZ-Signature: hex(HMAC-SHA256(secret, <raw body>)); the body's
    "timestamp" (unix seconds) must be within 5 minutes; "event_id" makes it
    idempotent. Creates an in-app notification + push opening a safe https url.
  * SUPPORT chat "HalalAdz সাপোর্ট": SupportTicket(topic="halaladz") threads.

Never raises into a view on the outbound call; tests mock `_post`.
The full spec for the HalalAdz developers: owner_actions/HALALADZ_INTEGRATION_BN.md.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

from django.conf import settings

TOPIC = "halaladz"
LINK_PATH = "/v1/integrations/assisto/link"
HTTP_TIMEOUT_S = 8
MAX_SKEW_S = 300               # 5 minutes, both directions
CODE_RE = re.compile(r"^[A-Z0-9]{8}$")
EVENT_ID_RE = re.compile(r"^[A-Za-z0-9_.:\-]{1,80}$")
# link attempts per user: 5 per 10 minutes, 20 per day
LINK_PER_10MIN = 5
LINK_PER_DAY = 20
# support messages per user per hour
SUPPORT_PER_HOUR = 30
SUPPORT_TEXT_MAX = 4000
PHOTO_MAX_BYTES = 5 * 1024 * 1024
VOICE_MAX_BYTES = 3 * 1024 * 1024
VOICE_MAX_MS = 5 * 60 * 1000
# urls a notification may open (https only)
SAFE_HOSTS = ("halaladz.com", "lifeassisto.com")

QUICK_REPLIES = [
    ("ধন্যবাদ! আপনার বার্তা পেয়েছি, আমরা দেখছি।",
     "Thanks! We got your message and are looking into it."),
    ("সমস্যাটি ঠিক হয়েছে। আবার চেষ্টা করে দেখুন।",
     "This is fixed now. Please try again."),
    ("আরেকটু বিস্তারিত বলবেন? একটি স্ক্রিনশট দিলে দ্রুত সাহায্য করতে পারব।",
     "Could you tell us a bit more? A screenshot helps us fix it faster."),
    ("আপনার HalalAdz অ্যাকাউন্টের ইমেইল বা ফোন নম্বরটি দিন (পাসওয়ার্ড কখনো নয়)।",
     "Please share your HalalAdz account email or phone (never your password)."),
]


# ------------------------------------------------------------------ basics
def secret():
    return str(getattr(settings, "HALALADZ_SHARED_SECRET", "") or "")


def enabled():
    return bool(secret())


def api_base():
    return str(getattr(settings, "HALALADZ_API_BASE", "") or
               "https://api.halaladz.com").rstrip("/")


def sign(raw: bytes, key: str | None = None) -> str:
    k = (key if key is not None else secret()).encode("utf-8")
    return hmac.new(k, raw, hashlib.sha256).hexdigest()


def outbound_signature(ts: int, raw_body: bytes, key: str | None = None) -> str:
    """X-Assisto-Signature = hex HMAC-SHA256 over b"<ts>." + raw body."""
    return sign(str(int(ts)).encode("ascii") + b"." + raw_body, key)


def verify_inbound(raw_body: bytes, header: str | None) -> bool:
    """X-HZ-Signature (hex, optional "sha256=" prefix) over the RAW body.
    Constant-time compare; False when the feature is off."""
    if not enabled() or not header:
        return False
    got = str(header).strip()
    if got.lower().startswith("sha256="):
        got = got[7:]
    return hmac.compare_digest(sign(raw_body).lower(), got.lower())


def fresh(ts, now=None) -> bool:
    try:
        ts = int(ts)
    except (TypeError, ValueError):
        return False
    now = int(now if now is not None else time.time())
    return abs(now - ts) <= MAX_SKEW_S


def norm_code(raw) -> str | None:
    c = re.sub(r"[\s\-]", "", str(raw or "")).upper()
    return c if CODE_RE.match(c) else None


def safe_url(raw) -> str | None:
    """Only https urls on halaladz.com / lifeassisto.com (or subdomains)."""
    s = str(raw or "").strip()
    if not s or len(s) > 500 or any(ch in s for ch in "\r\n\t \\"):
        return None
    try:
        u = urlparse(s)
    except ValueError:
        return None
    host = (u.hostname or "").lower()
    if u.scheme != "https" or not host or u.username or u.password:
        return None
    if u.port not in (None, 443):
        return None
    if not any(host == h or host.endswith("." + h) for h in SAFE_HOSTS):
        return None
    return s


def rate_ok(user, key, limit, window_s):
    from . import channels_service as CS
    return CS.rate_ok(user, "hz" + key, limit, window_s)


# ------------------------------------------------------------------ link
class LinkError(Exception):
    def __init__(self, reason, status=400):
        super().__init__(reason)
        self.reason = reason
        self.status = status


def _post(url, raw_body, headers, timeout=HTTP_TIMEOUT_S):
    """(status, parsed json or {}). Network failure -> (0, {})."""
    req = urllib.request.Request(url, data=raw_body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:   # noqa: S310
            body = r.read(65536)
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
        try:
            body = e.read(65536)
        except Exception:  # noqa: BLE001
            body = b""
    except Exception:  # noqa: BLE001 — timeout / DNS / TLS
        return 0, {}
    try:
        js = json.loads(body.decode("utf-8") or "{}")
    except Exception:  # noqa: BLE001
        js = {}
    return code, js if isinstance(js, dict) else {}


def request_link(user, code):
    """Ask HalalAdz to confirm `code` for this user. Returns
    {"hz_account_id", "display_name"} or raises LinkError(reason, status)."""
    raw = json.dumps({"code": code, "assisto_user_id": str(user.id)},
                     separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ts = int(time.time())
    headers = {"Content-Type": "application/json",
               "User-Agent": "Assisto-HalalAdz/1",
               "X-Assisto-Timestamp": str(ts),
               "X-Assisto-Signature": outbound_signature(ts, raw)}
    status, js = _post(api_base() + LINK_PATH, raw, headers)
    if status == 0:
        raise LinkError("unreachable", 502)
    if status in (400, 404, 410, 422):
        raise LinkError("bad_code", 400)
    if status == 409:
        raise LinkError("taken", 409)
    if status == 429:
        raise LinkError("rate_limited", 429)
    if status != 200:
        raise LinkError("unreachable", 502)
    acc = str(js.get("hz_account_id") or js.get("account_id") or "").strip()[:64]
    name = str(js.get("display_name") or js.get("name") or "").strip()[:120]
    if not acc:
        raise LinkError("unreachable", 502)
    return {"hz_account_id": acc, "display_name": name}


MSG = {
    "disabled": ("HalalAdz সংযোগ এখন চালু নেই।",
                 "HalalAdz linking is not available right now."),
    "bad_code": ("কোডটি সঠিক নয় বা মেয়াদ শেষ। HalalAdz থেকে নতুন ৮ অক্ষরের কোড নিয়ে আবার দিন।",
                 "That code is wrong or has expired. Get a new 8-character code "
                 "from HalalAdz and try again."),
    "bad_format": ("কোডটি ৮ অক্ষরের হতে হবে (ইংরেজি অক্ষর ও সংখ্যা)।",
                   "The code must be 8 characters (letters and numbers)."),
    "taken": ("এই HalalAdz অ্যাকাউন্টটি আরেকটি Assisto অ্যাকাউন্টে যুক্ত আছে।",
              "This HalalAdz account is already linked to another Assisto account."),
    "rate_limited": ("অনেকবার চেষ্টা হয়েছে। ১০ মিনিট পরে আবার চেষ্টা করুন।",
                     "Too many tries. Please try again in 10 minutes."),
    "unreachable": ("HalalAdz সার্ভারে এখন পৌঁছানো যাচ্ছে না। একটু পরে আবার চেষ্টা করুন।",
                    "We can't reach HalalAdz right now. Please try again a little later."),
}


def msg(reason, lang):
    bn, en = MSG.get(reason, MSG["unreachable"])
    return en if lang == "en" else bn


# ------------------------------------------------------------------ notify
def _texts(d, field):
    """{"bn","en"} from title_bn/title_en, or {"bn":..,"en":..}, or plain."""
    v = d.get(field)
    bn = d.get(field + "_bn")
    en = d.get(field + "_en")
    if isinstance(v, dict):
        bn = bn or v.get("bn")
        en = en or v.get("en")
    elif isinstance(v, str):
        bn = bn or v
        en = en or v
    bn = str(bn or en or "").strip()
    en = str(en or bn or "").strip()
    return bn, en


def deliver(user, title_bn, title_en, body_bn, body_en, url, event_id):
    """In-app notification row + push (user's language picked by push)."""
    from django.utils import timezone

    from . import push
    from .models import NotifEvent
    NotifEvent.objects.create(
        user=user, type="channel", title_bn=title_bn[:200], title_en=title_en[:200],
        body_bn=body_bn, body_en=body_en, route="halaladz_url",
        meta={"source": "halaladz", "url": url or "", "event_id": event_id},
        at=timezone.now())
    data = {"route": "halaladz_url", "url": url or "", "event_id": event_id}
    push.safe_push(user, "halaladz", title_bn[:200], title_en[:200],
                   body_bn[:500], body_en[:500], data=data)


# ------------------------------------------------------------------ support
def decode_b64(raw, cap):
    """base64 (optionally a data: URL) -> bytes, or None when bad / too big."""
    s = str(raw or "").strip()
    if not s:
        return None
    if s.startswith("data:") and "," in s:
        s = s.split(",", 1)[1]
    if len(s) > (cap * 4) // 3 + 8:
        return None
    try:
        b = base64.b64decode(s, validate=True)
    except Exception:  # noqa: BLE001
        return None
    return b if 0 < len(b) <= cap else None


def photo_ext(b: bytes):
    if b[:3] == b"\xff\xd8\xff":
        return "jpg"
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "webp"
    return None


def voice_ext(b: bytes):
    if b[4:8] == b"ftyp":
        return "m4a"
    if b[:4] == b"OggS":
        return "ogg"
    if b[:6] == b"#!AMR\n":
        return "amr"
    if b[:3] == b"ID3" or b[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return "mp3"
    return None


def thread_for(user, create=True):
    from .models import SupportTicket
    t = (SupportTicket.objects.filter(user=user, topic=TOPIC)
         .order_by("-id").first())
    if t is None and create:
        t = SupportTicket.objects.create(user=user, topic=TOPIC, kind="support",
                                         message="HalalAdz সাপোর্ট")
    return t


def message_dict(m):
    url = ""
    if m.attachment:
        try:
            url = m.attachment.url      # signed, expiring (core.media_sign)
        except Exception:  # noqa: BLE001
            url = ""
    return {"id": m.id, "sender": m.sender, "text": m.text,
            "kind": m.attachment_kind or "text", "media_url": url,
            "duration_ms": m.duration_ms,
            "at": m.created_at.isoformat() if m.created_at else None}


def ticket_dict(t, with_user=False):
    d = {"id": t.id, "resolved": t.resolved, "unread_owner": t.unread_owner,
         "unread_user": t.unread_user,
         "last_at": (t.last_at or t.created_at).isoformat() if (t.last_at or t.created_at) else None}
    if with_user:
        last = t.messages.order_by("-id").first()
        d.update({"user_id": t.user_id,
                  "user_name": (getattr(t.user, "name", "") or "").strip(),
                  "preview": (last.text[:120] if last and last.text else
                              (last.attachment_kind if last else "")),
                  "linked_name": getattr(getattr(t.user, "halaladz_link", None),
                                         "display_name", "") if _has_link(t.user) else ""})
    return d


def _has_link(user):
    from .models import HalalAdzLink
    return HalalAdzLink.objects.filter(user=user).exists()


def owner_reply(ticket, owner, text):
    """Owner answers a thread: message row, unread for the user, push."""
    from django.utils import timezone

    from . import push
    from .models import NotifEvent, SupportMessage
    text = str(text or "").strip()[:SUPPORT_TEXT_MAX]
    if not text:
        return None
    m = SupportMessage.objects.create(ticket=ticket, sender="owner", author=owner,
                                      text=text)
    ticket.unread_user = ticket.unread_user + 1
    ticket.unread_owner = 0
    ticket.last_at = timezone.now()
    ticket.reply = text
    ticket.save(update_fields=["unread_user", "unread_owner", "last_at", "reply"])
    try:
        NotifEvent.objects.create(
            user=ticket.user, type="channel", title_bn="HalalAdz সাপোর্ট",
            title_en="HalalAdz support", body_bn=text[:300], body_en=text[:300],
            route="halaladz_support", meta={"source": "halaladz_support"},
            at=timezone.now())
    except Exception:  # noqa: BLE001
        pass
    push.safe_push(ticket.user, "halaladz", "HalalAdz সাপোর্ট", "HalalAdz support",
                   text[:300], text[:300], data={"route": "halaladz_support"})
    return m


def official():
    from .models import HalalAdzOfficial
    return HalalAdzOfficial.objects.filter(pk=1).select_related(
        "channel", "community").first()


def official_links():
    from . import channels_service as CS
    o = official()
    if o is None:
        return None
    out = {}
    if o.channel_id and o.channel is not None:
        out["channel_id"] = o.channel_id
        out["channel_url"] = CS.channel_link(o.channel)
        out["channel_name"] = o.channel.name
    if o.community_id and o.community is not None and o.community.invite_code:
        out["community_id"] = o.community_id
        out["community_url"] = CS.community_link(o.community)
        out["community_name"] = o.community.name
    return out or None
