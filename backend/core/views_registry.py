"""
Anti-theft Batch 4 — stolen-IMEI registry + used-phone check + sell transfer.

SERVER IS THE SOURCE OF TRUTH. A factory reset on the handset can NEVER move
ownership or clear a stolen report; ownership only moves through POST sale/accept
(the buyer, a different auth user, accepts). A phone with an active StolenReport
or a recent theft signal can never be transfer-accepted — the thief's phone that
just screamed "stolen" cannot be sold.

HONESTY RULES (hard):
  * A check NEVER reveals the reporter's identity — only the report's COARSE
    area and an approximate time.
  * NEIR is a disabled placeholder — we never fake a network block.
  * Transfer re-checks recent_theft_signal() server-side as the authoritative
    guard; the UI gates the human-facing confirmation via POST security/action
    {action: sell_transfer}, but the server is what actually decides here.
"""
import secrets

from django.utils import timezone

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (ProtectedPhone, StolenReport, ImeiCheckLog, SaleReceipt,
                     _normalize_imei)
from .logic import security as sec
from .views_security import _notify_owner_and_circle


CHECKS_PER_HOUR = 20  # abuse limit: >20 checks/hour/user -> 429


def _owned_phone_with_imei(user, imei):
    """The caller's ProtectedPhone whose imei1 OR imei2 matches `imei`
    (normalized), or None."""
    for p in ProtectedPhone.objects.filter(owner=user):
        if _normalize_imei(p.imei1) == imei or _normalize_imei(p.imei2) == imei:
            return p
    return None


# --------------------------------------------------------------------------
# POST registry/report-stolen
# --------------------------------------------------------------------------

class ReportStolenView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        imei = _normalize_imei(request.data.get("imei"))
        gd = str(request.data.get("gd_number", "")).strip()
        if not imei:
            return Response({"ok": False, "reason": "bad_imei"},
                            status=status.HTTP_400_BAD_REQUEST)
        if not gd:
            # gd_number is REQUIRED — a police General Diary backs the claim.
            return Response({"ok": False, "reason": "gd_required"},
                            status=status.HTTP_400_BAD_REQUEST)
        report = StolenReport.objects.create(
            imei=imei, reporter=request.user, gd_number=gd,
            model_name=str(request.data.get("model", "") or "").strip()[:80],
            area=str(request.data.get("area", "") or "").strip()[:120],
            status="active")
        # If the caller owns a ProtectedPhone with this imei, flag it. We do NOT
        # fake a theft signal — just mark the status.
        phone = _owned_phone_with_imei(request.user, imei)
        if phone is not None:
            phone.status = "reported_stolen"
            phone.save(update_fields=["status", "updated_at"])
        return Response({"ok": True, "report_id": report.id})


# --------------------------------------------------------------------------
# POST registry/recover
# --------------------------------------------------------------------------

class RecoverView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        imei = _normalize_imei(request.data.get("imei"))
        if not imei:
            return Response({"ok": False, "reason": "bad_imei"},
                            status=status.HTTP_400_BAD_REQUEST)
        # Only the ORIGINAL reporter may recover their own active report.
        report = (StolenReport.objects
                  .filter(imei=imei, reporter=request.user, status="active")
                  .order_by("-created_at").first())
        if report is None:
            return Response({"ok": False, "reason": "no_active_report"},
                            status=status.HTTP_404_NOT_FOUND)
        now = timezone.now()
        report.status = "recovered"
        report.recovered_at = now
        report.save(update_fields=["status", "recovered_at"])
        # Clear the owner's phone status back to owned (if it was flagged).
        phone = _owned_phone_with_imei(request.user, imei)
        if phone is not None and phone.status == "reported_stolen":
            phone.status = "owned"
            phone.save(update_fields=["status", "updated_at"])
        return Response({"ok": True})


# --------------------------------------------------------------------------
# POST registry/check  — the used-phone buyer checks an IMEI
# --------------------------------------------------------------------------

class CheckView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        imei = _normalize_imei(request.data.get("imei"))
        if not imei:
            return Response({"ok": False, "reason": "bad_imei"},
                            status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        # Rate-limit BEFORE logging so the 21st in an hour is rejected and not
        # counted, and an attacker can't scrape the registry.
        since = now - timezone.timedelta(hours=1)
        recent = ImeiCheckLog.objects.filter(checker=request.user,
                                              at__gte=since).count()
        if recent >= CHECKS_PER_HOUR:
            return Response({"ok": False, "reason": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        ImeiCheckLog.objects.create(imei=imei, checker=request.user)

        # Result priority: a completed (accepted) sale verifies a clean transfer;
        # otherwise an active stolen report warns; otherwise clean.
        if SaleReceipt.objects.filter(imei=imei, state="accepted").exists():
            return Response({"result": "verified_transfer",
                             "advice_key": "verified_ok"})

        report = (StolenReport.objects
                  .filter(imei=imei, status="active")
                  .order_by("-created_at").first())
        if report is not None:
            # Alert the REPORTER with approximate time + COARSE area only.
            # NEVER expose the checker's identity or location, and NEVER expose
            # the reporter's identity to the checker.
            when = now.strftime("%Y-%m-%d %H:%M")
            area = report.area or "an unspecified area"
            _notify_owner_and_circle(
                report.reporter,
                "Someone checked your stolen phone's IMEI",
                f"A used-phone check hit your reported-stolen device around "
                f"{when}, near {area}. Do not confront anyone — contact the "
                f"police with your GD number.",
                meta={"kind": "imei_check", "at": now.isoformat(),
                      "area": report.area, "report_id": report.id})
            return Response({"result": "reported_stolen",
                             "advice_key": "contact_police_dont_confront"})

        return Response({"result": "clean", "advice_key": "buy_ok"})


# --------------------------------------------------------------------------
# GET registry/neir-status  — DISABLED placeholder (never fake a block)
# --------------------------------------------------------------------------

class NeirStatusView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return Response({"available": False, "message_key": "neir_not_available"})


# ==========================================================================
# Sell-my-phone transfer
# ==========================================================================

class SaleCreateView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        imei = _normalize_imei(request.data.get("imei"))
        if not imei:
            return Response({"ok": False, "reason": "bad_imei"},
                            status=status.HTTP_400_BAD_REQUEST)
        phone = _owned_phone_with_imei(request.user, imei)
        if phone is None:
            # The seller must actually own a protected handset with this imei.
            return Response({"ok": False, "reason": "not_owner"},
                            status=status.HTTP_403_FORBIDDEN)
        try:
            price = int(request.data.get("price") or 0)
        except (TypeError, ValueError):
            price = 0
        receipt = SaleReceipt.objects.create(
            seller=request.user, imei=imei,
            model_name=str(request.data.get("model", "") or "").strip()[:80],
            price=price,
            buyer_name=str(request.data.get("buyer_name", "") or "").strip()[:120],
            buyer_nid=str(request.data.get("buyer_nid", "") or "").strip()[:40],
            token=secrets.token_urlsafe(24), state="draft")
        return Response({"id": receipt.id, "token": receipt.token,
                         "state": receipt.state})


class SaleAuthorizeView(APIView):
    """The SENSITIVE step — must NOT bypass Section 8. The UI gates the
    human-facing confirmation through POST security/action {action:
    sell_transfer}; the server here is the authoritative guard: it re-checks
    the theft signal, the report status, and the freeze window. A phone that
    just screamed 'stolen' can never be authorized for sale."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        rid = request.data.get("id")
        receipt = SaleReceipt.objects.filter(id=rid, seller=request.user).first()
        if receipt is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)
        if receipt.state == "authorized":
            return Response({"ok": True, "state": "authorized"})
        if receipt.state != "draft":
            return Response({"ok": False, "reason": "bad_state",
                             "state": receipt.state},
                            status=status.HTTP_409_CONFLICT)
        phone = _owned_phone_with_imei(request.user, receipt.imei)
        if phone is None:
            return Response({"ok": False, "reason": "not_owner"},
                            status=status.HTTP_403_FORBIDDEN)
        now = timezone.now()
        # Authoritative server-side guard (mirrors Section 8's decide_action).
        if sec.is_frozen(phone, now):
            return Response({"ok": False, "state": "blocked", "reason": "frozen"},
                            status=status.HTTP_423_LOCKED)
        if phone.status == "reported_stolen" or StolenReport.objects.filter(
                imei=receipt.imei, status="active").exists():
            return Response({"ok": False, "state": "blocked",
                             "reason": "reported_stolen"},
                            status=status.HTTP_409_CONFLICT)
        if sec.recent_theft_signal(phone, now, 7):
            return Response({"ok": False, "state": "blocked",
                             "reason": "recent_theft_signal"},
                            status=status.HTTP_423_LOCKED)
        receipt.state = "authorized"
        receipt.save(update_fields=["state"])
        phone.status = "transfer_pending"
        phone.save(update_fields=["status", "updated_at"])
        return Response({"ok": True, "state": "authorized"})


class SaleAcceptView(APIView):
    """The BUYER (a different auth user) accepts via the QR token. Ownership
    moves here and ONLY here — this is the server source of truth; a factory
    reset cannot do this."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        token = str(request.data.get("token", "")).strip()
        receipt = SaleReceipt.objects.filter(token=token).first() if token else None
        if receipt is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)
        if receipt.seller_id == request.user.id:
            return Response({"ok": False, "reason": "buyer_must_differ"},
                            status=status.HTTP_403_FORBIDDEN)
        if receipt.state == "accepted":
            return Response({"ok": True, "state": "accepted"})
        if receipt.state != "authorized":
            return Response({"ok": False, "reason": "not_authorized",
                             "state": receipt.state},
                            status=status.HTTP_409_CONFLICT)
        now = timezone.now()
        phone = ProtectedPhone.objects.filter(
            owner=receipt.seller).order_by("created_at").first()
        if phone is None or (
                _normalize_imei(phone.imei1) != receipt.imei and
                _normalize_imei(phone.imei2) != receipt.imei):
            phone = _owned_phone_with_imei(receipt.seller, receipt.imei)
        # A phone with an active stolen report or a recent theft signal can
        # NEVER be transfer-accepted.
        if StolenReport.objects.filter(imei=receipt.imei, status="active").exists():
            return Response({"ok": False, "state": "blocked",
                             "reason": "reported_stolen"},
                            status=status.HTTP_409_CONFLICT)
        if phone is not None and sec.recent_theft_signal(phone, now, 7):
            return Response({"ok": False, "state": "blocked",
                             "reason": "recent_theft_signal"},
                            status=status.HTTP_423_LOCKED)

        # Move ownership server-side: the old phone is transferred; the buyer
        # gets a ProtectedPhone with this imei, owned.
        if phone is not None:
            phone.status = "transferred"
            phone.save(update_fields=["status", "updated_at"])
            new_imei1, new_imei2 = phone.imei1, phone.imei2
            new_model = phone.model_name
        else:
            new_imei1, new_imei2, new_model = receipt.imei, "", receipt.model_name
        ProtectedPhone.objects.create(
            owner=request.user, imei1=new_imei1, imei2=new_imei2,
            model_name=new_model or receipt.model_name, status="owned")

        receipt.state = "accepted"
        receipt.buyer_user = request.user
        receipt.accepted_at = now
        receipt.save(update_fields=["state", "buyer_user", "accepted_at"])
        return Response({"ok": True, "state": "accepted"})


class SaleMineView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        def _row(r, role):
            return {"id": r.id, "role": role, "imei": r.imei,
                    "model_name": r.model_name, "price": r.price,
                    "buyer_name": r.buyer_name, "state": r.state,
                    "token": r.token if role == "seller" else None,
                    "created_at": r.created_at.isoformat(),
                    "accepted_at": r.accepted_at.isoformat() if r.accepted_at else None}
        rows = [_row(r, "seller") for r in SaleReceipt.objects.filter(
            seller=request.user)]
        rows += [_row(r, "buyer") for r in SaleReceipt.objects.filter(
            buyer_user=request.user)]
        return Response({"receipts": rows})


# --------------------------------------------------------------------------
# GET registry/tac?imei=...  — TAC (first 8 digits) -> make/model lookup.
# KEY-GATED + HONEST: without a licensed TAC data source wired in Integrations,
# we return {available:false} and NEVER invent a brand/model. (A fabricated
# "genuine" result would be worse than none — IMEI re-flashing is the whole
# risk.) When a 'tac' integration key is present, this is where a provider call
# would go; until then it is honestly unavailable.
# --------------------------------------------------------------------------

class TacLookupView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        imei = _normalize_imei(request.GET.get("imei", ""))
        if len(imei) < 8:
            return Response({"available": False, "reason": "bad_imei"})
        try:
            from . import integrations as _ig
            enabled = _ig.is_enabled("tac")
        except Exception:
            enabled = False
        if not enabled:
            # Honest: no data source → cannot look up make/model from the TAC.
            return Response({"available": False, "message_key": "tac_not_available"})
        # Provider wiring would go here when a 'tac' key is configured. Until a
        # real provider is integrated we still do NOT fabricate a result.
        return Response({"available": False, "message_key": "tac_not_available"})
