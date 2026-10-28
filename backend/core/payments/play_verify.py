"""pricing-40 (owner 27 Oct night): "each new SKU stays not purchasable until
its Play product exists and is verified active through the API".

For every GATED sku (catalog.is_gated: Plus, Premium Pro, the new packs,
Probashi) the server asks the Play Developer API (the same service account
and _api seam as core/payments/play.py — read-only GETs, nothing is created
or changed in Play):

  subscription  GET applications/{pkg}/subscriptions/{productId}
                -> ok when the base plan {basePlanId} has state ACTIVE
  one-time pack GET applications/{pkg}/inappproducts/{sku}  -> status "active"
                (fallback: GET .../oneTimeProducts/{productId} -> a purchase
                option in state ACTIVE)

The result is stored per sku (PlaySkuCheck) and cached 60 s per process;
catalog.price() sells a gated sku only while its row says ok. Re-checked by
billing_daily, `manage.py play_sku_verify` and the Owner Admin "Re-check"
button. Never raises into the caller; Play not configured -> nothing verifies
(= nothing new is sold), which is the safe default.
"""
import logging
import time

from django.utils import timezone

log = logging.getLogger(__name__)

_CACHE = {"at": 0.0, "ok": frozenset()}
CACHE_S = 60


def _clear():
    _CACHE.update(at=0.0, ok=frozenset())


def verified(sku):
    now = time.time()
    if now - _CACHE["at"] > CACHE_S:
        try:
            from ..models import PlaySkuCheck
            ok = frozenset(PlaySkuCheck.objects.filter(ok=True).values_list("sku", flat=True))
        except Exception:  # noqa: BLE001 — unreadable = not verified
            ok = frozenset()
        _CACHE.update(at=now, ok=ok)
    return sku in _CACHE["ok"]


def targets(cfg=None):
    """[(sku, product_id, base_plan, kind)] for every gated sku the config
    knows (sold or not yet priced)."""
    from . import catalog
    c = catalog._cfg(cfg)
    pc = catalog.pay_cfg(c)
    out = []
    for sku, d in sorted(pc["play_products"].items()):
        if catalog.is_gated(sku):
            out.append((sku, d["product_id"], d["base_plan"], "sub"))
    from ..logic import pricing
    for p in pricing.topup_packs(c):
        sku = "pack_" + p["id"]
        if catalog.is_gated(sku):
            out.append((sku, pc["pack_product_prefix"] + p["id"], "", "pack"))
    # tagada2: the SMS packs (one-time products, same check as a credit pack)
    from ..logic import tagada_route as TR
    for n in TR.PACK_PARTS:
        sku = "%s%d" % (catalog.SMSPACK_PREFIX, n)
        out.append((sku, catalog.play_product(sku, c)[0], "", "pack"))
    return out


def _check_sub(product_id, base_plan, api):
    js = api("GET", "subscriptions/%s" % product_id)
    if js.get("archived"):
        return False, "ARCHIVED", "subscription archived"
    for bp in js.get("basePlans") or []:
        if bp.get("basePlanId") == base_plan:
            st = str(bp.get("state") or "")
            return st == "ACTIVE", st, ""
    return False, "NO_BASE_PLAN", "base plan %s not found" % base_plan


def _check_pack(product_id, api):
    from .play import PlayError
    try:
        js = api("GET", "inappproducts/%s" % product_id)
        st = str(js.get("status") or "")
        return st.lower() == "active", st.upper(), ""
    except PlayError as e:
        # A product made with Play's new one-time products model answers the
        # legacy inappproducts API with an error ("google_error"), not 404
        # (seen live 28 Oct on credits_c50) — ask oneTimeProducts then too.
        if e.args and e.args[0] not in ("not_found", "google_error"):
            raise
    js = api("GET", "oneTimeProducts/%s" % product_id)
    states = [str(o.get("state") or "") for o in js.get("purchaseOptions") or []]
    ok = "ACTIVE" in states
    return ok, "ACTIVE" if ok else (states[0] if states else "NO_OPTION"), ""


def check_all(cfg=None, api=None):
    """Ask Play about every gated sku; store + return the rows."""
    from ..models import PlaySkuCheck
    from . import play
    rows = []
    configured = False
    try:
        configured = play.configured()
    except Exception:  # noqa: BLE001
        configured = False
    call = api or (lambda m, p: play._api(m, p))
    now = timezone.now()
    for sku, pid, bp, kind in targets(cfg):
        ok, state, detail = False, "", ""
        if not configured and api is None:
            state, detail = "NOT_CONFIGURED", "Play API not configured"
        else:
            try:
                ok, state, detail = (_check_sub(pid, bp, call) if kind == "sub"
                                     else _check_pack(pid, call))
            except Exception as e:  # noqa: BLE001 — a failed check = not verified
                code = (e.args[0] if getattr(e, "args", None) else type(e).__name__)
                state, detail = ("NOT_FOUND" if code == "not_found" else "ERROR"), str(code)[:160]
        PlaySkuCheck.objects.update_or_create(
            sku=sku, defaults={"product_id": pid, "base_plan": bp, "state": state[:24],
                               "ok": bool(ok), "detail": detail[:160], "checked_at": now})
        rows.append({"sku": sku, "product_id": pid, "base_plan": bp, "kind": kind,
                     "ok": bool(ok), "state": state, "detail": detail})
    _clear()
    return {"checked": len(rows), "verified": sum(1 for r in rows if r["ok"]), "rows": rows}


def status_rows(cfg=None):
    """Owner Admin: every gated sku with its last stored check."""
    from ..models import PlaySkuCheck
    have = {r.sku: r for r in PlaySkuCheck.objects.all()}
    out = []
    for sku, pid, bp, kind in targets(cfg):
        r = have.get(sku)
        out.append({"sku": sku, "product_id": pid, "base_plan": bp, "kind": kind,
                    "ok": bool(r and r.ok), "state": r.state if r else "",
                    "detail": r.detail if r else "", "checked_at": r.checked_at if r else None})
    return out
