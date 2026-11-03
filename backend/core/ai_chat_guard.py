"""
aibar (2 Nov, launch group 6) — the production guards shared by the Assisto AI
chat (/chat/sessions/<id>/send|stream|regenerate) and the home chat (/agent).
Pure helpers + small DB reads; no network, no AI call, never raises into a
view.

  * INPUT CAPS — the user's own text is cut at USER_TEXT_MAX characters and
    the earlier turns sent as context are bounded (turns + characters per
    turn) on EVERY path, not only when the owner's pricing-40 credit_model is
    on. Before this a 50,000-character paste on the legacy path cost ~৳24 on
    Opus for 1 credit (owner_actions/PRICING_40PCT_BN.md §3).
  * BURST LIMIT — per user, per minute and per hour, counted from the stored
    user turns (ChatMessage) so it holds across every gunicorn worker. The
    crisis guard runs BEFORE it: a crisis message is never rate-limited.
  * IDEMPOTENCY — the app sends one `client_id` per typed message; a retry
    (stream dropped -> /send fallback, "Send again", flaky network) of the
    same id replays the stored answer instead of charging / logging twice.
  * HONEST DEGRADE LINES — when keyed AI is configured but cannot answer this
    turn (daily per-user limit, owner's daily cap, every provider failed),
    the reply says WHICH, instead of the old "the owner hasn't added the key
    yet" (false once keys exist). No credits are taken for these.
"""
import logging
import re
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from .i18n import pick

log = logging.getLogger(__name__)

USER_TEXT_MAX = 4000          # same as pricing_40 credit_model.user_text_max_chars
LEGACY_HISTORY_TURNS = 12     # earlier turns sent on the legacy (non-mode) path
HISTORY_TURN_CHARS = 1200     # each earlier turn is cut to this many characters

_CID = re.compile(r"^[A-Za-z0-9_\-:.]{8,64}$")


# ------------------------------------------------------------------ caps
def cap_text(text, limit=USER_TEXT_MAX):
    """(text cut to `limit` characters, was_cut)."""
    text = text or ""
    limit = int(limit or USER_TEXT_MAX)
    if len(text) <= limit:
        return text, False
    return text[:limit], True


def cap_history(history, turns=LEGACY_HISTORY_TURNS, chars=HISTORY_TURN_CHARS):
    """The last `turns` earlier turns, each cut to `chars` characters."""
    out = []
    for h in list(history or [])[-int(turns):]:
        c = (h.get("content") or "")
        out.append({"role": h.get("role"), "content": c[:int(chars)]})
    return out


# ------------------------------------------------------------------ client id
def client_id(request):
    """The app's per-message idempotency key ('' when absent / malformed)."""
    try:
        v = request.data.get("client_id")
    except Exception:  # noqa: BLE001
        v = None
    v = str(v or "").strip()
    return v if _CID.match(v) else ""


# ------------------------------------------------------------------ burst
def _rate(source):
    if source == "home":
        return (int(getattr(settings, "AGENT_RATE_PER_MIN", 20)),
                int(getattr(settings, "AGENT_RATE_PER_HOUR", 300)))
    return (int(getattr(settings, "AI_CHAT_RATE_PER_MIN", 10)),
            int(getattr(settings, "AI_CHAT_RATE_PER_HOUR", 150)))


def burst_retry_after(user, source="ai"):
    """Seconds the user must wait before another turn on `source` ('ai' =
    Assisto AI chat, 'home' = home chat), or 0 when allowed. Counted from the
    user's stored turns, so it is the same on every server worker."""
    from .models import ChatMessage
    per_min, per_hour = _rate(source)
    now = timezone.now()
    qs = ChatMessage.objects.filter(session__user=user, session__source=source,
                                    role="user")
    try:
        last_min = qs.filter(created_at__gte=now - timedelta(seconds=60))
        if per_min > 0 and last_min.count() >= per_min:
            first = last_min.order_by("created_at").first()
            wait = 60 - int((now - first.created_at).total_seconds())
            return max(1, wait)
        last_hour = qs.filter(created_at__gte=now - timedelta(hours=1))
        if per_hour > 0 and last_hour.count() >= per_hour:
            first = last_hour.order_by("created_at").first()
            wait = 3600 - int((now - first.created_at).total_seconds())
            return max(1, wait)
    except Exception:  # noqa: BLE001 — a counting error never blocks a user
        return 0
    return 0


def rate_limited_body(lang, retry_after):
    s = int(retry_after)
    return {
        "ok": False, "code": "rate_limited", "reason": "rate_limited",
        "retry_after": s,
        "detail": pick(lang,
                       "একটু ধীরে — খুব দ্রুত অনেক বার্তা এসেছে। %s সেকেন্ড পরে আবার পাঠান; "
                       "আপনার লেখা বাক্সে রাখা আছে।" % _bn_digits(s),
                       "Slow down a little — too many messages too fast. Send again in "
                       "%d seconds; your text is kept." % s),
    }


def _bn_digits(n):
    return str(n).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


# ------------------------------------------------------------------ honest lines
_UNAVAILABLE = {
    "user_limit": (
        "আজকের AI প্রশ্নের দৈনিক সীমা শেষ — কাল আবার পাবেন। কোনো ক্রেডিট কাটা হয়নি। "
        "আপনার নিজের খরচ, রিমাইন্ডার ও অ্যাপের প্রশ্নের উত্তর এখনও দিতে পারি।",
        "You've reached today's AI question limit — it resets tomorrow. No credits were "
        "taken. I can still answer about your own spending, reminders and the app."),
    "budget": (
        "AI আজকের জন্য সাময়িক বন্ধ (দৈনিক খরচের সীমা)। কোনো ক্রেডিট কাটা হয়নি। "
        "আপনার নিজের তথ্য ও অ্যাপের প্রশ্নের উত্তর এখনও দিতে পারি।",
        "AI is paused for today (daily spending limit). No credits were taken. "
        "I can still answer about your own data and the app."),
    "queued": (
        "AI এই মুহূর্তে উত্তর দিতে পারছে না — কোনো ক্রেডিট কাটা হয়নি। একটু পরে "
        "'আবার তৈরি করুন' চাপুন।",
        "The AI can't answer right now — no credits were taken. Tap 'Regenerate' "
        "in a moment."),
    "credits": (
        "এই উত্তরের জন্য যথেষ্ট ক্রেডিট নেই — কিছু কাটা হয়নি। ক্রেডিট পেলে আবার পাঠান।",
        "Not enough credits for this answer — nothing was taken. Send it again once "
        "you have credits."),
}


def unavailable_line(reason, lang):
    """The honest line for a keyed-AI turn that could not run, or None for
    'no_key' (the Brain's own needs-key line is true then)."""
    row = _UNAVAILABLE.get(reason)
    if row is None and reason and reason != "no_key":
        row = _UNAVAILABLE["queued"]
    return pick(lang, *row) if row else None


# aifinal (owner 3 Nov 23:20, PART 1b): users never see admin wording (key,
# Integrations, owner, provider names). The real reason stays in the owner's
# payload / the server log; everyone else gets one friendly line.
FRIENDLY_UNAVAILABLE = (
    "এই সুবিধাটি এই মুহূর্তে দেওয়া যাচ্ছে না — একটু পরে আবার চেষ্টা করুন।",
    "This isn't available right now — please try again a little later.")


def friendly_needs(state, user, lang):
    """A provider-state dict with every 'needs' text made user-safe for anyone
    but the owner (superuser). Never raises; returns a new dict."""
    if not isinstance(state, dict) or getattr(user, "is_superuser", False):
        return state
    out = dict(state)
    if out.get("needs"):
        log.info("ai: unavailable for user (%s)", str(out["needs"])[:120])
        out["needs"] = pick(lang, *FRIENDLY_UNAVAILABLE)
    if isinstance(out.get("providers"), list):
        out["providers"] = [dict(r, needs="") if isinstance(r, dict) else r
                            for r in out["providers"]]
    return out


# ------------------------------------------------------------------ credits
def balance(user):
    """The user's credit balance right now (fresh from the DB), or None."""
    try:
        from .models import User
        v = User.objects.filter(pk=user.pk).values_list("ai_credits", flat=True).first()
        return None if v is None else int(v)
    except Exception:  # noqa: BLE001
        return None
