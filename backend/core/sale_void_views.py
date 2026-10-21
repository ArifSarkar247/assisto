"""
sale_void_views.py — POST business/sales/<id>/void (a2-cctv, CCTV Part 4).

Assisto POS had no void. A void:
  * is allowed for the business OWNER at any time, or for STAFF only on the
    same (local) day as the sale; a reason is required;
  * marks the Sale voided (it stays in history as VOID, but every report/total
    excludes it);
  * restores stock for each line whose catalog variant was recorded at checkout
    (SaleLine.variant). Older sales did not record it, so their restore is
    SKIPPED and the response says so honestly;
  * reverses the due-sale khata bridge entry ([sale#<id>]) with ONE balancing
    'got' entry marked [void-sale#<id>] (idempotent);
  * mirrors a `void` row into the owner's Shop Box sites (pos_link) and runs the
    void-spike check — the owner sees "please check", never an accusation.
"""
from django.db import transaction
from django.db.models import F
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from . import business_views as BV
from .logic import business_khata as khata


class SaleVoidView(APIView):
    def post(self, request, pk):
        prof, role, bad = BV._require_business(request)
        if bad:
            return bad
        lang = req_lang(request)
        from .models import Sale, ProductVariant
        reason = (request.data.get("reason") or "").strip()
        if len(reason) < 2:
            return BV._err(lang, "বাতিলের কারণ লিখুন।", "Please give a reason for the void.",
                           status=422, code="reason_required")
        s = Sale.objects.filter(pk=pk, business=prof).first()
        if s is None:
            return BV._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if s.voided_at is not None:
            return BV._err(lang, "এই বিক্রি আগেই বাতিল করা হয়েছে।",
                           "This sale is already voided.", status=409,
                           code="already_voided")
        now = timezone.now()
        if not BV.is_owner(role):
            same_day = (timezone.localtime(s.created_at).date()
                        == timezone.localtime(now).date())
            if not same_day:
                return BV._err(lang, "কর্মী শুধু আজকের বিক্রি বাতিল করতে পারেন। মালিককে বলুন।",
                               "Staff can only void today's sales. Please ask the owner.",
                               status=403, code="staff_same_day_only")

        restored, skipped = [], 0
        with transaction.atomic():
            locked = Sale.objects.select_for_update().get(pk=s.pk)
            if locked.voided_at is not None:
                return BV._err(lang, "এই বিক্রি আগেই বাতিল করা হয়েছে।",
                               "This sale is already voided.", status=409,
                               code="already_voided")
            locked.voided_at = now
            locked.voided_by = request.user
            locked.void_reason = reason[:200]
            locked.save(update_fields=["voided_at", "voided_by", "void_reason"])
            for line in locked.lines.all():
                if line.variant_id:
                    ProductVariant.objects.filter(pk=line.variant_id).update(
                        stock=F("stock") + int(line.qty or 0))
                    restored.append({"variant_id": line.variant_id,
                                     "qty": int(line.qty or 0)})
                else:
                    skipped += 1
            khata_res = _reverse_khata(prof, locked)
        s = locked

        try:
            from .shop_ops_views import mirror_pos
            mirror_pos(prof, "void", s.total, now)
        except Exception:
            pass

        out = {"ok": True, "sale_id": s.id, "voided": True,
               "voided_at": now.isoformat(), "void_reason": s.void_reason,
               "stock_restored": restored, "stock_restore_skipped_lines": skipped,
               "khata": khata_res}
        if skipped:
            out["note"] = pick(
                lang,
                "%d টি লাইনের স্টক আপনাআপনি ফেরত দেওয়া যায়নি (পুরনো বিক্রি) — "
                "দরকার হলে স্টক হাতে ঠিক করে নিন।" % skipped,
                "%d line(s) could not have stock restored automatically (older sale) "
                "— please adjust that stock by hand if needed." % skipped)
        return Response(out)


def _reverse_khata(prof, sale):
    """Balance the due-sale khata bridge entry, once. Returns a small status."""
    from .models import KhataEntry
    marker = "[sale#%d]" % sale.id
    vmarker = "[void-sale#%d]" % sale.id
    entry = KhataEntry.objects.filter(party__business=prof,
                                      note__contains=marker).first()
    if entry is None:
        return {"status": "none"}
    if entry.party.entries.filter(note__contains=vmarker).exists():
        return {"status": "already_reversed"}
    e = khata.new_entry(entry.party_id, "got", entry.amount_poisha,
                        note="বিক্রি বাতিল — বাকি বাদ %s" % vmarker,
                        at=timezone.now().isoformat())
    obj = KhataEntry.objects.create(party=entry.party, direction=e["direction"],
                                    amount_poisha=e["amount"], note=e["note"],
                                    at=timezone.now())
    return {"status": "reversed", "entry_id": obj.id, "party_id": entry.party_id,
            "amount": obj.amount_poisha}
