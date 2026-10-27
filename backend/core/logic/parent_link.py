"""
parent_link.py — Assisto "link a parent (or any loved one) in under 2 minutes"
logic for ONBOARDING.  Pure Python, no AI key, deterministic, unit-testable.

WHY THIS EXISTS (SPEC v2.1 §21 — ADVANCED onboarding):
  A child enters a parent's phone number during onboarding and we offer every
  honest way to get that parent connected — WITHOUT a server SMS gateway, WITHOUT
  auto-sending anything, and WITHOUT pretending a feature phone can run the app.

  This module does NOT send anything.  It composes *descriptors* (plain dicts)
  the app turns into a `tel:` / `sms:` intent, a QR image, or a copy-link, reusing
  the already-shipped primitives:
    - circle.make_invite_token / parse_invite_token  (signed, single-use, expiring)
    - circle.qr_payload                               (the deep link encoded in QR)
    - msg_contacts.invite_non_user_sms                (OWN-SIM sms: URI, user sends)
    - msg_contacts.invite_non_user_share_link         (OS share sheet)

THE FOUR CHANNELS (honest, no dead taps):
  - call      — always available: open the dialer (`tel:`).  Human invite.
  - sms       — always available: OWN-SIM prefilled composer (no SEND_SMS perm,
                no gateway, never auto-sent — the USER presses send).
  - qr        — always available: a signed invite deep link rendered as a QR the
                parent scans with the app.  (Needs the parent to have a smartphone.)
  - ivr       — 🔑 KEY-GATED and HONEST: an automated voice call that reads the
                invite aloud for a FEATURE phone.  This requires a telephony/IVR
                provider the owner must configure (integrations slug "ivr").  Until
                then the channel is returned with available=False and a clear,
                bilingual "Available when ___" reason — the UI shows it locked, not
                as a working button.

The validity window is short (default 24h) so a stray screenshot can't link a
stranger later.  Self-invite (linking your own number) is refused.
"""
from __future__ import annotations

import re

from core.logic.circle import (
    make_invite_token,
    normalize_relation,
    qr_payload,
    reciprocal_relation,
    relation_label,
    pick,
)

# Channels we can offer.  CALL/SMS/QR need no server infra; IVR needs a provider.
CH_CALL = "call"
CH_SMS = "sms"
CH_QR = "qr"
CH_IVR = "ivr"
CHANNELS = (CH_CALL, CH_SMS, CH_QR, CH_IVR)

ERR_NO_PHONE = "phone_required"
ERR_BAD_PHONE = "phone_invalid"
ERR_SELF = "self_link"
OK = "ok"

# A permissive BD-friendly phone check: digits (optionally +, spaces, dashes),
# at least 6 significant digits so "123" can't slip through.  We do NOT force a
# country format — the user may link an international parent.
_DIGITS = re.compile(r"\d")


def normalize_phone(raw):
    """Trim and strip formatting spaces/dashes/parens, keep a leading '+'.
    Returns '' for empty.  Does not validate length (see validate_phone)."""
    s = (raw or "").strip()
    if not s:
        return ""
    plus = s.startswith("+")
    digits = "".join(_DIGITS.findall(s))
    return ("+" + digits) if plus else digits


def validate_phone(raw, *, own_number=None):
    """Return (ok, err).  Rejects empty, too-short, or the user's own number
    (you can't link yourself as your own parent)."""
    n = normalize_phone(raw)
    if not n:
        return False, ERR_NO_PHONE
    if len(_DIGITS.findall(n)) < 6:
        return False, ERR_BAD_PHONE
    if own_number and normalize_phone(own_number) == n:
        return False, ERR_SELF
    return True, OK


def invite_message_text(inviter_name, link, lang="bn"):
    """The prefilled, user-editable invite body for call-notes / SMS / copy-link.
    Bilingual, never auto-sent.  Mentions it's a family-care invite so the parent
    understands who and why."""
    return pick(
        lang,
        f"{inviter_name} আপনাকে Assisto-তে পরিবার হিসেবে যুক্ত হতে আমন্ত্রণ "
        f"জানিয়েছেন — ওষুধের রিমাইন্ডার, নিরাপদ যাত্রা ও জরুরি সাহায্যের জন্য। "
        f"যুক্ত হোন: {link}",
        f"{inviter_name} invited you to join their family on Assisto — for "
        f"medicine reminders, safe-journey and emergency help. Connect: {link}",
    )


def ivr_gate_reason(lang="bn"):
    """Honest 'Available when ___' string for the key-gated IVR channel."""
    return pick(
        lang,
        "ফিচার ফোনে স্বয়ংক্রিয় ভয়েস-কল আমন্ত্রণ চালু হবে যখন একটি IVR/"
        "ভয়েস-কল প্রোভাইডার যুক্ত করা হবে।",
        "Automated voice-call invites for feature phones become available once "
        "an IVR / voice-call provider is connected.",
    )


def channel_label(channel, lang="bn"):
    labels = {
        CH_CALL: ("কল করে বলুন", "Call & tell them"),
        CH_SMS: ("SMS পাঠান", "Send an SMS"),
        CH_QR: ("QR দেখান", "Show a QR"),
        CH_IVR: ("ভয়েস-কল (ফিচার ফোন)", "Voice call (feature phone)"),
    }
    bn, en = labels.get(channel, (channel, channel))
    return pick(lang, bn, en)


def channel_hint(channel, lang="bn"):
    """One honest line under each channel so the user knows what tapping does."""
    hints = {
        CH_CALL: ("তাদের ফোনে কল করে নিজে বলুন।",
                  "Opens your dialer so you can tell them yourself."),
        CH_SMS: ("আপনার নিজের SIM থেকে — মেসেজ আগে থেকে লেখা, আপনি Send চাপবেন।",
                 "From your own SIM — the text is prefilled, you press Send."),
        CH_QR: ("স্মার্টফোনে Assisto দিয়ে স্ক্যান করলেই যুক্ত।",
                "They scan it with Assisto on a smartphone to connect."),
        CH_IVR: ("ফিচার ফোনের জন্য স্বয়ংক্রিয় ভয়েস-কল।",
                 "An automated voice call for a basic (feature) phone."),
    }
    bn, en = hints.get(channel, ("", ""))
    return pick(lang, bn, en)


def build_parent_link(inviter_id, inviter_name, parent_phone, *, relation_code="parent",
                      secret="", lang="bn", base_url="https://assisto.asalify.com",
                      ivr_enabled=False, own_number=None, ttl_minutes=1440):
    """Compose the full "link a parent" result for the onboarding step.

    Returns either:
      {"ok": False, "error": <ERR_*>}                      — bad/own/empty phone
    or:
      {"ok": True, "phone", "relation", "relation_label",
       "reciprocal", "token", "invite_link", "qr_payload", "message",
       "channels": [ {channel, label, hint, available, action, uri?, reason?} ... ]}

    Every channel declares `available` explicitly so the app NEVER renders a dead
    tap: CALL/SMS/QR are available=True; IVR is available == ivr_enabled, with a
    bilingual `reason` when locked.  `relation_code` defaults to 'parent' but the
    same builder links any loved one (child picks 'father'/'mother'/etc.).
    """
    ok, err = validate_phone(parent_phone, own_number=own_number)
    if not ok:
        return {"ok": False, "error": err}

    phone = normalize_phone(parent_phone)
    rel = normalize_relation(relation_code)
    token = make_invite_token(inviter_id, rel, secret, ttl_minutes=ttl_minutes)
    link = qr_payload(token, base_url=base_url)
    message = invite_message_text(inviter_name, link, lang)

    def ch(channel, available, action, **extra):
        d = {
            "channel": channel,
            "label": channel_label(channel, lang),
            "hint": channel_hint(channel, lang),
            "available": bool(available),
            "action": action,
        }
        d.update(extra)
        if not available and "reason" not in d:
            d["reason"] = None
        return d

    # Build the SMS own-SIM URI via the shipped messenger helper (reuse, not dup).
    from core.logic.msg_contacts import invite_non_user_sms
    sms_desc = invite_non_user_sms(inviter_name, link, phone, lang=lang)

    channels = [
        ch(CH_CALL, True, "dial", uri=f"tel:{phone}"),
        ch(CH_SMS, True, "sms_own_sim", uri=sms_desc["sms_uri"],
           requires_send_sms_permission=False, uses_gateway=False, auto_sent=False),
        ch(CH_QR, True, "show_qr", qr=link),
        ch(CH_IVR, ivr_enabled,
           "ivr_call" if ivr_enabled else "locked",
           reason=None if ivr_enabled else ivr_gate_reason(lang)),
    ]

    return {
        "ok": True,
        "phone": phone,
        "relation": rel,
        "relation_label": relation_label(rel, lang),
        "reciprocal": reciprocal_relation(rel),
        "token": token,
        "invite_link": link,
        "qr_payload": link,
        "message": message,
        "channels": channels,
    }


# ---------------------------------------------------------------------------
# Onboarding role → tailored "first win" (the <60s wow)
# ---------------------------------------------------------------------------
# The user picks WHO THEY ARE; we tailor the first thing we invite them to do so
# value is immediate and relevant.  Returned as a descriptor the app maps to a
# real screen (no simulation).

ROLE_SELF = "self"
ROLE_PARENT = "parent"       # caring for an elderly parent
ROLE_FAMILY = "family"
ROLE_BUSINESS = "business"
ROLES = (ROLE_SELF, ROLE_PARENT, ROLE_FAMILY, ROLE_BUSINESS)

# first-win target codes (the app owns the screen mapping)
WIN_MEDICINE = "medicine"
WIN_BILL = "bill"
WIN_JOURNEY = "journey"
WIN_EXPENSE = "expense"
# truth (owner 27 Oct): a business owner's first win is the real Digital
# Khata (add the first customer), not the vault "scan a bill" tile — the
# vault does not read amounts and OCR needs a key.
WIN_LEDGER = "ledger"


def normalize_role(role):
    r = (role or "").strip().lower()
    return r if r in ROLES else ROLE_SELF


def role_label(role, lang="bn"):
    labels = {
        ROLE_SELF: ("আমি নিজের জন্য", "For myself"),
        ROLE_PARENT: ("বয়স্ক বাবা-মায়ের যত্ন", "Caring for an elderly parent"),
        ROLE_FAMILY: ("পুরো পরিবারের জন্য", "For my whole family"),
        ROLE_BUSINESS: ("আমার ব্যবসার জন্য", "For my business"),
    }
    bn, en = labels.get(normalize_role(role), labels[ROLE_SELF])
    return pick(lang, bn, en)


def first_win_for_role(role):
    """The single most relevant first win per role (code the app maps to a screen)."""
    return {
        ROLE_SELF: WIN_JOURNEY,       # a safe-journey check-in is a fast self-win
        ROLE_PARENT: WIN_MEDICINE,    # add a parent's medicine reminder
        ROLE_FAMILY: WIN_MEDICINE,
        ROLE_BUSINESS: WIN_LEDGER,    # add the first khata customer
    }[normalize_role(role)]


def should_prompt_parent_link(role):
    """Only push the parent-link step hard for parent/family roles; others can
    still reach it but it isn't the headline."""
    return normalize_role(role) in (ROLE_PARENT, ROLE_FAMILY)
