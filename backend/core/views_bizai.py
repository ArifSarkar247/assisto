"""bizai — DRF wiring for core/bizai_service.py (flag `business_agent`).

Shop side (owner / active staff; switches owner-only):
  GET  bizai/shop-link           code, share url, switches
  POST bizai/shop-link           {app_chat_enabled?, cod_risk_guard?}
  GET  bizai/outcomes?days=7     the Business-home outcome card (real rows)
Customer side (any signed-in account):
  GET  shopchat/mine             shops I chat with + My Circle contacts' shops
  GET  shopchat/<code>           shop + disclosure + my messages
  GET  shopchat/<code>/messages?after=<id>
  POST shopchat/<code>/send      JSON {text} or multipart {text?, file, type image|audio}
  POST shopchat/<code>/person    "Talk to a person"
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import bizai_service as BA
from . import feature_flags as FF
from .business_views import _owner_only, _require_business
from .i18n import is_play_flavour, pick, req_lang

FLAG = "business_agent"


def _off(request):
    return not FF.is_on(FLAG, request.user, is_play_flavour(request))


def _refuse(request, reason, code):
    lang = req_lang(request)
    text = {
        "off": ("এই সুবিধা এখন বন্ধ।", "This feature is off right now."),
        "not_found": ("দোকানটি পাওয়া যায়নি — লিংকটি আবার দেখুন।",
                      "Shop not found — please check the link."),
        "chat_off": ("এই দোকান এখন অ্যাপে চ্যাট নিচ্ছে না।",
                     "This shop is not taking app chats right now."),
        "own_shop": ("এটা আপনার নিজের দোকান — গ্রাহকের চ্যাট Business → ইনবক্সে দেখুন।",
                     "This is your own shop — see customer chats in Business → Inbox."),
        "empty": ("কিছু লিখুন বা ছবি/ভয়েস পাঠান।", "Type something or send a photo / voice note."),
        "bad_upload": ("ফাইলটি পাঠানো গেল না (ছবি বা ভয়েস, ৬ MB পর্যন্ত)।",
                       "That file could not be sent (photo or voice, up to 6 MB)."),
        "rate_limited": ("একটু ধীরে — এক মিনিট পরে আবার পাঠান।",
                         "Slow down a little — try again in a minute."),
    }.get(reason, ("কাজটি করা যায়নি।", "That did not work."))
    return Response({"ok": False, "reason": reason, "detail": pick(lang, *text)}, status=code)


class ShopLinkView(APIView):
    def get(self, request):
        if _off(request):
            return _refuse(request, "off", 404)
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        a = BA._S().agent_for(prof)
        return Response({"code": BA.shop_code(prof), "url": BA.share_url(prof),
                         "shop": prof.shop_name or "", "app_chat_enabled": a.app_chat_enabled,
                         "cod_risk_guard": a.cod_risk_guard, "ai_on": a.ai_enabled})

    def post(self, request):
        if _off(request):
            return _refuse(request, "off", 404)
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        g = _owner_only(request, role)
        if g:
            return g
        a = BA._S().agent_for(prof)
        changed = []
        for k in ("app_chat_enabled", "cod_risk_guard"):
            if k in request.data:
                setattr(a, k, bool(request.data.get(k)))
                changed.append(k)
        if changed:
            a.save(update_fields=changed + ["updated_at"])
            if "app_chat_enabled" in changed:
                BA.app_channel(prof)
        return self.get(request)


class OutcomesView(APIView):
    def get(self, request):
        if _off(request):
            return _refuse(request, "off", 404)
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        try:
            days = max(1, min(int(request.query_params.get("days") or 7), 90))
        except ValueError:
            days = 7
        return Response(BA.outcomes(prof, days=days))


class _Customer(APIView):
    def shop(self, request, code):
        if _off(request):
            return None, _refuse(request, "off", 404)
        b = BA.business_for_code(code)
        if b is None:
            return None, _refuse(request, "not_found", 404)
        return b, None


class ShopChatMineView(APIView):
    def get(self, request):
        if _off(request):
            return _refuse(request, "off", 404)
        return Response({"shops": BA.my_shops(request.user)})


class ShopChatView(_Customer):
    def get(self, request, code):
        b, bad = self.shop(request, code)
        if bad:
            return bad
        return Response(BA.shop_view(request.user, b, req_lang(request)))


class ShopChatMessagesView(_Customer):
    def get(self, request, code):
        b, bad = self.shop(request, code)
        if bad:
            return bad
        try:
            after = int(request.query_params.get("after") or 0)
        except ValueError:
            after = 0
        t = BA.customer_thread(request.user, b, create=False)
        return Response({"messages": BA.visible_messages(t, after=after),
                         "with_person": bool(t and t.owner_takeover)})


class ShopChatSendView(_Customer):
    def post(self, request, code):
        b, bad = self.shop(request, code)
        if bad:
            return bad
        upload = None
        f = request.FILES.get("file")
        if f is not None:
            kind = str(request.data.get("type") or "")
            if f.size > BA.MAX_UPLOAD:
                return _refuse(request, "bad_upload", 413)
            upload = {"type": kind, "bytes": f.read(), "mime": f.content_type or ""}
        lang = req_lang(request)
        st, body = BA.customer_send(request.user, b, request.data.get("text") or "",
                                    upload=upload, lang=lang,
                                    ref=str(request.data.get("ref") or "")[:12])
        if not body.get("ok"):
            return _refuse(request, body.get("reason", ""), st)
        return Response(body, status=st)


class ShopChatPersonView(_Customer):
    def post(self, request, code):
        b, bad = self.shop(request, code)
        if bad:
            return bad
        st, body = BA.talk_to_person(request.user, b, req_lang(request))
        if not body.get("ok"):
            return _refuse(request, body.get("reason", ""), st)
        return Response(body, status=st)


# ===================================================================== pillar 2: CRM
# Same gate as retention automation (flag `retention_auto`, shop owner,
# Business plan to change/send) — views_retention._Owner.
from .views_retention import _Owner as _RetOwner  # noqa: E402


class CrmSegmentsView(_RetOwner):
    need_plan = False

    def get(self, request):
        from . import bizai_crm as C
        return Response(C.segments(self.biz))


class CrmLadderView(_RetOwner):
    def get(self, request):
        from . import bizai_crm as C
        return Response(C.ladder(self.biz, req_lang(request)))

    def post(self, request):
        from . import bizai_crm as C
        lang = req_lang(request)
        if request.data.get("on") is False:
            C.stop_ladder(self.biz, request.user)
            return Response(C.ladder(self.biz, lang))
        ok, problem = C.approve_ladder(self.biz, request.user,
                                       drafts=request.data.get("drafts"),
                                       channel=str(request.data.get("channel") or "in_app"))
        if not ok:
            return Response({"ok": False, "reason": problem,
                             "detail": C.problem_text(problem, lang)}, status=400)
        return Response(C.ladder(self.biz, lang))


class CrmDraftView(_RetOwner):
    def post(self, request):
        from . import bizai_crm as C
        lang = "en" if request.data.get("lang") == "en" else "bn"
        text, problem = C.ai_draft(request.user, str(request.data.get("stage") or ""),
                                   str(request.data.get("text") or ""), lang)
        if problem:
            return Response({"ok": False, "reason": problem,
                             "detail": C.problem_text(problem, req_lang(request))},
                            status=402 if problem == "ai_insufficient" else 400)
        return Response({"ok": True, "text": text})


# ===================================================================== pillar 5: Prochar
class ProcharView(APIView):
    """GET bizai/prochar?days=30 — which posts sold (tracked codes), the best
    time to post, and this week's report (owner / staff of the shop)."""
    def get(self, request):
        if _off(request):
            return _refuse(request, "off", 404)
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        from . import bizai_prochar as BP
        try:
            days = max(1, min(int(request.query_params.get("days") or 30), 90))
        except ValueError:
            days = 30
        lang = req_lang(request)
        return Response({"attribution": BP.attribution(prof, days=days),
                         "best_hours": BP.best_hours(prof),
                         "weekly": BP.weekly_report(prof, lang)})


class ProcharTrackedView(APIView):
    """GET bizai/prochar/tracked/<item_id> — the post text with its tracked
    shop link + code, ready to share (WhatsApp status / broadcast / Page)."""
    def get(self, request, item_id):
        if _off(request):
            return _refuse(request, "off", 404)
        prof, role, bad = _require_business(request)
        if bad:
            return bad
        from . import bizai_prochar as BP
        d = BP.tracked(prof, item_id, req_lang(request))
        if d is None:
            return _refuse(request, "not_found", 404)
        return Response(d)


# ===================================================================== pillar 4: CCTV accuracy
def _cctv_off(request):
    return not FF.is_on("cctv_watchman", request.user, is_play_flavour(request))


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


class CctvAccuracyView(APIView):
    """GET bizai/cctv/accuracy?site=&days=30 — measured precision / recall
    per alert kind from reviews (+ missed reports) and live test sessions."""
    def get(self, request):
        if _cctv_off(request):
            return _refuse(request, "off", 404)
        from . import bizai_cctv as C
        days = max(1, min(_int(request.query_params.get("days")) or 30, 365))
        return Response(C.accuracy(request.user, site_id=_int(request.query_params.get("site")),
                                   days=days))


class CctvMissedView(APIView):
    """POST bizai/cctv/missed {site, kind, note?} — "it happened, no alert"."""
    def post(self, request):
        if _cctv_off(request):
            return _refuse(request, "off", 404)
        from . import bizai_cctv as C
        r = C.report_missed(request.user, _int(request.data.get("site")),
                            str(request.data.get("kind") or ""), request.data.get("note") or "")
        if r is None:
            return _refuse(request, "not_found", 404)
        return Response({"ok": True, "id": r.pk}, status=201)


class CctvTestView(APIView):
    """POST bizai/cctv/test {site} → start · POST bizai/cctv/test/<id>/mark
    {kind} → "this happened now" · POST bizai/cctv/test/<id>/stop → result."""
    def post(self, request, pk=None, action=""):
        if _cctv_off(request):
            return _refuse(request, "off", 404)
        from . import bizai_cctv as C
        if pk is None:
            r = C.start_test(request.user, _int(request.data.get("site")))
        elif action == "mark":
            r = C.mark_truth(request.user, pk, str(request.data.get("kind") or ""))
        elif action == "stop":
            r = C.stop_test(request.user, pk)
        else:
            r = None
        if r is None:
            return _refuse(request, "not_found", 404)
        d = r.data or {}
        return Response({"id": r.pk, "started": d.get("started"), "stopped": d.get("stopped"),
                         "marks": len(d.get("truth") or []), "alerts": d.get("alerts"),
                         "result": d.get("result")})
