"""callmoney — AFTER CALL NOTE: turn what the user said/typed after a call into
draft items (a reminder, a note or a khata due entry).

POST /api/v1/callnote/understand {text, now?}
  -> {ok: true, ai: true, items: [{kind, title, due_at, date_only, amount,
      person, direction, due_date}], charged}
  -> {ok: false, reason, detail}  (no key / no credits / unclear: the app then
      falls back to its on-device rules; no credits are kept for an unusable
      answer)

Rules (owner order 4 Nov 02:22):
* This endpoint NEVER writes anything. The phone shows the drafts and saves
  each one ONLY after the user taps Confirm (reminder / note / loan repos).
* NEVER a call recording: the input is the user's own words typed or spoken
  AFTER the call; audio never reaches the server; the text is not stored.
* Shared AI router + the user's level/credit rules: core.ai.generate with the
  cheap tier (ai_msg_cheap credits), PII masked before any provider sees it.
"""
import json
import re
from datetime import date, datetime

from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang

MAX_TEXT = 600
MAX_ITEMS = 3
KINDS = ("reminder", "note", "due")
DIRECTIONS = ("they_owe", "i_owe")

TASK = (
    "The user just finished a phone call and told Assisto what to remember. "
    "DATA is their own words (Bangla, English or Banglish). Today (Asia/Dhaka) "
    "is {now}. Turn it into at most 3 items. Kinds: 'reminder' (something to "
    "do at a time), 'note' (information to keep), 'due' (money someone owes: "
    "direction 'they_owe' = the other person will pay the user, 'i_owe' = the "
    "user must pay). Reply with ONLY one JSON object, no prose: "
    "{\"items\":[{\"kind\":\"reminder|note|due\",\"title\":\"short title in the "
    "user's language\",\"due_at\":\"YYYY-MM-DDTHH:MM or null\",\"amount\":number "
    "or null,\"person\":\"name or null\",\"direction\":\"they_owe|i_owe|null\","
    "\"due_date\":\"YYYY-MM-DD or null\"}]}. Never invent names, amounts or "
    "times that are not in DATA; leave them null. Keep the user's language "
    "for titles.")


def _clean_str(v, n):
    if not isinstance(v, str):
        return None
    v = re.sub(r"\s+", " ", v).strip()
    return v[:n] or None


def _clean_dt(v):
    if not isinstance(v, str) or not v.strip():
        return None, False
    s = v.strip()
    try:
        if len(s) == 10:
            return date.fromisoformat(s).isoformat(), True
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%dT%H:%M"), False
    except ValueError:
        return None, False


def _clean_amount(v):
    try:
        a = float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None
    if a <= 0 or a > 1_000_000_000:
        return None
    return int(a) if a == int(a) else round(a, 2)


def parse_items(text):
    """Validate the model output into safe draft items ([] = unusable)."""
    raw = str(text or "")
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        return []
    try:
        obj = json.loads(m.group(0))
    except ValueError:
        return []
    items = obj.get("items") if isinstance(obj, dict) else None
    out = []
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict) or it.get("kind") not in KINDS:
            continue
        kind = it["kind"]
        title = _clean_str(it.get("title"), 120)
        due_at, date_only = _clean_dt(it.get("due_at"))
        item = {"kind": kind, "title": title, "due_at": due_at, "date_only": date_only,
                "amount": None, "person": None, "direction": None, "due_date": None}
        if kind == "due":
            item["amount"] = _clean_amount(it.get("amount"))
            item["person"] = _clean_str(it.get("person"), 60)
            d = it.get("direction")
            item["direction"] = d if d in DIRECTIONS else None
            dd, _ = _clean_dt(it.get("due_date"))
            item["due_date"] = dd[:10] if dd else None
            if item["amount"] is None:
                continue          # a due without an amount is not a due
        elif not title:
            continue
        out.append(item)
        if len(out) >= MAX_ITEMS:
            break
    return out


class CallNoteUnderstandView(APIView):
    def post(self, request):
        from . import ai
        lang = req_lang(request)
        text = _clean_str((request.data or {}).get("text"), MAX_TEXT)
        if not text:
            return Response({"ok": False, "reason": "empty",
                             "detail": pick(lang, "কিছু বলুন বা লিখুন।", "Say or type something.")},
                            status=400)
        now = _clean_str((request.data or {}).get("now"), 32) or date.today().isoformat()
        meta = {}
        try:
            out, _cost = ai.generate(TASK.replace("{now}", now), data=text, tier="cheap",
                                     max_tokens=400, feature="call_note", user=request.user,
                                     pii=True, out_meta=meta)
        except ai.AIUnavailable as e:
            msg = {"no_key": ("AI এখনো যুক্ত হয়নি — ফোনের নিয়মে সাজানো হলো।",
                              "AI is not connected yet — sorted with the phone's rules."),
                   "credits": ("যথেষ্ট ক্রেডিট নেই — ফোনের নিয়মে সাজানো হলো।",
                               "Not enough credits — sorted with the phone's rules."),
                   "user_limit": ("আজকের AI সীমা শেষ — ফোনের নিয়মে সাজানো হলো।",
                                  "Today's AI limit is reached — sorted with the phone's rules.")}
            bn_m, en_m = msg.get(e.reason, ("এখন AI পাওয়া গেল না — ফোনের নিয়মে সাজানো হলো।",
                                           "AI is not available now — sorted with the phone's rules."))
            return Response({"ok": False, "reason": e.reason, "detail": pick(lang, bn_m, en_m)},
                            status=402 if e.reason == "credits" else 503)
        items = parse_items(out)
        if not items:
            charged = int(meta.get("charged") or 0)
            if charged:
                try:
                    from . import billing
                    billing.credit(request.user, "adjust", charged, note="ai_refund")
                except Exception:
                    pass
            return Response({"ok": False, "reason": "unclear", "refunded": charged,
                             "detail": pick(lang, "AI বুঝতে পারেনি — ফোনের নিয়মে সাজানো হলো, কোনো ক্রেডিট কাটা হয়নি।",
                                            "AI couldn't sort it — used the phone's rules, no credits used.")},
                            status=200)
        return Response({"ok": True, "ai": True, "items": items,
                         "charged": int(meta.get("charged") or 0)})
