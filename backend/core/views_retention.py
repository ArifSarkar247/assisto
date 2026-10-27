"""
views_retention.py — RETENTION AUTOMATION API (big-week H). Behind the
server feature flag `retention_auto` (default OFF): every endpoint answers
403 `feature_off` while hidden (owner / staff / allow-listed testers preview
it) — EXCEPT the customer's STOP, which must always work instantly.

OWNER (Business plan, shop owner only — staff get 403)
  GET    retention                           overview: caps, channels, automations
  PATCH  retention/settings                  lower the caps (never above server max)
  GET    retention/automations               list
  POST   retention/automations               create
  GET/PATCH/DELETE retention/automations/<id>
  POST   retention/preview                   audience count + sample for a draft
  GET    retention/automations/<id>/results  sent / delivered / replied / opted out
                                             / purchases after (attribution window)
  GET    retention/customers?q=              own customers (birthday picker)
  POST   retention/customers/<id>/birthday   {birthday: YYYY-MM-DD | null}
  GET/POST retention/stock-asks              who asked for which product
  DELETE retention/stock-asks/<id>
  POST   retention/opt-outs                  {phone} customer asked the owner to stop
CUSTOMER (any signed-in user who received a message)
  GET    retention/inbox                     messages from shops (marks delivered)
  POST   retention/inbox/<id>/reply          {text} (STOP text = stop)
  POST   retention/inbox/<id>/stop           stop ALL messages from that shop (never gated)
PUBLIC
  GET/POST retention/u/<token>               SMS stop link: confirm page -> POST stops
"""
from datetime import date

from django.http import HttpResponse
from django.utils import timezone
from django.utils.html import escape
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import retention_service as S
from .i18n import pick, req_lang
from .logic import msg_guard as MG
from .logic import retention as R
from .logic.business_selling import normalize_phone

_MSG = {
    "bad_kind": ("এই ধরনের অটোমেশন নেই।", "Unknown automation type."),
    "bad_channel": ("এই চ্যানেল নেই।", "Unknown channel."),
    "channel_not_connected": ("এই চ্যানেলটি এখনো যুক্ত নয়। আগে বিজনেস এজেন্ট বা SMS গেটওয়ে যুক্ত করুন।",
                              "This channel is not connected yet. Connect it in the business agent or SMS gateway first."),
    "template_required": ("অন্তত একটি ভাষায় মেসেজ লিখুন।", "Write the message in at least one language."),
    "template_too_long": ("মেসেজ ৪০০ অক্ষরের মধ্যে রাখুন।", "Keep the message under 400 characters."),
    "unknown_variable": ("মেসেজে অজানা {…} আছে। শুধু তালিকার শব্দগুলো ব্যবহার করুন।",
                         "The message has an unknown {…}. Use only the listed words."),
    "bad_send_hour": ("পাঠানোর সময় সকাল ৯টা থেকে রাত ৮টার মধ্যে দিন।", "Pick a send time between 9 am and 8 pm."),
    "bad_template_category": ("WhatsApp টেমপ্লেটের ধরন বেছে নিন (Marketing বা Utility)।",
                              "Pick the WhatsApp template category (Marketing or Utility)."),
    "promo_in_utility_template": ("প্রচারের মেসেজ Utility টেমপ্লেটে পাঠানো যায় না (Meta নিয়ম)। Marketing টেমপ্লেট দিন।",
                                  "Promotional messages cannot use a Utility template (Meta rule). Use a Marketing template."),
    "too_many": ("এই ব্যবসায় সর্বোচ্চ অটোমেশন হয়ে গেছে।", "This business has the maximum number of automations."),
    "cap_above_server_max": ("সীমা শুধু কমানো যায়, সার্ভারের সর্বোচ্চের বেশি নয়।",
                             "Caps can only be lowered, never above the server maximum."),
    "cap_too_low": ("সীমা অন্তত ১ রাখুন।", "Keep each cap at 1 or more."),
    "bad_birthday": ("জন্মদিনের তারিখ ঠিক নয়।", "That birthday date is not valid."),
    "bad_phone": ("ফোন নম্বর ঠিক নয়।", "That phone number is not valid."),
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "not_your_customer": ("এই গ্রাহক আপনার ব্যবসার নন।", "This customer is not in your business."),
    "empty": ("কিছু লিখুন।", "Write something."),
    "rate_limited": ("একটু পরে আবার চেষ্টা করুন।", "Please wait a moment and try again."),
}


def _err(request, code, status=400, **extra):
    lang = req_lang(request)
    bn, en = _MSG.get(code, ("ঠিক হয়নি, আবার চেষ্টা করুন।", "That did not work, please try again."))
    d = {"error": code, "detail": pick(lang, bn, en)}
    d.update(extra)
    return Response(d, status=status)


def _flag(request):
    try:
        from .i18n import is_play_flavour
        play = is_play_flavour(request)
    except Exception:
        play = False
    return S.flag_on(request.user, play)


def _feature_off(request):
    from rest_framework.exceptions import PermissionDenied
    lang = req_lang(request)
    raise PermissionDenied(detail={"error": "feature_off",
                                   "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                                                  "This feature is not available yet.")})


class _Gated(APIView):
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not _flag(request):
            _feature_off(request)


class _Owner(_Gated):
    """Owner of the shop (staff refused). self.biz is set."""
    need_plan = True

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        from rest_framework.exceptions import APIException, PermissionDenied
        from .business_views import is_owner, resolve_business
        lang = req_lang(request)
        biz, role = resolve_business(request)
        if biz is None or not is_owner(role):
            raise PermissionDenied(detail={"error": "owner_only", "detail": pick(
                lang, "শুধু দোকানের মালিক এটি ব্যবহার করতে পারেন।",
                "Only the shop owner can use this.")})
        self.biz = biz
        from . import entitlements_service as ES
        if self.need_plan and ES.on(request.user) and not S.plan_ok(request.user):
            # plans-v2: what exists stays readable and removable (no data
            # loss); creating / changing / sending needs Business.
            if request.method in ("GET", "HEAD", "OPTIONS", "DELETE"):
                return
            ES.refuse("automation", request.user, lang)
        if self.need_plan and not S.plan_ok(request.user):
            from . import plans
            e = APIException()
            e.status_code = 402
            e.detail = {"error": "upgrade_required", "plan_required": "business",
                        "current_plan": plans.effective_plan(request.user), "upgrade": True,
                        "detail": pick(lang, "রিটেনশন অটোমেশনের জন্য বিজনেস প্ল্যান দরকার।",
                                       "Retention automation needs the Business plan.")}
            raise e


def _auto_row(a):
    return {"id": a.id, "kind": a.kind, "name": a.name, "enabled": a.enabled,
            "params": R.normalize_params(a.kind, a.params) if a.kind in R.KINDS else {},
            "template_bn": a.template_bn, "template_en": a.template_en,
            "channel": a.channel, "wa_template": a.wa_template or {},
            "send_hour": a.send_hour,
            "last_run_at": a.last_run_at.isoformat() if a.last_run_at else None,
            "created_at": a.created_at.isoformat(), "summary": S.summary(a)}


def _catalog():
    out = []
    for k in R.KINDS:
        c = R.CATALOG[k]
        out.append({"kind": k, "purpose": c["purpose"], "vars": list(c["vars"]),
                    "params": {p: {"min": lo, "max": hi, "default": d}
                               for p, (lo, hi, d) in c["params"].items()},
                    "default_bn": R.DEFAULT_TEMPLATES[k][0],
                    "default_en": R.DEFAULT_TEMPLATES[k][1]})
    return out


def _caps_payload(biz):
    return {"caps": S.caps_for(biz), "server_max": S.server_max()}


class OverviewView(_Owner):
    need_plan = False

    def get(self, request):
        from .models import BizOptOut, RetentionAutomation
        biz = self.biz
        now = timezone.now()
        autos = RetentionAutomation.objects.filter(business=biz)
        d = {"plan_ok": S.plan_ok(request.user),
             "credits": int(request.user.ai_credits or 0),
             "shop": S.shop_name(biz),
             "quiet": {"start": "21:00", "end": "09:00", "now": MG.in_quiet_hours(now)},
             "channels_ready": S.channels_ready(biz),
             "kinds": _catalog(),
             "max_automations": S.cfg()["max_automations"],
             "attribution_days": S.cfg()["attribution_days"],
             "opted_out_count": BizOptOut.objects.filter(business=biz).count(),
             "automations": [_auto_row(a) for a in autos]}
        d.update(_caps_payload(biz))
        return Response(d)


class SettingsView(_Owner):
    def patch(self, request):
        smax = S.server_max()
        body = {k: request.data.get(k) for k in smax if k in request.data}
        problems = MG.validate_owner_caps(body, smax)
        if problems:
            return _err(request, problems[0], problems=problems, **_caps_payload(self.biz))
        row = S.settings_for(self.biz)
        for k, v in body.items():
            setattr(row, k, int(v))
        row.save()
        return Response(_caps_payload(self.biz))


def _validate(request, biz, data):
    clean, problems = R.validate(data, channels_ready=S.channels_ready(biz))
    return clean, problems


class AutomationsView(_Owner):
    def get(self, request):
        from .models import RetentionAutomation
        return Response({"automations": [_auto_row(a) for a in
                                         RetentionAutomation.objects.filter(business=self.biz)]})

    def post(self, request):
        from .models import RetentionAutomation
        if RetentionAutomation.objects.filter(business=self.biz).count() >= S.cfg()["max_automations"]:
            return _err(request, "too_many")
        clean, problems = _validate(request, self.biz, request.data)
        if problems:
            return _err(request, problems[0], problems=problems)
        a = RetentionAutomation.objects.create(business=self.biz, **clean)
        return Response(_auto_row(a), status=201)


class AutomationDetailView(_Owner):
    def _get(self, pk):
        from .models import RetentionAutomation
        return RetentionAutomation.objects.filter(business=self.biz, pk=pk).first()

    def get(self, request, pk):
        a = self._get(pk)
        if a is None:
            return _err(request, "not_found", status=404)
        return Response(_auto_row(a))

    def patch(self, request, pk):
        a = self._get(pk)
        if a is None:
            return _err(request, "not_found", status=404)
        cur = _auto_row(a)
        cur.pop("summary", None)
        merged = dict(cur)
        for k in ("name", "enabled", "params", "template_bn", "template_en", "channel",
                  "wa_template", "send_hour"):
            if k in request.data:
                merged[k] = request.data.get(k)
        merged["kind"] = a.kind
        clean, problems = _validate(request, self.biz, merged)
        if problems:
            return _err(request, problems[0], problems=problems)
        for k, v in clean.items():
            setattr(a, k, v)
        a.save()
        return Response(_auto_row(a))

    def delete(self, request, pk):
        a = self._get(pk)
        if a is None:
            return _err(request, "not_found", status=404)
        a.delete()
        return Response(status=204)


PREVIEWS_PER_MIN = 30     # the audience count scans customers: rate-limited


def _rate_ok(user_id, scope, per_min):
    import time
    from django.core.cache import cache
    key = "rt:%s:%s:%d" % (scope, user_id, int(time.time() // 60))
    cache.add(key, 0, 90)
    try:
        n = cache.incr(key)
    except ValueError:
        n = 1
    return n <= per_min


class PreviewView(_Owner):
    def post(self, request):
        from .models import RetentionAutomation
        if not _rate_ok(request.user.id, "preview", PREVIEWS_PER_MIN):
            return _err(request, "rate_limited", status=429)
        pk = request.data.get("id")
        if pk:
            a = RetentionAutomation.objects.filter(business=self.biz, pk=pk).first()
            if a is None:
                return _err(request, "not_found", status=404)
        else:
            clean, problems = R.validate(request.data)    # channel readiness not needed
            if "bad_kind" in problems:
                return _err(request, "bad_kind")
            clean.pop("enabled", None)
            a = RetentionAutomation(business=self.biz, **clean)   # unsaved draft
        return Response(S.preview(a, lang=req_lang(request)))


class ResultsView(_Owner):
    def get(self, request, pk):
        from .models import RetentionAutomation
        a = RetentionAutomation.objects.filter(business=self.biz, pk=pk).first()
        if a is None:
            return _err(request, "not_found", status=404)
        d = S.results(a)
        d["automation"] = _auto_row(a)
        return Response(d)


def _cust_row(c):
    return {"id": c.id, "name": c.name, "phone": c.phone,
            "birthday": c.birthday.isoformat() if c.birthday else None}


class CustomersView(_Owner):
    def get(self, request):
        from .models import Customer
        q = (request.query_params.get("q") or "").strip()
        qs = Customer.objects.filter(S._cust_q(self.biz)).exclude(phone_key="")
        if q:
            from django.db.models import Q
            qs = qs.filter(Q(name__icontains=q) | Q(phone__icontains=q))
        if request.query_params.get("with_birthday") == "1":
            qs = qs.filter(birthday__isnull=False)
        return Response({"customers": [_cust_row(c) for c in qs.order_by("name", "id")[:100]]})


class BirthdayView(_Owner):
    def post(self, request, pk):
        from .models import Customer
        c = Customer.objects.filter(S._cust_q(self.biz), pk=pk).first()
        if c is None:
            return _err(request, "not_your_customer", status=404)
        raw = request.data.get("birthday")
        if raw in (None, ""):
            c.birthday = None
        else:
            try:
                bd = date.fromisoformat(str(raw)[:10])
            except ValueError:
                return _err(request, "bad_birthday")
            if bd > timezone.localdate() or bd.year < 1900:
                return _err(request, "bad_birthday")
            c.birthday = bd
        c.save(update_fields=["birthday"])
        return Response(_cust_row(c))


def _ask_row(a):
    return {"id": a.id, "product_id": a.product_id, "product": a.product.name,
            "in_stock": S._in_stock(a.product), "customer_id": a.customer_id,
            "customer": a.customer.name, "phone": a.customer.phone,
            "notified": bool(a.notified_at), "created_at": a.created_at.isoformat()}


class StockAsksView(_Owner):
    def get(self, request):
        from .models import Product, RetentionStockAsk
        asks = (RetentionStockAsk.objects.filter(business=self.biz)
                .select_related("product", "customer").order_by("-created_at")[:200])
        prods = Product.objects.filter(S._cust_q(self.biz)).order_by("name")[:300]
        return Response({"asks": [_ask_row(a) for a in asks],
                         "products": [{"id": p.id, "name": p.name, "in_stock": S._in_stock(p)}
                                      for p in prods]})

    def post(self, request):
        from .models import Customer, Product, RetentionStockAsk
        p = Product.objects.filter(S._cust_q(self.biz), pk=request.data.get("product_id")).first()
        c = Customer.objects.filter(S._cust_q(self.biz), pk=request.data.get("customer_id")).first()
        if p is None or c is None:
            return _err(request, "not_your_customer", status=404)
        a, _ = RetentionStockAsk.objects.get_or_create(
            business=self.biz, product=p, customer=c)
        if a.notified_at:          # asked again after we told them -> ask again
            a.notified_at = None
            a.save(update_fields=["notified_at"])
        return Response(_ask_row(a), status=201)


class StockAskDetailView(_Owner):
    def delete(self, request, pk):
        from .models import RetentionStockAsk
        n, _ = RetentionStockAsk.objects.filter(business=self.biz, pk=pk).delete()
        if not n:
            return _err(request, "not_found", status=404)
        return Response(status=204)


class OptOutsView(_Owner):
    need_plan = False      # the owner may always record a customer's STOP

    def post(self, request):
        key = normalize_phone(request.data.get("phone"))
        if len(key) < 10:
            return _err(request, "bad_phone")
        MG.record_opt_out(self.biz.id, key, "owner")
        from .models import BizOptOut
        return Response({"ok": True, "opted_out_count":
                         BizOptOut.objects.filter(business=self.biz).count()})


# ===================================================================== customer side
def _inbox_row(s, stopped):
    return {"id": s.pk, "shop": S.shop_name(s.business), "text": s.text,
            "at": s.created_at.isoformat(), "replied": bool(s.replied_at),
            "reply_text": s.reply_text, "stopped": stopped}


class InboxView(_Gated):
    def get(self, request):
        from .models import BizOptOut, RetentionSend
        rows = list(RetentionSend.objects.filter(recipient=request.user, channel="in_app",
                                                 status__in=MG.SENT_STATES)
                    .select_related("business", "business__user")[:100])
        now = timezone.now()
        fresh = [s.pk for s in rows if s.status == "sent"]
        if fresh:
            RetentionSend.objects.filter(pk__in=fresh).update(status="delivered", delivered_at=now)
        stopped = set(BizOptOut.objects.filter(
            business_id__in={s.business_id for s in rows},
            key__in={s.audience_key for s in rows}).values_list("business_id", "key"))
        return Response({"messages": [_inbox_row(s, (s.business_id, s.audience_key) in stopped)
                                      for s in rows]})


def _my_send(request, pk):
    from .models import RetentionSend
    return (RetentionSend.objects.filter(recipient=request.user, pk=pk, channel="in_app")
            .select_related("business", "business__user").first())


class InboxReplyView(_Gated):
    def post(self, request, pk):
        s = _my_send(request, pk)
        if s is None:
            return _err(request, "not_found", status=404)
        text = (request.data.get("text") or "").strip()[:500]
        if not text:
            return _err(request, "empty")
        if not _rate_ok(request.user.id, "reply", 10):
            return _err(request, "rate_limited", status=429)
        now = timezone.now()
        if MG.is_stop_text(text):
            S.opt_out_send(s, "in_app")
            return Response({"ok": True, "stopped": True})
        s.replied_at, s.reply_text = now, text
        if not s.read_at:
            s.read_at = now
        s.save(update_fields=["replied_at", "reply_text", "read_at"])
        try:
            from . import bizagent_service as BS
            name = s.customer_name or getattr(request.user, "name", "")
            BS.notify_seller(s.business, "retention_reply",
                             "%s উত্তর দিয়েছেন" % name, "%s replied" % name,
                             text, text, data={"route": "retention_auto"})
        except Exception:
            pass
        return Response({"ok": True, "stopped": False})


class InboxStopView(APIView):
    """NEVER gated by the feature flag: a STOP must always work."""

    def post(self, request, pk):
        s = _my_send(request, pk)
        if s is None:
            return _err(request, "not_found", status=404)
        S.opt_out_send(s, "in_app")
        return Response({"ok": True, "stopped": True})


_PAGE = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>
<style>body{{font-family:system-ui,sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem;
line-height:1.6;color:#111;background:#fff}}button{{font-size:1.1rem;min-height:48px;padding:0 1.5rem;
border-radius:8px;border:0;background:#C62839;color:#fff}}@media(prefers-color-scheme:dark){{
body{{background:#111;color:#eee}}}}</style></head><body><h1>{title}</h1><p>{body}</p>{form}</body></html>"""


class PublicStopView(APIView):
    """SMS stop link. GET shows ONE button (link previews never stop anyone
    by accident); POST stops every message from that shop at once."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def _page(self, lang, title, body, form="", status=200):
        return HttpResponse(_PAGE.format(lang=lang, title=escape(title), body=escape(body),
                                         form=form), status=status,
                            content_type="text/html; charset=utf-8")

    def get(self, request, token):
        s = S.send_for_token(token)
        lang = "en" if (s and s.lang == "en") else "bn"
        if s is None:
            return self._page(lang, "লিংক ঠিক নয় / Link not valid",
                              "এই লিংকটি আর কাজ করে না। / This link does not work.", status=404)
        shop = S.shop_name(s.business)
        done = MG.is_opted_out(s.business_id, s.audience_key)
        if done:
            return self._page(lang, pick(lang, "বন্ধ করা হয়েছে", "Stopped"),
                              pick(lang, "%s আর নিজে থেকে মেসেজ পাঠাবে না।" % shop,
                                   "%s will not message you first again." % shop))
        form = ('<form method="post"><button type="submit">%s</button></form>'
                % escape(pick(lang, "মেসেজ বন্ধ করুন", "Stop messages")))
        return self._page(lang, pick(lang, "মেসেজ বন্ধ করবেন?", "Stop messages?"),
                          pick(lang, "%s থেকে আর কোনো স্বয়ংক্রিয় মেসেজ চাইলে না, নিচে চাপুন।" % shop,
                               "Tap below to get no more automatic messages from %s." % shop), form)

    def post(self, request, token):
        s = S.send_for_token(token)
        if s is None:
            return self._page("bn", "লিংক ঠিক নয় / Link not valid",
                              "এই লিংকটি আর কাজ করে না। / This link does not work.", status=404)
        S.opt_out_send(s, "sms_link")
        lang = "en" if s.lang == "en" else "bn"
        shop = S.shop_name(s.business)
        return self._page(lang, pick(lang, "বন্ধ করা হয়েছে", "Stopped"),
                          pick(lang, "%s আর নিজে থেকে মেসেজ পাঠাবে না।" % shop,
                               "%s will not message you first again." % shop))
