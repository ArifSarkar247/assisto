"""pay1 — payments API (the app only ever talks to these; never to a gateway).

  GET  payments/config?flavour=play|apk   channels (owner switches), products
                                          with server prices, entitlement state
  GET  payments/state                     entitlement summary (+ recompute)
  POST payments/checkout {sku, idem, flavour}      gateway order -> redirect_url
  GET  payments/orders/<id>               order status (re-verifies if pending)
  POST payments/play/precheck {sku}       would a Play purchase double-charge?
  POST payments/play/verify {kind, product_id, purchase_token}
  POST payments/play/rtdn                 Google Pub/Sub push (RTDN)
  POST payments/gateway/ipn               gateway server-to-server notification
"""
import logging

from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .payments import catalog, entitlement as E, service as S

log = logging.getLogger(__name__)


def _err(reason, lang, code=400, **extra):
    return Response({"ok": False, "reason": reason, "message": S.message(reason, lang), **extra},
                    status=code)


def _flavour(v):
    return "play" if str(v or "").lower() == "play" else "apk"


def _order_json(o):
    return {"id": o.pk, "sku": o.sku, "kind": o.kind, "plan": o.plan, "status": o.status,
            "amount_bdt": str(o.amount_bdt), "currency": o.currency,
            "created_at": o.created_at.isoformat(),
            "paid_at": o.paid_at.isoformat() if o.paid_at else None,
            "redirect_url": (o.raw or {}).get("redirect_url", "")
            if o.status in ("created", "pending") else ""}


class PaymentsConfigView(APIView):
    def get(self, request):
        return Response(S.config_for(request.user, _flavour(request.query_params.get("flavour")),
                                     req_lang(request)))


class PaymentsStateView(APIView):
    def get(self, request):
        return Response(E.summary(request.user))


class PaymentsCheckoutView(APIView):
    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        sku = str(d.get("sku", ""))[:32]
        try:
            o = S.checkout(request.user, sku, source="app", idem=str(d.get("idem", ""))[:64],
                           flavour=_flavour(d.get("flavour")), ip=_ip(request), lang=lang)
        except S.PayError as e:
            return _err(e.reason, lang, e.status)
        return Response({"ok": True, "order": _order_json(o)}, status=status.HTTP_201_CREATED)


class PaymentsOrderView(APIView):
    def get(self, request, pk):
        from .models import PaymentOrder
        o = PaymentOrder.objects.filter(pk=pk, user=request.user).first()
        if o is None:
            return _err("not_found", req_lang(request), 404)
        if o.status in ("pending", "cancelled", "failed"):
            o = S.complete(o, via="poll")
        o.refresh_from_db()
        return Response({"ok": True, "order": _order_json(o), "state": E.summary(request.user)})


class PlayPrecheckView(APIView):
    """Before the app opens Google's purchase sheet: refuse when a PREPAID
    gateway period of the same or a higher tier is still running (that would
    charge twice for the same time). Upgrades are always allowed."""
    def post(self, request):
        from django.utils import timezone
        from .models import PlanPeriod
        lang = req_lang(request)
        sku = str((request.data or {}).get("sku", ""))[:32]
        d = catalog.describe(sku)
        pc = catalog.pay_cfg()
        if not d:
            return _err("not_for_sale", lang)
        if not pc["play_enabled"]:
            return _err("channel_off", lang, 409)
        now = timezone.now()
        if d["kind"] == "sub":
            for p in PlanPeriod.objects.filter(user=request.user, status="active",
                                               ends_at__gt=now):
                if p.source == "play" and E.tier(p.plan) == E.tier(d["plan"]):
                    return _err("already_active", lang, 409)
                if p.source == "gateway" and E.tier(p.plan) >= E.tier(d["plan"]):
                    return _err("prepaid_active", lang, 409, until=p.ends_at.isoformat())
        from .payments import play
        return Response({"ok": True, "play_account_id": play.account_id(request.user)})


class PlayVerifyView(APIView):
    def post(self, request):
        from .payments import play
        lang = req_lang(request)
        d = request.data or {}
        token = str(d.get("purchase_token", ""))[:4096]
        product_id = str(d.get("product_id", ""))[:64]
        kind = str(d.get("kind", ""))
        if not token or not product_id or kind not in ("sub", "pack"):
            return _err("bad_request", lang)
        if not catalog.pay_cfg()["play_enabled"]:
            return _err("channel_off", lang, 409)
        if not play.configured():
            return _err("not_configured", lang, 503)
        try:
            if kind == "sub":
                r = play.sync_subscription(token, request.user)
            else:
                r = play.sync_pack(token, product_id, request.user)
        except play.PlayError as e:
            log.info("play verify refused: %s", e.reason)
            return _err(e.reason, lang, e.status if e.status in (400, 403, 409, 503) else 502)
        r.pop("user", None)
        return Response({"ok": bool(r.get("ok")), **r, "entitlement": E.summary(request.user)})


class PlayRtdnView(APIView):
    """Pub/Sub push endpoint. 2xx = processed (or a duplicate / not ours);
    5xx makes Pub/Sub retry (Google outage); 401/403 for bad auth."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        from .payments import play
        try:
            play.authenticate_push(request.META.get("HTTP_AUTHORIZATION", ""),
                                   request.query_params.get("token", ""))
        except play.PlayError as e:
            E.event(None, "play.rtdn_rejected", "play", "", reason=e.reason)
            return Response({"ok": False}, status=e.status)
        try:
            out = play.handle_rtdn(request.data)
        except play.PlayError as e:
            if e.status >= 500:
                return Response({"ok": False, "retry": True}, status=503)
            return Response({"ok": False, "reason": e.reason}, status=200 if
                            e.reason in ("wrong_package",) else 400)
        return Response({"ok": True, "outcome": out})


class GatewayIpnView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def post(self, request):
        code, body = S.handle_ipn(request.body, dict(request.headers))
        return Response(body, status=code)


def _ip(request):
    xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
    return (xff.split(",")[0].strip() if xff else request.META.get("REMOTE_ADDR", ""))[:45]
