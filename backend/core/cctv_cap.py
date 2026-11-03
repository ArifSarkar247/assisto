"""cctvcap (owner decision 3 Nov 10:40): the CCTV monthly caps, glue.

Pure rules: core/logic/cctv_cap.py. Storage: the cctvguard month doc
(core/cctv_traffic.py, PaCollectionItem "cctv_traffic") — no migration.

  * ONE shared AI counter per account per month. EVERY paid AI call on a
    CCTV photo goes through `ai_try_take()` first (tests_cctvcap guards
    that no CCTV module calls the vision provider without it). Fail-closed:
    any error = no paid call (the honest template text is used instead).
  * Relay cap state comes from cctv_traffic.account_state (pool + packs).
  * One push per month per kind when a cap is reached (`maybe_push`).
  * Extra packs for THIS month, paid with credits (`buy_pack`); a Play
    one-time product per pack is the later seam (CP.PACK_PLAY_PRODUCTS).

Never touches alerts, photos, evidence, clips or SOS — those never stop.
"""
import logging

from django.utils import timezone

from . import cctv_traffic as CT
from .logic import cctv_cap as C
from .logic import cctv_plan as CP
from .logic import cctv_traffic as T

log = logging.getLogger("assisto.cctvcap")


# ---------------------------------------------------------------- config
def plan_cfg():
    try:
        from . import billing
        raw = billing.cfg().get("cctv_plan")
    except Exception:
        raw = None
    return CP.normalize_cfg(raw)


def ai_per_camera():
    return int(plan_cfg()["ai_checks_per_camera"])


def credit_bdt():
    try:
        from . import billing
        return float(billing.cfg().get("credit_bdt") or 1.0)
    except Exception:
        return 1.0


def _oid(owner):
    return getattr(owner, "pk", owner)


# ---------------------------------------------------------------- AI counter
def _legacy_used(owner_id, month):
    """Before cctvcap each site counted its own AI descriptions
    (site.guard._activity.ai). The shared counter starts from their sum the
    first time it is used in a month, so nothing is counted twice or lost."""
    try:
        from . import cctv_activity as A
        from .models import ShopSite
        used = 0
        for s in ShopSite.objects.filter(owner_id=owner_id).only("id", "guard"):
            a = A.act_of(s).get("ai") or {}
            if a.get("month") == month:
                used += int(a.get("used", 0) or 0)
        return used
    except Exception:
        return 0


def ai_cap(owner_id, doc=None, now=None):
    doc = doc if doc is not None else CT.month_doc(_oid(owner_id), now)
    base = max(0, ai_per_camera()) * max(0, CT.n_cameras(_oid(owner_id)))
    return base + C.extra(doc)["ai"]


def ai_used(owner_id, now=None, doc=None):
    owner_id = _oid(owner_id)
    now = now or timezone.now()
    doc = doc if doc is not None else CT.month_doc(owner_id, now)
    if "ai_used" in doc:
        return int(doc.get("ai_used") or 0)
    return _legacy_used(owner_id, doc.get("month") or T.month_key(now))


def ai_state(owner_id, now=None, doc=None):
    owner_id = _oid(owner_id)
    doc = doc if doc is not None else CT.month_doc(owner_id, now)
    return C.ai_state(ai_used(owner_id, now, doc), ai_cap(owner_id, doc))


def ai_try_take(owner, now=None):
    """Take ONE AI check for `owner` before a paid AI call. True = go ahead;
    False = the cap is reached (or anything failed): use the template."""
    owner_id = _oid(owner)
    now = now or timezone.now()
    try:
        doc0 = CT.month_doc(owner_id, now)
        legacy = None if "ai_used" in doc0 else _legacy_used(owner_id, doc0.get("month"))
        cap = ai_cap(owner_id, doc0)
        out = {"ok": False}

        def fn(doc):
            if "ai_used" not in doc:
                doc["ai_used"] = int(legacy or 0)
            # packs bought between our read and the lock count too
            c = cap - C.extra(doc0)["ai"] + C.extra(doc)["ai"]
            if not C.ai_can_take(doc, c):
                return doc
            out["ok"] = True
            out["state"] = C.ai_state(int(doc["ai_used"]) + 1, c)
            return C.ai_take(doc)
        CT._update(owner_id, now, fn)
        st = out.get("state") or C.ai_state(cap, cap)
        if st["level"] == "full":
            maybe_push(owner_id, "ai", "full", now)
        return out["ok"]
    except Exception:
        log.exception("ai cap check failed (no paid call)")
        return False


# ---------------------------------------------------------------- push once
def maybe_push(owner_id, kind, level, now=None):
    """ONE push per month per kind when a cap is reached. Never raises."""
    owner_id = _oid(owner_id)
    now = now or timezone.now()
    try:
        if not C.push_due(CT.month_doc(owner_id, now), kind, level):
            return False
        month = T.month_key(now)
        claimed = {"ok": False}

        def fn(doc):
            if C.push_due(doc, kind, level):
                claimed["ok"] = True
                return C.mark_pushed(doc, kind, month)
            return doc
        CT._update(owner_id, now, fn)
        if not claimed["ok"]:
            return False
        from .models import User
        from .push import push_to_user
        user = User.objects.filter(pk=owner_id).first()
        if user is None:
            return False
        tb, bb = C.push_text(kind, "bn")
        te, be = C.push_text(kind, "en")
        push_to_user(user, "shop_alert", tb, te, bb, be,
                     data={"type": "cctv_cap", "cap": kind, "route": "watchman"})
        try:
            # the in-app feed row too (the push may be off on this phone)
            from .models import NotifEvent
            NotifEvent.objects.create(user=user, type="business", title_bn=tb, title_en=te,
                                      body_bn=bb, body_en=be, route="watchman",
                                      meta={"cctv_cap": kind, "month": month})
        except Exception:
            pass
        return True
    except Exception:
        log.exception("cap push failed")
        return False


def relay_after(owner_id, st, now=None):
    """After any relay traffic was added: push once when the cap is hit."""
    if st and st.get("enforced") and st.get("level") == "paused":
        return maybe_push(owner_id, "relay", "paused", now)
    return False


# ---------------------------------------------------------------- the app
def status(owner, now=None, lang="bn"):
    """What the camera screen shows: relay + AI, notices, the packs."""
    now = now or timezone.now()
    owner_id = _oid(owner)
    c = plan_cfg()
    doc = CT.month_doc(owner_id, now)
    rs = CT.account_state(owner_id, now, doc=doc)
    ai = ai_state(owner_id, now, doc)
    ex = C.extra(doc)
    cb = credit_bdt()
    packs = []
    for k, p in CP.packs(c).items():
        packs.append(dict(p, credits=C.credits_for(p["price_bdt"], cb)))
    return {
        "month": doc.get("month"),
        "enforced": rs["enforced"],
        "relay": {"level": rs["level"], "pct": rs["pct"], "cap_mb": rs["cap_mb"],
                  "used_mb": T.mb(rs["used_bytes"]), "extra_mb": ex["relay_mb"],
                  "message": T.messages(rs["level"], rs["pct"], lang)},
        "ai": {"level": ai["level"], "pct": ai["pct"], "cap": ai["cap"], "used": ai["used"],
               "left": ai["left"], "extra": ex["ai"],
               "message": C.ai_message(ai["level"], ai["pct"], lang)},
        "packs": packs,
        "balance": int(getattr(owner, "ai_credits", 0) or 0) if hasattr(owner, "pk") else None,
        "safety_note": ("SOS, সতর্কতা, ছবি ও প্রমাণ কখনো থামে না।" if lang == "bn" else
                        "SOS, alerts, photos and evidence never stop."),
    }


def buy_pack(user, kind, now=None):
    """Debit credits and add the pack to THIS month. -> (ok, info). info is
    {"code": ...} on failure ("bad_kind" | "no_credits" | "failed")."""
    now = now or timezone.now()
    if kind not in CP.PACK_KINDS:
        return False, {"code": "bad_kind"}
    c = plan_cfg()
    p = CP.packs(c)[kind]
    need = C.credits_for(p["price_bdt"], credit_bdt())
    size = p["mb"] if kind == "relay" else p["checks"]
    from . import credits as CR
    res = CR.spend(user, need, note=("cctv_extra_%s %s" % (kind, T.month_key(now)))[:120],
                   now=now, source_type="spend")
    if not res.get("ok"):
        return False, {"code": "no_credits", "credits_needed": need}
    ref = str(res.get("spend_ref") or "")
    try:
        CT._update(user.pk, now, lambda d: C.add_pack(d, kind, size, need, ref,
                                                       int(now.timestamp())))
    except Exception:
        log.exception("extra pack grant failed — returning the credits")
        try:
            CR.return_spend(user, ref, note="cctv_extra_failed")
        except Exception:
            log.exception("return_spend failed")
        return False, {"code": "failed"}
    return True, {"kind": kind, "size": size, "charged_credits": need}
