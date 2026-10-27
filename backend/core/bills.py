"""
Bill guide (feature 11) — extract bill fields, and CACHE the biller's layout so
the second scan of the same biller needs NO AI call. Honest: without an AI key
the first scan returns a clean needs-key state; cached billers still work.

Fields: company, account/meter no, where to pay, last date (+ late fee), amount,
and a month-over-month comparison from the user's past bills.
"""
import json

from . import ai
from .i18n import pick
from .models import BillTemplate, Transaction


def _task(lang):
    return (
        pick(lang,
             "নিচের বিলের লেখা থেকে JSON বের করো: ",
             "Extract JSON from the bill text below: ")
        + '{"biller":"","account_no":"","meter_no":"","amount":"","last_date":"",'
        + '"late_fee":"","where_to_pay":""}. '
        + pick(lang,
               "শুধু JSON দাও, আর কিছু না। অনুমান করো না — না পেলে ফাঁকা রাখো।",
               "Return only JSON, nothing else. Do not guess — leave blank if not found.")
    )


def _month_over_month(user, biller, amount):
    """Compare with the user's previous bill payments to this biller (own data)."""
    try:
        amt = float(amount)
    except (TypeError, ValueError):
        return None
    prev = (Transaction.objects.filter(user=user, kind="expense",
                                       category__icontains=biller)
            .order_by("-date").first())
    if not prev:
        return None
    try:
        p = float(prev.amount)
    except (TypeError, ValueError):
        return None
    diff = amt - p
    pct = (diff / p * 100) if p else 0
    return {"prev": p, "diff": round(diff, 2), "pct": round(pct, 1),
            "up": diff > 0}


def parse_bill(user, raw_text, biller_hint=""):
    """Return (result_dict, used_ai, from_cache). Uses cache when the biller is
    already known — no AI on repeat scans."""
    lang = getattr(user, "language", "bn")
    biller = (biller_hint or "").strip()

    # If we can identify the biller and have a template, reuse it (no AI).
    if biller:
        tpl = BillTemplate.objects.filter(user=user, biller__iexact=biller).first()
        if tpl:
            tpl.uses += 1
            tpl.save(update_fields=["uses", "updated_at"])
            fields = dict(tpl.fields)
            # amount still read from this scan's text if present, cheaply
            fields["mom"] = _month_over_month(user, biller, fields.get("amount"))
            return (fields, False, True)

    if not ai.available():
        return ({"needs_key": True}, False, False)

    try:
        text, _ = ai.generate(task=_task(lang), data=raw_text, tier="cheap",
                               feature="bill_guide", max_tokens=300, user=user)
    except ai.AIUnavailable:
        return ({"needs_key": True}, False, False)

    try:
        fields = json.loads(text[text.find("{"): text.rfind("}") + 1])
    except Exception:
        fields = {}
    # aieval guard: an amount / account / meter number / late fee not in
    # the scanned text is blanked, never shown as read from the bill.
    from . import ai_guard
    fields, _dropped = ai_guard.ground_fields(
        fields, raw_text, ("amount", "account_no", "meter_no", "late_fee"))
    b = (fields.get("biller") or biller or "").strip()
    if b:
        BillTemplate.objects.update_or_create(
            user=user, biller=b,
            defaults={"fields": {k: fields.get(k, "") for k in
                                 ("account_no", "meter_no", "where_to_pay", "last_date", "late_fee", "amount")}})
    fields["mom"] = _month_over_month(user, b, fields.get("amount"))
    return (fields, True, False)
