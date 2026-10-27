"""
Push notifications — Firebase Cloud Messaging HTTP v1, fully KEY-GATED.

Nothing here works until the owner supplies a Firebase service account; until
then every entry point is a clean no-op (returns False / 0) and the app keeps
using its foreground polls (/alerts, notif feed). See MEMORY: WorkManager was
removed for Realme/ColorOS, so push is the ONLY background delivery path.

Credentials (first hit wins, never in git, never logged):
  1. JSON file at env FCM_SERVICE_ACCOUNT_FILE
     (default /home/ubuntu/.assisto_firebase_sa.json, chmod 600, server-only)
  2. integrations.get("firebase")["service_account_json"] (Fernet-encrypted
     owner key store, pasted via the owner dashboard)

OAuth2: an RS256 JWT is signed locally with `cryptography` (no google-auth
dependency) and exchanged at Google's token endpoint for a short-lived access
token, cached module-wide (thread-safe) until ~5 min before expiry.

SAFETY RULES (reviewers: keep these true):
  - NEVER raise into a caller. Every public function swallows its own errors;
    hooks additionally wrap calls so a push can never break a request.
  - NEVER put E2E message plaintext in a push — chat pushes carry only
    "New message from <display name>" + ids (the server never has plaintext).
  - NEVER log push tokens, message bodies or other PII — only kinds/counts/
    HTTP status codes.
  - Calls / call_cancel / SOS are DATA-ONLY + high priority + short TTL so the
    app's background handler can draw a full-screen ringing/alarm UI itself.
  - Shop alerts say "please check camera X" — never "theft".
  - A token FCM reports as UNREGISTERED (or rejects as an invalid token) is
    deleted from core.Device so we stop sending to dead installs.
"""
import base64
import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from django.conf import settings

log = logging.getLogger("assisto.push")

DEFAULT_SA_FILE = "/home/ubuntu/.assisto_firebase_sa.json"
TOKEN_URI = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
SEND_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
HTTP_TIMEOUT_S = 8
TOKEN_REFRESH_MARGIN_S = 300          # refresh ~5 min before expiry

KINDS = ("message", "call", "call_cancel", "reminder", "family_alert", "sos",
         "owner_alert", "shop_alert", "missed_call", "msg_sync",
         # e2-keys: SILENT data pushes (nothing is drawn): key_request asks the
         # device to publish its PUBLIC key in the background; key_ready tells
         # a waiting sender the peer's key arrived (its outbox sends).
         "key_request", "key_ready",
         # mr1: a stranger's first message (one per sender, collapsed per
         # sender). A NOTIFICATION push (the tray draws it on any build).
         "message_request",
         # agent-proactive: an Agent Core nudge / morning brief / evening
         # recap (a NOTIFICATION push; capped + quiet hours server-side).
         "agent_nudge",
         # p2-money: a brand offer the user opted into (max 2/day, mutable;
         # its own LOW-importance "offers" channel on the phone).
         "offer",
         # agent-core (WP-APP): the agent needs a one-tap approval before it
         # messages / posts / pays / books / deletes. A NOTIFICATION push with
         # NO details (lock screen): the app adds Approve / Reject actions —
         # Reject calls the API from the notification, Approve opens the card.
         "agent_approval")
# Kinds that must ALWAYS be data-only + high priority (app draws the UI).
# c3-msg: "message" is data-only too, so the DEVICE draws the WhatsApp-style
# MessagingStyle notification (decrypted on device), acks delivery and offers
# inline reply. Older app builds still draw data-only pushes (background
# handler shows title/body when there is no notification block).
# c2-calls: "missed_call" is data-only (the app draws it on its own channel).
DATA_ONLY_KINDS = ("call", "call_cancel", "sos", "message", "missed_call",
                   "msg_sync", "key_request", "key_ready")
# x2-ticks: "msg_sync" = a SILENT delivery ping (muted chat / message
# notifications off). The device only acks DELIVERED (✓✓ for the sender) and
# draws nothing. Older builds ignore unknown kinds (PushPayload.isKnownKind),
# so it can never ring a muted chat on an old phone.
# Per-kind TTL (seconds). A ring older than 30 s is useless; SOS keeps a
# little longer so a phone that briefly lost signal still gets it.
TTL_S = {"call": 30, "call_cancel": 60, "sos": 600, "message": 86400,
         "reminder": 3600, "family_alert": 86400, "owner_alert": 86400,
         "shop_alert": 3600, "missed_call": 86400, "msg_sync": 86400,
         "key_request": 86400, "key_ready": 86400, "message_request": 86400,
         "offer": 6 * 3600, "agent_nudge": 12 * 3600, "agent_approval": 86400}
# Android notification channel ids the app must create.
CHANNELS = {"message": "messages", "call": "calls", "call_cancel": "calls",
            "reminder": "reminders", "family_alert": "alerts", "sos": "sos",
            "owner_alert": "alerts", "shop_alert": "alerts",
            "missed_call": "missed_calls", "msg_sync": "messages",
            "key_request": "messages", "key_ready": "messages",
            "message_request": "messages", "offer": "offers",
            "agent_nudge": "alerts", "agent_approval": "alerts"}
# FCM rejects these data keys.
_RESERVED_DATA_KEYS = ("from", "notification", "message_type", "collapse_key")

_lock = threading.Lock()
_token_cache = {"access_token": None, "expires_at": 0.0, "client_email": None}
_executor = None
_executor_lock = threading.Lock()


# ---------------------------------------------------------------- credentials
def _sa_from_file():
    path = getattr(settings, "FCM_SERVICE_ACCOUNT_FILE", None)
    if path is None:
        path = os.getenv("FCM_SERVICE_ACCOUNT_FILE", DEFAULT_SA_FILE)
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        log.warning("push: service-account file unreadable")
        return None


def _sa_from_integrations():
    try:
        from . import integrations
        raw = (integrations.get("firebase") or {}).get("service_account_json")
    except Exception:
        return None
    if not raw:
        return None
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except Exception:
        log.warning("push: integrations service_account_json is not JSON")
        return None


def _valid_sa(sa):
    return (isinstance(sa, dict) and sa.get("client_email")
            and sa.get("private_key") and sa.get("project_id"))


def load_service_account():
    """The service-account dict, or None. Never raises."""
    for loader in (_sa_from_file, _sa_from_integrations):
        sa = loader()
        if _valid_sa(sa):
            return sa
    return None


def is_available():
    """True when FCM credentials exist (key-gate). Never raises."""
    try:
        return load_service_account() is not None
    except Exception:
        return False


# ---------------------------------------------------------------- http layer
def _http_post(url, body, headers):
    """POST bytes -> (status_code, parsed_json_or_{}). Single seam for tests.
    Uses `requests` when installed, else urllib. Raises only on network error."""
    try:
        import requests  # noqa: F401
    except ImportError:
        requests = None
    if requests is not None:
        r = requests.post(url, data=body, headers=headers, timeout=HTTP_TIMEOUT_S)
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, {}
    import urllib.request
    import urllib.error
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            code, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    try:
        return code, json.loads(raw.decode("utf-8") or "{}")
    except Exception:
        return code, {}


# ---------------------------------------------------------------- oauth2
def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def build_jwt(sa, now=None):
    """RS256-signed service-account assertion for the OAuth2 jwt-bearer grant."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    now = int(now if now is not None else time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    if sa.get("private_key_id"):
        header["kid"] = sa["private_key_id"]
    claims = {"iss": sa["client_email"], "scope": SCOPE,
              "aud": sa.get("token_uri") or TOKEN_URI,
              "iat": now, "exp": now + 3600}
    signing_input = (_b64url(json.dumps(header, separators=(",", ":")).encode())
                     + "." +
                     _b64url(json.dumps(claims, separators=(",", ":")).encode()))
    key = serialization.load_pem_private_key(
        sa["private_key"].encode("utf-8"), password=None)
    sig = key.sign(signing_input.encode("ascii"), padding.PKCS1v15(),
                   hashes.SHA256())
    return signing_input + "." + _b64url(sig)


def get_access_token(sa=None, force=False):
    """Cached OAuth2 access token or None. Thread-safe. Never raises."""
    try:
        sa = sa or load_service_account()
        if not sa:
            return None
        with _lock:
            now = time.time()
            if (not force and _token_cache["access_token"]
                    and _token_cache["client_email"] == sa["client_email"]
                    and now < _token_cache["expires_at"] - TOKEN_REFRESH_MARGIN_S):
                return _token_cache["access_token"]
            from urllib.parse import urlencode
            body = urlencode({
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": build_jwt(sa, now),
            }).encode("ascii")
            code, js = _http_post(
                TOKEN_URI, body,
                {"Content-Type": "application/x-www-form-urlencoded"})
            if code != 200 or not js.get("access_token"):
                log.warning("push: token exchange failed (http %s)", code)
                return None
            _token_cache.update(
                access_token=js["access_token"],
                expires_at=now + int(js.get("expires_in", 3600) or 3600),
                client_email=sa["client_email"])
            return js["access_token"]
    except Exception as e:  # pragma: no cover - defensive
        log.warning("push: token error %s", type(e).__name__)
        return None


def reset_cache():
    """Forget the cached access token (tests / credential rotation)."""
    with _lock:
        _token_cache.update(access_token=None, expires_at=0.0, client_email=None)


# ---------------------------------------------------------------- send
def _stringify(data):
    out = {}
    for k, v in (data or {}).items():
        k = str(k)
        if k in _RESERVED_DATA_KEYS or k.startswith(("google", "gcm")):
            continue
        if v is None:
            v = ""
        elif isinstance(v, bool):
            v = "true" if v else "false"
        elif isinstance(v, (dict, list)):
            v = json.dumps(v, ensure_ascii=False)
        out[k] = str(v)
    return out


def _is_dead_token(code, js):
    """UNREGISTERED (404) or an INVALID_ARGUMENT about the token itself."""
    err = (js or {}).get("error") or {}
    codes = {d.get("errorCode") for d in (err.get("details") or [])
             if isinstance(d, dict)}
    if "UNREGISTERED" in codes or (code == 404 and err.get("status") == "NOT_FOUND"):
        return True
    # ring-everywhere: a token minted for another Firebase project can never
    # receive our pushes either (FCM v1 SENDER_ID_MISMATCH, HTTP 403).
    if code == 403 and "SENDER_ID_MISMATCH" in codes:
        return True
    if code == 400 and (err.get("status") == "INVALID_ARGUMENT"
                        or "INVALID_ARGUMENT" in codes):
        msg = str(err.get("message", "")).lower()
        return "token" in msg or "registration" in msg
    return False


def _drop_token(token):
    try:
        from .models import Device
        n, _ = Device.objects.filter(push_token=token).delete()
        if n:
            log.info("push: removed %d dead device row(s)", n)
    except Exception:
        pass


def build_message(token, data, notification=None, priority="high", ttl_s=3600,
                  collapse_key=None, android_channel=None):
    android = {"priority": "HIGH" if priority == "high" else "NORMAL",
               "ttl": "%ds" % int(max(0, ttl_s))}
    if collapse_key:
        android["collapse_key"] = str(collapse_key)[:64]
    msg = {"token": token, "data": _stringify(data), "android": android}
    if notification:
        msg["notification"] = {k: str(v) for k, v in notification.items()
                               if k in ("title", "body") and v is not None}
        an = {}
        if android_channel:
            an["channel_id"] = android_channel
        if an:
            android["notification"] = an
    return {"message": msg}


def send_to_token(token, data, notification=None, priority="high", ttl_s=3600,
                  collapse_key=None, android_channel=None, result=None):
    """Send one FCM v1 message. True on success. Never raises.
    ring-everywhere: pass a dict as `result` to receive FCM's message id
    (`result["name"]`, e.g. "projects/x/messages/0:123") on success."""
    try:
        if not token:
            return False
        sa = load_service_account()
        if not sa:
            return False
        payload = build_message(token, data, notification, priority, ttl_s,
                                collapse_key, android_channel)
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        url = SEND_URL.format(project_id=sa["project_id"])
        for attempt in (0, 1):
            access = get_access_token(sa, force=bool(attempt))
            if not access:
                return False
            code, js = _http_post(url, body, {
                "Authorization": "Bearer " + access,
                "Content-Type": "application/json; charset=utf-8"})
            if code == 200:
                if isinstance(result, dict):
                    try:
                        result["name"] = str((js or {}).get("name", ""))[:160]
                    except Exception:
                        pass
                return True
            if code == 401 and attempt == 0:
                continue                      # stale token -> refresh once
            if _is_dead_token(code, js):
                _drop_token(token)
            else:
                log.warning("push: send failed (http %s)", code)
            return False
        return False
    except Exception as e:
        log.warning("push: send error %s", type(e).__name__)
        return False


# ---------------------------------------------------------------- per-user
def user_lang(user):
    la = getattr(user, "language", None)
    return la if la in ("bn", "en") else "bn"


def display_name(user):
    """Public display name for a push title (never phone/email)."""
    if user is None:
        return ""
    return (getattr(user, "name", "") or "").strip() or "Assisto"


def seen_name(viewer, user, group=None):
    """cde-chat: `user`'s name as `viewer` sees it in that chat — the shared
    nickname when one is set, else the public display name."""
    try:
        from . import chat_decor
        nick = chat_decor.nickname_seen_by(viewer, user, group=group)
        if nick:
            return nick
    except Exception:
        pass
    return display_name(user)


def push_to_user(user, kind, title_bn, title_en, body_bn="", body_en="",
                 data=None, high_priority=False, data_only=False):
    """Send `kind` to every registered device of `user`. Returns the number of
    devices that accepted it (0 when push is unavailable). Never raises."""
    try:
        if user is None or kind not in KINDS or not is_available():
            return 0
        from .models import Device
        # calls95: newest phone first — it is the one most likely alive, and
        # a dead older token (dropped below) must never delay its ring.
        tokens = list(Device.objects.filter(user=user).exclude(push_token="")
                      .order_by("-last_seen", "-id")
                      .values_list("push_token", flat=True))
        if not tokens:
            if kind == "call":
                _call_push_event((data or {}).get("call_id"), "no_device", user)
            return 0
        lang = user_lang(user)
        title = title_en if lang == "en" else title_bn
        body = body_en if lang == "en" else body_bn
        if kind in DATA_ONLY_KINDS:
            data_only, high_priority = True, True
        payload = dict(data or {})
        payload.update(kind=kind, title=title or "", body=body or "",
                       lang=lang, channel=CHANNELS[kind],
                       sent_at=int(time.time()))
        notification = None if data_only else {"title": title, "body": body}
        collapse = None
        if kind == "message" and payload.get("chat_id"):
            collapse = "chat-%s" % payload["chat_id"]
        elif kind == "message_request" and payload.get("sender_id"):
            collapse = "msgreq-%s" % payload["sender_id"]   # mr1: per sender
        elif kind in ("key_request", "key_ready"):
            collapse = kind   # one pending per device is enough
        elif kind in ("call", "call_cancel") and payload.get("call_id"):
            collapse = "call-%s" % payload["call_id"]
        elif kind == "agent_approval" and payload.get("approval_id"):
            collapse = "agentap-%s" % payload["approval_id"]
        sent = 0
        msg_ids = []
        for tok in dict.fromkeys(tokens):
            res = {}
            if send_to_token(tok, payload, notification,
                             priority="high" if high_priority else "normal",
                             ttl_s=TTL_S.get(kind, 3600), collapse_key=collapse,
                             android_channel=CHANNELS[kind], result=res):
                sent += 1
                if res.get("name"):
                    msg_ids.append(res["name"])
        if kind == "call" and payload.get("call_id"):
            _record_call_push(payload.get("call_id"), sent, msg_ids)
            if not sent:
                # every token refused (dead tokens are already dropped):
                # visible in Owner Admin -> Calls -> missed-ring causes
                _call_push_event(payload.get("call_id"), "send_fail", user)
        log.info("push: kind=%s devices=%d sent=%d", kind, len(tokens), sent)
        return sent
    except Exception as e:
        log.warning("push: push_to_user error %s", type(e).__name__)
        return 0


def _record_call_push(call_id, sent, msg_ids):
    """ring-everywhere: FCM accepted the ring for this call -> remember when
    and its message id (Owner Admin / delivery debugging). Never raises."""
    if not sent:
        return
    try:
        from django.utils import timezone as _tz
        from .models import CallSession
        qs = CallSession.objects.filter(call_id=int(call_id))
        qs.filter(fcm_sent_at__isnull=True).update(fcm_sent_at=_tz.now())
        if msg_ids:
            qs.update(fcm_msg_id=msg_ids[-1][:160])
    except Exception:
        pass


def _call_push_event(call_id, code, user=None):
    """calls95: a ring push that reached NO device (no token / every send
    refused) -> CallHealthEvent(step=push) for the miss-cause table. Never
    raises."""
    try:
        if not call_id:
            return
        from . import call_health
        call_health.log_event("push", code, user=user, call_id=int(call_id))
    except Exception:
        pass


def _get_executor():
    global _executor
    with _executor_lock:
        if _executor is None:
            _executor = ThreadPoolExecutor(max_workers=2,
                                           thread_name_prefix="assisto-push")
        return _executor


def _run_in_worker(args, kwargs):
    from django.db import close_old_connections, connection
    try:
        close_old_connections()
        push_to_user(*args, **kwargs)
    except Exception:
        pass
    finally:
        try:
            connection.close()
        except Exception:
            pass


def push_to_user_async(user, kind, title_bn, title_en, body_bn="", body_en="",
                       data=None, high_priority=False, data_only=False,
                       sync=None):
    """Fire-and-forget push. The availability check runs inline (cheap) so with
    no credentials nothing is queued at all. sync=True (or settings.PUSH_SYNC)
    runs inline — used by tests. Never raises; returns True if queued/sent."""
    try:
        if user is None or not is_available():
            return False
        args = (user, kind, title_bn, title_en, body_bn, body_en)
        kwargs = {"data": data, "high_priority": high_priority,
                  "data_only": data_only}
        if sync is None:
            sync = bool(getattr(settings, "PUSH_SYNC", False))
        if sync:
            return push_to_user(*args, **kwargs) > 0
        _get_executor().submit(_run_in_worker, args, kwargs)
        return True
    except Exception:
        return False


def safe_push(*args, **kwargs):
    """Hook helper: push_to_user_async that can NEVER raise into a view."""
    try:
        return push_to_user_async(*args, **kwargs)
    except Exception:
        return False


# ---------------------------------------------------------------- helpers
def member_peer_user(member):
    """The OTHER party's User for a CircleMember edge (peer_user, else phone)."""
    try:
        peer = getattr(member, "peer_user", None)
        if peer is not None:
            return peer
        phone = (getattr(member, "phone", "") or "").strip()
        if phone:
            from django.contrib.auth import get_user_model
            from .phone import find_user as _find_by_phone
            return (_find_by_phone(phone)
                    or get_user_model().objects.filter(phone=phone).first())
    except Exception:
        pass
    return None


def circle_family_users(user):
    """Accepted circle peers of `user` that have an Assisto account."""
    try:
        from .models import CircleMember
        out, seen = [], set()
        for m in CircleMember.objects.filter(user=user, state="accepted",
                                             blocked=False):
            peer = member_peer_user(m)
            if peer is not None and peer.pk != user.pk and peer.pk not in seen:
                seen.add(peer.pk)
                out.append(peer)
        return out
    except Exception:
        return []


def _smtp_configured():
    backend = str(getattr(settings, "EMAIL_BACKEND", "") or "").lower()
    return bool(backend) and not any(
        b in backend for b in ("console", "locmem", "dummy", "filebased"))


def notify_owner(subject, body):
    """Alert every superuser: FCM push (owner_alert) when available AND email
    when real SMTP is configured (+ env OWNER_ALERT_EMAIL). Never raises.
    Returns what was attempted."""
    out = {"push_available": False, "push_sent": 0, "email": False,
           "email_recipients": 0}
    try:
        from django.contrib.auth import get_user_model
        owners = list(get_user_model().objects.filter(is_superuser=True,
                                                      is_active=True))
        if is_available():
            out["push_available"] = True
            for u in owners:
                out["push_sent"] += push_to_user(
                    u, "owner_alert", subject, subject, body, body,
                    data={"route": "owner"}, high_priority=True)
        if _smtp_configured():
            emails = [u.email for u in owners if getattr(u, "email", None)]
            extra = (os.getenv("OWNER_ALERT_EMAIL") or "").strip()
            if extra:
                emails += [e.strip() for e in extra.split(",") if e.strip()]
            emails = list(dict.fromkeys(emails))
            if emails:
                from django.core.mail import send_mail
                send_mail(subject, body, settings.DEFAULT_FROM_EMAIL, emails,
                          fail_silently=True)
                out["email"] = True
                out["email_recipients"] = len(emails)
    except Exception as e:
        log.warning("push: notify_owner error %s", type(e).__name__)
    return out


# ---------------------------------------------------------------- view hooks
# Each hook is fully wrapped: whatever happens in here, the calling view's
# response is unaffected. All of them are no-ops when push is unavailable.
def _reverse_edge(recipient, sender):
    """The recipient's own CircleMember row pointing at `sender` (their chat id
    for this conversation), or None."""
    from .models import CircleMember
    edge = CircleMember.objects.filter(user=recipient, peer_user=sender).first()
    if edge is None and (getattr(sender, "phone", "") or "").strip():
        edge = CircleMember.objects.filter(user=recipient,
                                           phone=sender.phone.strip()).first()
    return edge


def _recipient_silenced(edge):
    if edge is None:
        return False
    if getattr(edge, "blocked", False) or getattr(edge, "restricted", False):
        return True
    mu = getattr(edge, "muted_until", None)
    if mu is not None:
        from django.utils import timezone
        if mu > timezone.now():
            return True
    # m1-messenger: the hub's per-user mute (ChatOrganiseState) counts too.
    try:
        from .views_m1_messenger import organise_muted
        if organise_muted(edge.user, "member", edge.id):
            return True
    except Exception:
        pass
    return False


def _m1_notif(user):
    """m1-messenger: the recipient's Messenger notification prefs (messages /
    groups / calls / show_preview). Defaults to all-on; never raises."""
    try:
        from .views_m1_messenger import notif_prefs
        return notif_prefs(user)
    except Exception:
        return {"messages": True, "groups": True, "calls": True,
                "show_preview": True}


def _private_texts():
    """show_preview=false: a push that names nobody."""
    return ("নতুন মেসেজ", "New message", "পড়তে Assisto খুলুন",
            "Open Assisto to read")


def _message_texts(sender_name):
    return ("নতুন মেসেজ — %s" % sender_name, "New message from %s" % sender_name,
            "পড়তে Assisto খুলুন", "Open Assisto to read")


# ---- x2-ticks ---- delivery pings -------------------------------------------
def _x2_notify_new(recipient, chat_kind, chat_id, message_id):
    """`msg.new` on the shared realtime queue for an app that is OPEN: it acks
    DELIVERED at once (POST circle/receipts) and refreshes the open chat. Ids
    only. Never raises."""
    try:
        if recipient is None or chat_id is None:
            return 0
        from .views_c2_calls import rt_publish
        return rt_publish(recipient, "msg.new", {
            "chat": "%s:%s" % (chat_kind, chat_id),
            "message_id": message_id})
    except Exception:
        return 0


def _x2_silent_sync(recipient, chat_kind, chat_id, message_id, sender_id):
    """Data-only, high-priority, draws NOTHING: the phone acks delivered."""
    return safe_push(recipient, "msg_sync", "", "", "", "", data={
        "message_id": message_id, "chat_kind": chat_kind,
        "chat_id": chat_id, "sender_id": sender_id, "silent": "1"},
        high_priority=True)
# ---- /x2-ticks ----


def hook_circle_message(sender, member, message):
    """1:1 circle message relayed on `member` (the SENDER's edge). Push carries
    the sender's display name + ids ONLY — never ciphertext/plaintext."""
    try:
        recipient = member_peer_user(member)
        if recipient is None or recipient.pk == sender.pk:
            return False
        edge = _reverse_edge(recipient, sender)
        # x2-ticks: the realtime queue tells an OPEN app at once (delivered
        # ack without waiting for FCM) — works with or without Firebase.
        _x2_notify_new(recipient, "member", edge.id if edge else None,
                       message.id)
        if not is_available():
            return False
        if edge is not None and getattr(edge, "blocked", False):
            return False
        prefs = _m1_notif(recipient)
        if _recipient_silenced(edge) or not prefs.get("messages", True):
            # x2-ticks: muted / notifications off -> no ring, but the phone
            # must still ack DELIVERED (WhatsApp: ✓✓ even for a muted chat).
            return _x2_silent_sync(recipient, "member",
                                   edge.id if edge else "", message.id,
                                   sender.id)
        preview = prefs.get("show_preview", True)
        sname = seen_name(recipient, sender)  # cde-chat: nickname first
        tb, te, bb, be = (_message_texts(sname) if preview
                          else _private_texts())
        return safe_push(recipient, "message", tb, te, bb, be, data={
            "message_id": message.id, "chat_kind": "member",
            "chat_id": edge.id if edge is not None else "",
            "sender_id": sender.id,
            "sender_name": sname if preview else "",
            # c3-msg: the device honours the account-wide preview switch too
            "preview": "1" if preview else "0",
            "route": "circle/chat"}, high_priority=True)
    except Exception:
        return False


def hook_group_message(sender, group, message):
    """Group message -> every ACTIVE member except the sender (names + ids only)."""
    try:
        from .models import CircleGroupMember
        rows = (CircleGroupMember.objects.filter(group=group, status="active")
                .exclude(member=sender).select_related("member"))
        for r in rows:   # x2-ticks: realtime "new message" (delivered ack)
            _x2_notify_new(r.member, "group", group.id, message.id)
        if not is_available():
            return False
        tb, te, bb, be = _message_texts(display_name(sender))
        gname = (getattr(group, "name", "") or "").strip()
        if gname:
            bb, be = "%s — পড়তে খুলুন" % gname, "%s — open to read" % gname
        from .views_m1_messenger import organise_muted
        sent = 0
        for r in rows:
            # m1-messenger: a member who muted this group, or switched group
            # notifications off, gets nothing; show_preview=false hides names.
            prefs = _m1_notif(r.member)
            if (organise_muted(r.member, "group", group.id)
                    or not prefs.get("groups", True)):
                # x2-ticks: silent delivery ping (no ring, ✓✓ still works)
                _x2_silent_sync(r.member, "group", group.id, message.id,
                                sender.id)
                continue
            preview = prefs.get("show_preview", True)
            sname = seen_name(r.member, sender, group=group)  # cde-chat
            t = ((tb, te, bb, be) if sname == display_name(sender)
                 else _message_texts(sname)[:2] + (bb, be))
            t = t if preview else _private_texts()
            safe_push(r.member, "message", *t, data={
                "message_id": message.id, "chat_kind": "group",
                "chat_id": group.id, "group_id": group.id,
                "sender_id": sender.id,
                "sender_name": sname if preview else "",
                "preview": "1" if preview else "0",
                "route": "circle/group"}, high_priority=True)
            sent += 1
        return sent > 0
    except Exception:
        return False


def hook_call_placed(caller, member, call, attempt=0):
    """Ring the callee's devices (data-only, high priority, 30 s TTL).
    ring-everywhere: `attempt` > 0 is a bounded resend (same collapse key
    call-<id>, the phone shows ONE notification per call id). The payload
    carries `ack_sig` so the phone's NATIVE FCM service can confirm
    delivery / decline without the Flutter engine or the auth token."""
    try:
        if not is_available():
            return False
        callee = member_peer_user(member)
        if callee is None or callee.pk == caller.pk:
            return False
        edge = _reverse_edge(callee, caller)
        if edge is not None and getattr(edge, "blocked", False):
            return False
        # m1-messenger: callee prefs — call notifications off, or "silence
        # unknown callers" and the caller is not in their accepted circle.
        if not _m1_notif(callee).get("calls", True):
            return False
        try:
            from .views_m1_messenger import call_prefs
            if call_prefs(callee)["silence_unknown"] and (
                    edge is None or edge.state != "accepted"):
                return False
        except Exception:
            pass
        name = seen_name(callee, caller)  # cde-chat: the callee's nickname
        video = getattr(call, "kind", "voice") == "video"
        return safe_push(callee, "call",
                         "%s কল করছেন" % name, "%s is calling" % name,
                         "ভিডিও কল" if video else "ভয়েস কল",
                         "Video call" if video else "Voice call",
                         data={"call_id": call.id, "caller_id": caller.id,
                               "caller_name": name, "video": video,
                               "chat_id": edge.id if edge is not None else "",
                               # x1-calls A3: caller photo for the full-screen
                               # ring + notification large icon
                               "caller_photo": _x1_photo(caller),
                               "ack_sig": _ack_sig(call),
                               "attempt": int(attempt or 0),
                               "route": "circle/call"})
    except Exception:
        return False


def _ack_sig(call):
    try:
        from .call_ack import sign
        return sign(call.id, call.callee_id)
    except Exception:
        return ""


def _x1_photo(user):
    try:
        from .views_c2_calls import photo_of
        return photo_of(user)[0]
    except Exception:
        return ""


def hook_call_cancel(call, reason):
    """Stop the ringing on the callee side (cancelled/declined/missed/failed
    before answer)."""
    try:
        if not is_available() or call is None:
            return False
        member = getattr(call, "circle", None)
        callee = member_peer_user(member) if member is not None else None
        if callee is None or callee.pk == call.caller_id:
            return False
        return safe_push(callee, "call_cancel", "কল শেষ", "Call ended", "", "",
                         data={"call_id": call.id, "caller_id": call.caller_id,
                               "reason": reason or "", "route": "circle/call"})
    except Exception:
        return False


def hook_family_alert(user, title_bn, title_en, body_bn="", body_en="",
                      data=None, include_self=False):
    """A family-facing alert raised by/for `user` -> their accepted circle
    peers (and optionally the user's own other devices)."""
    try:
        if not is_available() or user is None:
            return False
        targets = circle_family_users(user)
        if include_self:
            targets = [user] + targets
        payload = dict(data or {})
        payload.setdefault("from_user_id", user.id)
        payload.setdefault("from_name", display_name(user))
        payload.setdefault("route", "alerts")
        for t in targets:
            safe_push(t, "family_alert", title_bn, title_en, body_bn, body_en,
                      data=payload, high_priority=True)
        return bool(targets)
    except Exception:
        return False


def hook_sos(user, lat=None, lng=None, silent=False, journey_id=None):
    """SOS -> every accepted circle peer, data-only + high priority. A SILENT
    (duress) SOS still reaches family — only the sender's own screen is quiet;
    nothing is ever sent back to the sender's devices."""
    try:
        if not is_available() or user is None:
            return False
        name = display_name(user)
        data = {"from_user_id": user.id, "from_name": name,
                "lat": "" if lat is None else lat,
                "lng": "" if lng is None else lng,
                "silent": bool(silent), "journey_id": journey_id or "",
                "route": "safety/sos"}
        targets = circle_family_users(user)
        for t in targets:
            safe_push(t, "sos", "জরুরি: %s সাহায্য চাইছেন" % name,
                      "SOS: %s needs help" % name,
                      "এখনই যোগাযোগ করুন", "Please contact them now", data=data)
        return bool(targets)
    except Exception:
        return False
