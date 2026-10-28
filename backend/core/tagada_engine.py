"""
tagada_engine.py — tagada2 (owner order 28 Oct, part B): the SERVER decides
how a due reminder reaches each customer, and enforces the rules on every
channel. Pure decisions live in core/logic/tagada_route.py; this module
feeds it the DB facts and persists what happens.

Send order (cheapest first):
  1 assisto      customer is an Assisto user matched by a VERIFIED phone only
                 (PhoneVerification == account phone; the test-build flag
                 contacts_match_unverified is NEVER used here) -> the message
                 lands in the shop <-> customer thread + an Assisto push. FREE.
  2 whatsapp /   wa.me link / the owner's own-SIM SMS composer. FREE; the
    own_sms      server claims today's slot and hands back the link.
  3 gateway_sms  Assisto sends it: SMS PARTS from the owner's Business-plan
                 monthly allowance first, then SMS-pack parts
                 (core/sms_wallet). Never sent without enough parts; parts
                 come back if the gateway fails.

Server rules (every channel): ONE tagada per customer per shop per Dhaka day
(TagadaSend unique row — a second claim fails in the database); a customer
who blocked the shop is "not reachable" (the shop never sees "blocked");
STOP opt-out + quiet hours 21:00-09:00 for what Assisto itself sends.

Customer side ("My Dues"): a VERIFIED account sees, per shop, only what that
shop recorded under the customer's verified number (balance + entry amount,
date, line note — never the shop's private party note, bill photos, other
customers or the supplier book), chats with the shop, mutes or blocks it.
"""
import logging
from datetime import timedelta

from django.db import IntegrityError, transaction
from django.db.models import Count, Max, Q, Sum
from django.utils import timezone

from .logic import business_khata as khata
from .logic import tagada_route as TR

log = logging.getLogger(__name__)

CHAT_MAX_CHARS = 1000
SHOP_MSGS_PER_HOUR = 60        # per customer
CUSTOMER_MSGS_PER_HOUR = 30    # per shop
ENTRIES_SHOWN = 50

# reason -> (http status, bn, en). Shop-facing; never says "blocked".
REASONS = {
    "daily_limit": (429, "এই গ্রাহককে আজ একবার তাগাদা পাঠানো হয়েছে। কাল আবার পাঠাতে পারবেন।",
                    "This customer was already reminded today. You can remind again tomorrow."),
    "not_reachable": (409, "এই গ্রাহককে এখন Assisto দিয়ে পাওয়া যাচ্ছে না।",
                      "This customer can't be reached through Assisto right now."),
    "not_assisto_user": (409, "এই গ্রাহক এখনো Assisto ব্যবহার করেন না — WhatsApp বা SMS দিয়ে পাঠান, "
                              "অথবা Assisto-তে আমন্ত্রণ দিন।",
                         "This customer isn't on Assisto yet — use WhatsApp or SMS, or invite "
                         "them to Assisto."),
    "no_balance": (402, "SMS ব্যালান্স কম — SMS কিনুন অথবা WhatsApp দিয়ে বিনা খরচে পাঠান।",
                   "Not enough SMS balance — buy SMS or send free on WhatsApp."),
    "owner_only": (403, "শুধু মালিক Assisto SMS পাঠাতে পারেন।",
                   "Only the owner can send Assisto SMS."),
    "bad_channel": (400, "এই পথ চেনা যায়নি।", "Unknown channel."),
    "no_due": (400, "এই গ্রাহকের কোনো বাকি নেই।", "This customer owes nothing."),
    "sms_not_configured": (503, "SMS গেটওয়ে যুক্ত নেই — WhatsApp দিয়ে পাঠান।",
                           "No SMS gateway yet — send it on WhatsApp."),
    "opted_out": (409, "এই গ্রাহক মেসেজ বন্ধ করেছেন (STOP)।", "This customer opted out (STOP)."),
    "quiet_hours": (409, "রাত ৯টা থেকে সকাল ৯টা Assisto নিজে কিছু পাঠায় না — চাইলে WhatsApp দিয়ে পাঠান।",
                    "Assisto sends nothing itself between 9 pm and 9 am — use WhatsApp if you want."),
    "phone_daily_cap": (429, "এই গ্রাহককে আজ আর SMS পাঠানো যাবে না।",
                        "No more SMS to this customer today."),
    "business_daily_cap": (429, "আজকের ব্যবসার SMS সীমা শেষ।", "Today's business SMS limit is reached."),
    "user_daily_cap": (429, "আজকের SMS সীমা শেষ।", "Today's SMS limit is reached."),
    "global_daily_cap": (429, "আজকের SMS সীমা শেষ। কাল আবার চেষ্টা করুন।",
                         "Today's SMS limit is reached. Try tomorrow."),
    "purpose_off": (503, "SMS রিমাইন্ডার এখন বন্ধ।", "SMS reminders are off right now."),
    "bad_phone": (400, "গ্রাহকের সঠিক মোবাইল নম্বর নেই।", "This customer has no valid mobile number."),
    "too_long": (400, "মেসেজ বেশি লম্বা।", "The message is too long."),
    "send_failed": (502, "SMS পাঠানো যায়নি — SMS ব্যালান্স ফেরত দেওয়া হয়েছে।",
                    "The SMS failed — your SMS balance was given back."),
    "guard_over": (503, "এখন SMS পাঠানো সাময়িক বন্ধ। কাল আবার চেষ্টা করুন।",
                   "SMS is paused for now. Try again tomorrow."),
    "empty": (400, "কিছু লিখুন।", "Write something."),
    "rate_limited": (429, "একটু পরে আবার পাঠান।", "Please wait a little before sending more."),
    "blocked": (409, "আপনি এই দোকান ব্লক করেছেন — মেসেজ পাঠাতে আগে আনব্লক করুন।",
                "You blocked this shop — unblock it first to send a message."),
    "not_verified": (403, "আপনার ফোন নম্বর যাচাই করা নেই।", "Your phone number isn't verified."),
    "not_found": (404, "পাওয়া যায়নি।", "Not found."),
}


def reason_body(reason, lang, **extra):
    st, bn, en = REASONS.get(reason, (400, "পাঠানো যায়নি।", "Couldn't send it."))
    body = {"ok": False, "reason": reason, "error": reason,
            "detail": en if lang == "en" else bn}
    body.update(extra)
    return st, body


# ------------------------------------------------------------------ helpers
def _now(now=None):
    return now or timezone.now()


def dhaka_day(now=None):
    from .logic import msg_guard as MG
    return MG.local(_now(now)).date()


def _canon(raw):
    from .phone import canonical_phone
    return canonical_phone(raw or "") or ""


def verified_phone_of(user):
    """The account's phone ONLY when it is OTP-verified (PhoneVerification
    for the very same number), else ''."""
    if user is None or not getattr(user, "is_active", False):
        return ""
    canon = _canon(getattr(user, "phone", ""))
    if not canon:
        return ""
    from .models import PhoneVerification
    pv = PhoneVerification.objects.filter(user=user).first()
    if pv is None or _canon(pv.phone) != canon:
        return ""
    return canon


def verified_user_for(canon):
    """The ONE active account whose OTP-verified number is `canon`, or None.
    Verified-only by design (owner rule): an unverified account that merely
    typed this number is never matched."""
    if not canon:
        return None
    from .models import PhoneVerification, User, UserPhoneHash
    from .phone import hash_canonical
    cands = []
    try:
        row = (UserPhoneHash.objects.select_related("user")
               .filter(phone_hash=hash_canonical(canon)).first())
        if row is not None:
            cands.append(row.user)
    except Exception:  # noqa: BLE001 — fall back to the verification table
        pass
    if not cands:
        local = "0" + canon[4:] if canon.startswith("+880") else canon
        ids = PhoneVerification.objects.filter(
            phone__in={canon, canon.lstrip("+"), local}).values_list("user_id", flat=True)
        cands = list(User.objects.filter(pk__in=list(ids)[:5]))
    for u in cands:
        if verified_phone_of(u) == canon:
            return u
    return None


def phone_key(party):
    return party.phone_canon or ("p:%d" % party.pk)


def pref(business, user):
    """(muted, blocked) the customer set for this shop."""
    if user is None:
        return (False, False)
    from .models import ShopPref
    p = ShopPref.objects.filter(user=user, business=business).first()
    return (bool(p and p.muted), bool(p and p.blocked))


def sent_today(business, key, now=None):
    from .models import TagadaSend
    return TagadaSend.objects.filter(business=business, phone_key=key,
                                     day=dhaka_day(now)).first()


def _opted_key(canon):
    from .logic.business_selling import normalize_phone
    return normalize_phone(canon) if canon else "\0"


def _opted_out(business, canon):
    if not canon:
        return False
    from .logic import msg_guard as MG
    from .logic.business_selling import normalize_phone
    try:
        return MG.is_opted_out(business.pk, normalize_phone(canon))
    except Exception:  # noqa: BLE001
        return False


def party_balance(party):
    rows = [{"direction": e.direction, "amount": e.amount_poisha}
            for e in party.entries.all()]
    return khata.running_balance(rows, party.book)


def invite_status(party, cust=None):
    """none | invited | joined (joined = the number is now a verified account)."""
    if cust is not None:
        return "joined"
    from .models import KhataInvite
    return "invited" if KhataInvite.objects.filter(party=party).exists() else "none"


def message_text(prof, party, bal, preset, pay_hint, lang):
    return khata.tagada_message({"name": party.name}, bal, shop_name=prof.shop_name,
                                preset=preset or "polite", pay_hint=pay_hint, lang=lang)


def prefetch(prof, parties, now=None):
    """One pass of lookups for a bulk send screen (500 customers must not be
    thousands of queries): verified accounts by number, the customers' shop
    prefs, today's sends and the invites."""
    from .models import KhataInvite, PhoneVerification, ShopPref, TagadaSend, User
    now = _now(now)
    canons = {p.phone_canon for p in parties if p.phone_canon}
    users = {}
    if canons:
        locals_ = {"0" + c[4:] for c in canons if c.startswith("+880")}
        pv = PhoneVerification.objects.filter(
            phone__in=canons | locals_ | {c.lstrip("+") for c in canons})
        for u in User.objects.filter(pk__in=pv.values_list("user_id", flat=True),
                                     is_active=True).select_related("phone_verification"):
            c = _canon(u.phone)
            if c in canons and _canon(u.phone_verification.phone) == c:
                users[c] = u
    prefs = {p.user_id: (p.muted, p.blocked) for p in ShopPref.objects.filter(
        business=prof, user__in=list(users.values()))}
    sent = {t.phone_key: t for t in TagadaSend.objects.filter(business=prof,
                                                             day=dhaka_day(now))}
    invited = set(KhataInvite.objects.filter(party__in=parties)
                  .values_list("party_id", flat=True))
    from .logic import msg_guard as MG
    try:
        opted = MG.opted_out_keys(prof.pk)
    except Exception:  # noqa: BLE001
        opted = set()
    return {"users": users, "prefs": prefs, "sent": sent, "invited": invited,
            "opted": opted}


def facts(prof, party, *, owner=True, text="", now=None, wallet=None, cust="?", pre=None):
    """Everything decide() needs for ONE customer, from the DB (or `pre`)."""
    from . import sms_segments, sms_service, sms_wallet
    from .logic import msg_guard as MG
    now = _now(now)
    canon = party.phone_canon or _canon(party.phone)
    if pre is not None:
        cust = pre["users"].get(canon)
        muted, blocked = pre["prefs"].get(cust.pk, (False, False)) if cust else (False, False)
        sent = pre["sent"].get(phone_key(party))
    else:
        if cust == "?":
            cust = verified_user_for(canon)
        muted, blocked = pref(prof, cust)
        sent = sent_today(prof, phone_key(party), now)
    parts = max(1, sms_segments.segments(text)) if text else 1
    w = wallet if wallet is not None else (sms_wallet.state(prof.user, now)
                                           if owner and prof.user_id else None)
    return {"canon": canon, "cust": cust, "assisto_user": cust is not None,
            "reachable": not blocked, "muted": muted, "sent": sent,
            "phone_ok": bool(khata.bd_msisdn(party.phone)),
            "opted_out": (_opted_key(canon) in pre["opted"]) if pre else _opted_out(prof, canon),
            "quiet": MG.in_quiet_hours(now),
            "sms_ready": sms_service.ready(), "parts": parts, "wallet": w,
            "owner": owner, "invited": (party.pk in pre["invited"]) if pre else None}


def _decide(f):
    w = f["wallet"] or {}
    return TR.decide(assisto_user=f["assisto_user"], reachable=f["reachable"],
                     phone_ok=f["phone_ok"], sent_today=f["sent"] is not None,
                     opted_out=f["opted_out"], quiet=f["quiet"],
                     sms_ready=f["sms_ready"], parts_needed=f["parts"],
                     parts_left=int(w.get("parts_left") or 0), owner=f["owner"])


def row_fields(prof, party, f):
    """The extra per-customer fields the send screen shows."""
    d = _decide(f)
    return {"assisto_user": f["assisto_user"], "reachable": f["reachable"],
            "sent_today": f["sent"] is not None,
            "sent_today_channel": f["sent"].channel if f["sent"] else "",
            "route": d["route"], "options": d["options"], "sms_parts": f["parts"],
            "invite_status": invite_status(party, f["cust"]) if f.get("invited") is None
            else ("joined" if f["cust"] else ("invited" if f["invited"] else "none"))}


def sms_offer(prof, owner, now=None):
    """The wallet line for the send screen (owner only)."""
    from . import sms_service, sms_wallet
    ready = sms_service.ready()
    w = sms_wallet.state(prof.user, now) if owner and prof.user_id else {}
    on_sale = any(p["on_sale"] for p in sms_wallet.packs()) if owner else False
    left = int(w.get("parts_left") or 0)
    return {"ready": ready, "owner_only": not owner, "available": ready and owner,
            "allowance_total": int(w.get("allowance_total") or 0),
            "allowance_left": int(w.get("allowance_left") or 0),
            "pack_left": int(w.get("pack_left") or 0), "parts_left": left,
            "low": bool(w.get("low")) if owner else False, "packs_on_sale": on_sale,
            "balance": left, "per_segment": 1, "unit": "sms_part"}


# ------------------------------------------------------------------ claims
def claim(prof, party, channel, *, parts=0, pay_hint=None, by=None, now=None):
    """Take today's ONE slot for this customer. None = already used today."""
    from .models import TagadaSend
    now = _now(now)
    try:
        with transaction.atomic():
            return TagadaSend.objects.create(
                business=prof, party=party, phone_key=phone_key(party),
                day=dhaka_day(now), channel=channel, parts=int(parts or 0),
                pay_hint=pay_hint or {}, by=by, created_at=now)
    except IntegrityError:
        return None


def unclaim(row):
    if row is not None and row.pk:
        type(row).objects.filter(pk=row.pk).delete()


# ------------------------------------------------------------------ push
def _push(user, title_bn, title_en, body_bn, body_en, data):
    from . import push
    try:
        return push.push_to_user_async(user, "dues", title_bn, title_en, body_bn, body_en,
                                       data=data)
    except Exception:  # noqa: BLE001 — the in-app message is already saved
        log.warning("tagada2: push failed", exc_info=True)
        return False


def _shop_name(prof, lang="bn"):
    n = (prof.shop_name or "").strip()
    if n:
        return n
    return "Shop" if lang == "en" else "দোকান"


# ------------------------------------------------------------------ send
def send(prof, party, *, channel, owner, preset="polite", pay_hint=None, lang="bn",
         by=None, now=None):
    """Send ONE tagada on `channel`. Returns (http_status, body)."""
    from . import push as P
    from . import sms_service, sms_wallet
    from .models import KhataChat
    now = _now(now)
    if channel not in TR.CHANNELS:
        return reason_body("bad_channel", lang)
    bal = party_balance(party)
    if bal <= 0:
        return reason_body("no_due", lang)
    canon = party.phone_canon or _canon(party.phone)
    cust = verified_user_for(canon)
    text_lang = P.user_lang(cust) if (channel == "assisto" and cust) else lang
    text = message_text(prof, party, bal, preset, pay_hint, text_lang)
    f = facts(prof, party, owner=owner, text=text, now=now, cust=cust)
    why = TR.refusal(channel, assisto_user=f["assisto_user"], reachable=f["reachable"],
                     phone_ok=f["phone_ok"], sent_today=f["sent"] is not None,
                     opted_out=f["opted_out"], quiet=f["quiet"], sms_ready=f["sms_ready"],
                     parts_needed=f["parts"],
                     parts_left=int((f["wallet"] or {}).get("parts_left") or 0),
                     owner=owner)
    if why:
        extra = {"sms": sms_offer(prof, owner, now)} if channel == "gateway_sms" else {}
        return reason_body(why, lang, **extra)
    row = claim(prof, party, channel, parts=f["parts"] if channel == "gateway_sms" else 0,
                pay_hint=pay_hint, by=by, now=now)
    if row is None:
        return reason_body("daily_limit", lang)
    base = {"ok": True, "channel": channel, "message": text,
            "balance_poisha": bal, "balance_display": khata.fmt_amount(bal)}

    if channel == "assisto":
        KhataChat.objects.create(business=prof, party=party, customer=cust, sender="shop",
                                 kind="tagada", text=text[:CHAT_MAX_CHARS], sent_by=by,
                                 created_at=now)
        pushed = False
        if not f["muted"]:
            shop = _shop_name(prof, P.user_lang(cust))
            amt = khata.fmt_amount(bal)
            pushed = _push(cust, "বাকির কথা: %s" % shop, "Due reminder: %s" % shop,
                           "%s বাকি — দেখুন ও পরিশোধ করুন।" % amt["bn"],
                           "%s due — see it and pay." % amt["en"],
                           {"route": "my_dues", "business_id": prof.pk})
        return 200, {**base, "free": True, "pushed": bool(pushed)}

    if channel in ("whatsapp", "own_sms"):
        url = khata.wa_link(party.phone, text) if channel == "whatsapp" \
            else khata.sms_uri(party.phone, text)
        return 200, {**base, "free": True, "url": url}

    # gateway_sms — paid in SMS parts, never without balance
    ref = "tagada:%d:%s" % (party.pk, row.day.isoformat())
    res = sms_wallet.reserve(prof.user, f["parts"], ref=ref, now=now)
    if res is None:
        unclaim(row)
        return reason_body("no_balance", lang, sms=sms_offer(prof, owner, now))
    r = sms_service.send_sms(party.phone, text, "tagada", user=prof.user, business=prof,
                             now=now, prepaid=True)
    if not r["ok"]:
        sms_wallet.release(prof.user, res, now)
        unclaim(row)
        return reason_body(r["reason"], lang, segments=r["segments"],
                           sms=sms_offer(prof, owner, now))
    if r["segments"] and r["segments"] != row.parts:
        type(row).objects.filter(pk=row.pk).update(parts=r["segments"])
    return 200, {**base, "free": False, "parts": f["parts"],
                 "from_allowance": res["allowance"], "from_pack": res["pack"],
                 "provider": r["provider"], "sms": sms_offer(prof, owner, now)}


# ------------------------------------------------------------------ invite
def invite(prof, party, owner_user, lang="bn"):
    """Create (or re-send) an Assisto invite for a khata customer."""
    from . import invite_join as IJ
    from .models import KhataInvite
    cust = verified_user_for(party.phone_canon or _canon(party.phone))
    if cust is not None:
        KhataInvite.objects.filter(party=party, joined_user__isnull=True).update(
            joined_user=cust, joined_at=timezone.now())
        return {"status": "joined"}
    inv = KhataInvite.objects.filter(party=party).first()
    ci = IJ.find(inv.code) if inv and inv.code else None
    if ci is None or IJ.state_of(ci) != "ok":
        if not IJ.create_rate_ok(owner_user):
            return {"status": "rate_limited"}
        ci = IJ.create_invite(owner_user, relation="friend", max_uses=1,
                              label=("khata:%s" % party.name)[:60])
    else:
        IJ.resend(ci)
    if inv is None:
        inv = KhataInvite.objects.create(party=party, code=ci.code)
    else:
        inv.code, inv.invited_at, inv.times = ci.code, timezone.now(), inv.times + 1
        inv.save(update_fields=["code", "invited_at", "times"])
    shop = _shop_name(prof, lang)
    link = IJ.link_for(ci.code)
    if lang == "en":
        text = ("%s uses Assisto for its khata. Join Assisto to see your dues, pay "
                "by bKash/Nagad and chat with the shop — reminders then come free "
                "inside the app, no SMS. Tap: %s" % (shop, link))
    else:
        text = ("%s তাদের খাতা Assisto-তে রাখে। Assisto-তে যোগ দিলে আপনার বাকি দেখতে, "
                "বিকাশ/নগদে পরিশোধের ধাপ পেতে আর দোকানের সাথে চ্যাট করতে পারবেন — "
                "তাগাদা তখন অ্যাপের ভেতরে বিনা খরচে আসবে, SMS লাগবে না। ট্যাপ করুন: %s"
                % (shop, link))
    return {"status": "invited", "code": ci.code, "link": link, "share_text": text,
            "invited_at": inv.invited_at.isoformat(),
            "wa_url": khata.wa_link(party.phone, text),
            "sms_uri": khata.sms_uri(party.phone, text)}


# ------------------------------------------------------------------ chat
def _msg_row(m):
    return {"id": m.pk, "from": m.sender, "kind": m.kind, "text": m.text,
            "at": m.created_at.isoformat(), "read": m.read_at is not None}


def _thread(prof, cust, limit=200):
    from .models import KhataChat
    qs = KhataChat.objects.filter(business=prof, customer=cust).order_by("-created_at", "-id")
    return [_msg_row(m) for m in reversed(list(qs[:limit]))]


def _mark_read(prof, cust, sender, now):
    from .models import KhataChat
    KhataChat.objects.filter(business=prof, customer=cust, sender=sender,
                             read_at__isnull=True).update(read_at=now)


def _recent(prof, cust, sender, now):
    from .models import KhataChat
    return KhataChat.objects.filter(business=prof, customer=cust, sender=sender,
                                    created_at__gte=now - timedelta(hours=1)).count()


def shop_chat(prof, party, now=None):
    now = _now(now)
    cust = verified_user_for(party.phone_canon or _canon(party.phone))
    _, blocked = pref(prof, cust)
    out = {"assisto_user": cust is not None, "reachable": not blocked,
           "party": {"id": party.pk, "name": party.name}, "messages": []}
    if cust is not None:
        _mark_read(prof, cust, "customer", now)
        out["messages"] = _thread(prof, cust)
    return out


def shop_chat_post(prof, party, text, by=None, lang="bn", now=None):
    from .models import KhataChat
    now = _now(now)
    text = str(text or "").strip()[:CHAT_MAX_CHARS]
    if not text:
        return reason_body("empty", lang)
    cust = verified_user_for(party.phone_canon or _canon(party.phone))
    if cust is None:
        return reason_body("not_assisto_user", lang)
    muted, blocked = pref(prof, cust)
    if blocked:
        return reason_body("not_reachable", lang)
    if _recent(prof, cust, "shop", now) >= SHOP_MSGS_PER_HOUR:
        return reason_body("rate_limited", lang)
    m = KhataChat.objects.create(business=prof, party=party, customer=cust, sender="shop",
                                 kind="text", text=text, sent_by=by, created_at=now)
    if not muted:
        from . import push as P
        shop = _shop_name(prof, P.user_lang(cust))
        _push(cust, shop, shop, text[:120], text[:120],
              {"route": "my_dues", "business_id": prof.pk, "open": "chat"})
    return 200, {"ok": True, "message": _msg_row(m)}


# ------------------------------------------------------------------ My Dues
def my_parties(user, business=None):
    """The customer-book parties recorded under this account's VERIFIED number."""
    from .models import KhataParty
    canon = verified_phone_of(user)
    if not canon:
        return canon, KhataParty.objects.none()
    qs = (KhataParty.objects.filter(phone_canon=canon, book=khata.CUSTOMER, archived=False)
          .exclude(business__user=user).select_related("business"))
    if business is not None:
        qs = qs.filter(business=business)
    return canon, qs


def _mask(canon):
    if not canon:
        return ""
    local = "0" + canon[4:] if canon.startswith("+880") else canon
    return local[:3] + "•" * max(0, len(local) - 6) + local[-3:]


def my_dues(user, lang="bn"):
    from .models import KhataChat, KhataEntry, ShopPref
    canon, parties = my_parties(user)
    if not canon:
        return {"verified": False, "phone_masked": "", "shops": [],
                "total_display": khata.fmt_amount(0)}
    parties = list(parties)
    pids = [p.pk for p in parties]
    agg = {r["party_id"]: r for r in KhataEntry.objects.filter(party_id__in=pids)
           .values("party_id")
           .annotate(up=Sum("amount_poisha", filter=Q(direction="gave")),
                     down=Sum("amount_poisha", filter=Q(direction="got")),
                     last=Max("at"), n=Count("id"))}
    by_biz = {}
    for p in parties:
        a = agg.get(p.pk)
        if not a or not a["n"]:
            continue                      # nothing recorded for me there
        d = by_biz.setdefault(p.business_id, {"prof": p.business, "bal": 0, "last": None})
        d["bal"] += int(a["up"] or 0) - int(a["down"] or 0)
        if a["last"] and (d["last"] is None or a["last"] > d["last"]):
            d["last"] = a["last"]
    unread = dict(KhataChat.objects.filter(customer=user, sender="shop", read_at__isnull=True)
                  .values_list("business_id").annotate(n=Count("id")))
    prefs = {p.business_id: p for p in ShopPref.objects.filter(user=user,
                                                               business_id__in=list(by_biz))}
    shops, total = [], 0
    for bid, d in by_biz.items():
        pr = prefs.get(bid)
        bal = d["bal"]
        total += max(0, bal)
        shops.append({"business_id": bid, "shop_name": _shop_name(d["prof"], lang),
                      "balance_poisha": bal, "balance_display": khata.fmt_amount(abs(bal)),
                      "status": _my_status(bal), "owes": bal > 0,
                      "last_entry_at": d["last"].isoformat() if d["last"] else None,
                      "unread": int(unread.get(bid, 0)),
                      "muted": bool(pr and pr.muted), "blocked": bool(pr and pr.blocked)})
    shops.sort(key=lambda s: (not s["owes"], -s["balance_poisha"], s["shop_name"]))
    return {"verified": True, "phone_masked": _mask(canon), "shops": shops,
            "total_display": khata.fmt_amount(total)}


def _my_status(bal):
    """From the CUSTOMER's side (the shop's book is the other way round)."""
    if bal > 0:
        return {"bn": "আপনার বাকি", "en": "You owe"}
    if bal < 0:
        return {"bn": "দোকানের কাছে আপনার জমা", "en": "Your advance with the shop"}
    return {"bn": "কোনো বাকি নেই", "en": "All settled"}


def _pay_methods(prof, parties):
    """Where the shop takes money: its own bKash/Nagad merchant (OwnerWallet)
    first, then the pay-to number it put on its latest reminder."""
    from .models import OwnerWallet, TagadaSend
    out, seen = [], set()
    for w in OwnerWallet.objects.filter(business=prof).exclude(merchant_number=""):
        key = (w.provider, khata.normalize_digits(w.merchant_number))
        if key not in seen:
            seen.add(key)
            out.append({"provider": w.provider, "number": key[1], "kind": "merchant"})
    last = (TagadaSend.objects.filter(business=prof, party__in=parties)
            .exclude(pay_hint={}).order_by("-created_at").first())
    if last and isinstance(last.pay_hint, dict):
        m = str(last.pay_hint.get("method") or "").strip().lower()
        n = khata.normalize_digits(str(last.pay_hint.get("number") or "")).strip()
        prov = m if m in ("bkash", "nagad", "rocket") else ""
        if prov and n and (prov, n) not in seen:
            out.append({"provider": prov, "number": n, "kind": "personal"})
    return out


def my_shop(user, prof, lang="bn"):
    from .models import KhataEntry
    canon, qs = my_parties(user, prof)
    if not canon:
        return reason_body("not_verified", lang)
    parties = list(qs)
    if not parties:
        return reason_body("not_found", lang)
    ents = list(KhataEntry.objects.filter(party__in=parties).order_by("-at", "-id")
                [:ENTRIES_SHOWN])
    if not ents:
        return reason_body("not_found", lang)
    bal = sum(party_balance(p) for p in parties)
    muted, blocked = pref(prof, user)
    return 200, {"shop": {"id": prof.pk, "name": _shop_name(prof, lang)},
                 "balance_poisha": bal, "balance_display": khata.fmt_amount(abs(bal)),
                 "status": _my_status(bal), "owes": bal > 0,
                 "entries": [{"at": e.at.isoformat(),
                              "kind": "due" if e.direction == "gave" else "paid",
                              "amount_display": khata.fmt_amount(e.amount_poisha),
                              "note": e.note} for e in ents],
                 "pay": {"methods": _pay_methods(prof, parties),
                         "amount_display": khata.fmt_amount(max(0, bal))},
                 "muted": muted, "blocked": blocked}


def set_pref(user, prof, muted=None, blocked=None):
    from .models import ShopPref
    p, _ = ShopPref.objects.get_or_create(user=user, business=prof)
    if muted is not None:
        p.muted = bool(muted)
    if blocked is not None:
        p.blocked = bool(blocked)
    p.save()
    return {"muted": p.muted, "blocked": p.blocked}


def customer_chat(user, prof, now=None, lang="bn"):
    now = _now(now)
    _, blocked = pref(prof, user)
    _mark_read(prof, user, "shop", now)
    return {"shop": {"id": prof.pk, "name": _shop_name(prof, lang)}, "blocked": blocked,
            "messages": _thread(prof, user)}


def customer_chat_post(user, prof, text, lang="bn", now=None):
    from .models import KhataChat
    now = _now(now)
    text = str(text or "").strip()[:CHAT_MAX_CHARS]
    if not text:
        return reason_body("empty", lang)
    canon, qs = my_parties(user, prof)
    if not canon:
        return reason_body("not_verified", lang)
    party = qs.order_by("id").first()
    if party is None:
        return reason_body("not_found", lang)
    _, blocked = pref(prof, user)
    if blocked:
        return reason_body("blocked", lang)
    if _recent(prof, user, "customer", now) >= CUSTOMER_MSGS_PER_HOUR:
        return reason_body("rate_limited", lang)
    m = KhataChat.objects.create(business=prof, party=party, customer=user,
                                 sender="customer", kind="text", text=text, created_at=now)
    if prof.user_id:
        _push(prof.user, "খাতা: %s" % party.name, "Khata: %s" % party.name,
              text[:120], text[:120],
              {"route": "business/khata", "party_id": party.pk, "business_id": prof.pk,
               "party_name": party.name[:60], "open": "chat"})
    return 200, {"ok": True, "message": _msg_row(m)}
