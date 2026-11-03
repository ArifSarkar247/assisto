"""CI-ONLY deterministic fakes for the e2e proof run (settings_e2e).

Only the NETWORK seams are replaced (the same seams the unit tests patch);
everything between the app and the seam is the real server code: the chat
engine, the ACTION -> confirm-card path, OTP limits + hashing, the maps
proxy's caps, SOS fan-out, Care Call ladder, reminder push job.

Every fake call is appended to the outbox file (JSON lines) so a flow can
prove "the server sent X to Y" (GET /api/v1/ci-e2e/outbox). Fake answers are
marked "(CI)" so a screenshot can never pass for a real AI answer.
"""
import json
import re
import threading
import time
from datetime import timedelta

from django.conf import settings

_LOCK = threading.Lock()
BN = re.compile(r"[ঀ-৿]")
_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_USER = re.compile(r"User's latest message:\s*(.*?)\n\nTheir data summary:", re.S)


# ------------------------------------------------------------------ outbox
def record(kind, **row):
    row.update(kind=kind, ts=time.time())
    line = json.dumps(row, ensure_ascii=False, default=str)
    with _LOCK:
        with open(settings.E2E_OUTBOX, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def read_outbox(since=0.0, kind="", user_id=None):
    out = []
    try:
        with open(settings.E2E_OUTBOX, encoding="utf-8") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("ts", 0) <= since:
                    continue
                if kind and r.get("kind") != kind:
                    continue
                if user_id is not None and r.get("user_id") != user_id:
                    continue
                out.append(r)
    except FileNotFoundError:
        pass
    return out


# ------------------------------------------------------------------ AI
def _num(s):
    return s.translate(_BN_DIGITS)


def _local_due(minutes):
    from django.utils import timezone
    d = timezone.localtime(timezone.now()) + timedelta(minutes=minutes)
    return d.strftime("%Y-%m-%dT%H:%M")


def answer_for(user, prompt, history, system):
    """The fake model's reply for one chat turn (deterministic)."""
    bn = bool(BN.search(user))
    low = user.lower()
    tools = "ACTION:" in (system or "") or "ACTION:" in (prompt or "")
    hist_text = " ".join(str(h.get("content", "")) for h in (history or []))
    ctx = (prompt or "") + " " + hist_text
    # the photo's stored description reaches the model by either path
    # (photo_job -> DATA, or the session's photo_text in the history)
    photo = any(k in ctx for k in ("[Photo attached earlier", "[Photo shared earlier",
                                   "লাল বৃত্ত", "red circle"))
    tag = " (CI)"
    # reminder ("৩ মিনিট পরে ওষুধ খাওয়ার কথা মনে করিয়ে দাও")
    if tools and re.search(r"মনে করিয়ে|রিমাইন্ডার|remind", low):
        m = re.search(r"([0-9০-৯]+)\s*(মিনিট|min)", user)
        mins = int(_num(m.group(1))) if m else 3
        title = "ওষুধ খাওয়া" if "ওষুধ" in user else ("রিমাইন্ডার" if bn else "Reminder")
        text = ("ঠিক আছে, নিচের বোতামে হ্যাঁ চাপলে রিমাইন্ডারটি সেট হবে।" if bn
                else "Sure - tap Yes below to set the reminder.")
        return text + tag + "\nACTION: " + json.dumps(
            {"type": "reminder", "title": title, "due": _local_due(mins)}, ensure_ascii=False)
    # expense ("চায়ে ৫০ টাকা খরচ লিখে রাখো")
    m = re.search(r"([0-9০-৯]+)\s*(টাকা|tk|taka|৳)", low)
    if tools and m and re.search(r"খরচ|লিখে|spent|expense", low):
        cat = "চা" if "চা" in user else ("খাবার" if bn else "food")
        text = ("হিসাবটা লিখে রাখার আগে নিশ্চিত করুন।" if bn
                else "Please confirm before I save it.")
        return text + tag + "\nACTION: " + json.dumps(
            {"type": "expense", "amount": _num(m.group(1)), "category": cat}, ensure_ascii=False)
    # follow-up about the attached photo
    if photo:
        return ("ছবিতে যা দেখেছি সেই অনুযায়ী: বৃত্তটি লাল রঙের, পেছনটা সাদা।" if bn
                else "From the photo: the circle is red on a white background.") + tag
    # follow-up that needs the earlier turns
    if history and "রাজধানী" in hist_text:
        return ("আগের প্রশ্নটা মনে আছে — আপনি ঢাকার কথা বলছেন। ঢাকা শহরে দুই কোটির বেশি মানুষ থাকে।"
                if bn else "You asked about Dhaka: more than twenty million people live there.") + tag
    if "রাজধানী" in user or "capital" in low:
        return ("বাংলাদেশের রাজধানী ঢাকা।" if bn else "The capital of Bangladesh is Dhaka.") + tag
    return ("আপনার প্রশ্নটা পেয়েছি; এটা পরীক্ষার (CI) উত্তর।" if bn
            else "Got your question; this is a test (CI) answer.")


def fake_call_anthropic(key, model, system, prompt, max_tokens, history=None):
    m = _USER.search(prompt or "")
    if m:
        user = m.group(1).strip()
        text = answer_for(user, prompt, history, system)
    else:
        # helper calls (titles, levels, summaries): short, same language
        user = ""
        text = "ঠিক আছে (CI)" if BN.search(prompt or "") else "OK (CI)"
    record("ai", model=model, q=user[:200], a=text[:300], bn_q=bool(BN.search(user)),
           bn_a=bool(BN.search(text)), history=len(history or []))
    itok = (len(system or "") + len(prompt or "")) // 4 + 1
    return text, itok, len(text) // 4 + 1, {"model": model}


def fake_vision(cfg, *, image_bytes, mime, system, question, opts=None):
    bn = bool(BN.search(question or ""))
    text = ("ছবিতে একটি লাল বৃত্ত দেখা যাচ্ছে, পেছনটা সাদা। (CI)" if bn
            else "The photo shows a red circle on a white background. (CI)")
    record("vision", bytes=len(image_bytes or b""), q=(question or "")[:200], a=text, bn_q=bn)
    u = (opts or {}).get("usage")
    if isinstance(u, dict):
        u.update(input_tokens=500, output_tokens=40)
    return text


# ------------------------------------------------------------------ Places
CHANDRA = [
    {"id": "ci_chandra_mor", "name": "Chandra", "secondary": "Kaliakair, Gazipur",
     "lat": 24.0389, "lng": 90.2381, "address": "Chandra Mor, Kaliakair, Gazipur"},
    {"id": "ci_chandra_bus", "name": "Chandra Bus Stand", "secondary": "Dhaka-Tangail Highway, Gazipur",
     "lat": 24.0402, "lng": 90.2363, "address": "Chandra Bus Stand, Gazipur"},
]


def fake_maps_http(url, body=None, headers=None):
    record("maps", url=url.split("?")[0][:120], q=(body or {}).get("input", ""))
    if "places:autocomplete" in url:
        q = str((body or {}).get("input") or "").lower()
        hits = [p for p in CHANDRA if q[:3] and (q[:3] in p["name"].lower() or "চন্দ্রা" in q)]
        return {"suggestions": [{"placePrediction": {
            "placeId": p["id"], "distanceMeters": 35000,
            "structuredFormat": {"mainText": {"text": p["name"]},
                                 "secondaryText": {"text": p["secondary"]}}}} for p in hits]}
    if "/v1/places/" in url:
        pid = url.split("/v1/places/")[1].split("?")[0]
        for p in CHANDRA:
            if p["id"] == pid:
                return {"location": {"latitude": p["lat"], "longitude": p["lng"]},
                        "formattedAddress": p["address"]}
        return {}
    raise RuntimeError("ci_e2e: no fake for %s" % url[:80])


# ------------------------------------------------------------------ SMS / push
class _FakeSmsAdapter:
    slug = "ci_fake_sms"
    cfg = {}


def fake_send_sms(to, text, purpose, user=None, secret="", now=None, **kw):
    # the fake code is a CI constant; the text is stored with it masked
    record("sms", to=str(to)[-4:], purpose=str(purpose), text=str(text).replace(secret or "\0", "******"))
    return {"ok": True, "reason": "", "provider": "ci_fake_sms", "segments": 1}


def fake_push_to_user(user, kind, title_bn, title_en, body_bn="", body_en="",
                      data=None, high_priority=False, data_only=False, image=None):
    record("push", user_id=getattr(user, "pk", None), push_kind=kind, title=title_en or title_bn,
           title_bn=title_bn, body=body_en or body_bn,
           data={k: str(v) for k, v in (data or {}).items()}, high=bool(high_priority))
    return 1


# ------------------------------------------------------------------ install
def install():
    from core import ai, maps_cost, otp, push, sms_gateway, sms_service, vision_providers
    ai._call_anthropic = fake_call_anthropic
    vision_providers._claude = fake_vision
    maps_cost.HTTP = fake_maps_http
    code = str(settings.E2E_TEST_OTP)
    otp._gen_code = lambda: code
    otp.sms_available = lambda: True
    sms_gateway.active = lambda: [_FakeSmsAdapter()]
    sms_service.send_sms = fake_send_sms
    push.is_available = lambda: True
    push.push_to_user = fake_push_to_user
