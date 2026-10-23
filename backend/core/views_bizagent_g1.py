"""
G1 — Business AI Agent (advanced) HTTP surface, under /api/v1/bizagent/.

SELLER (signed-in business owner; staff may read + reply):
  POST threads/<id>/mode {mode: human|ai}   per-chat toggle: "I will reply" / "Let AI reply"
  GET  faqs                                 approved + suggested (learned) FAQ
  POST faqs {question, answer}              add an approved FAQ (owner)
  POST faqs/<id> {question?, answer?, status?}  edit / approve / reject
  POST faqs/<id>/delete
  POST faqs/learn                           learn suggestions from my past replies
  GET  post-links, POST post-links {post_id, product_id}, POST post-links/<id>/delete
  GET  agent-report?days=30                 chats, orders, revenue by the agent, AI cost, profit,
                                            rules vs AI
  POST widget {enabled?, origins?, regenerate?}   website chat widget
  POST orders/<id>/payment {status: verified|rejected}   the OWNER verifies a payment

PUBLIC (website chat widget; per-business key, origin-checked, rate-limited):
  GET  chat.js                              the embeddable script (served from our domain,
                                            under /api/ so no new web-server route is needed)
  POST widget/<key>/send {visitor, text}
  GET  widget/<key>/messages?visitor=&after=
"""
import hashlib
from datetime import timedelta

from django.conf import settings
from django.http import HttpResponse, JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from rest_framework.response import Response
from rest_framework.views import APIView

from . import bizagent_g1_service as G1S
from . import bizagent_service as S
from .business_views import _err
from .i18n import req_lang
from .logic import bizagent_g1 as G1
from .views_bizagent import _ctx, _thread

WIDGET_PER_MIN = 8
WIDGET_PER_HOUR = 60
WIDGET_IP_PER_HOUR = 80
WIDGET_BIZ_PER_HOUR = 600


# =========================================================== seller
class ThreadModeView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        lang = req_lang(request)
        t = _thread(prof, pk)
        if not t:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        mode = request.data.get("mode")
        if mode not in ("human", "ai"):
            return _err(lang, "human অথবা ai দিন।", "Use human or ai.", status=422,
                        code="bad_mode")
        G1S.set_reply_mode(t, mode)
        return Response({"ok": True, "reply_mode": mode, "handover": t.owner_takeover})


def _faq_row(f):
    return {"id": f.id, "question": f.question, "answer": f.answer, "status": f.status,
            "source": f.source, "has_price": f.has_price, "hits": f.hits,
            "updated_at": f.updated_at.isoformat()}


class FaqsView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        from .models import BizFaq
        rows = BizFaq.objects.filter(business=prof).exclude(status="rejected")
        return Response({"faqs": [_faq_row(f) for f in rows[:300]],
                         "rules_enabled": a.rules_enabled})

    def post(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        from .models import BizFaq
        lang = req_lang(request)
        q = str(request.data.get("question") or "").strip()[:500]
        ans = str(request.data.get("answer") or "").strip()[:1500]
        if len(q) < 3 or len(ans) < 2:
            return _err(lang, "প্রশ্ন ও উত্তর দুটোই লিখুন।", "Write both the question and the answer.",
                        status=422, code="empty")
        if BizFaq.objects.filter(business=prof).count() >= 300:
            return _err(lang, "সর্বোচ্চ ৩০০টি FAQ রাখা যায়।", "At most 300 FAQs.", status=409,
                        code="limit")
        from .logic import bizagent_rules as R
        f = BizFaq.objects.create(business=prof, question=q, answer=ans, status="approved",
                                  source="manual", has_price=R.has_money(ans))
        return Response({"ok": True, "faq": _faq_row(f)}, status=201)


class FaqDetailView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        from .models import BizFaq
        from .logic import bizagent_rules as R
        lang = req_lang(request)
        f = BizFaq.objects.filter(business=prof, pk=pk).first()
        if not f:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        d = request.data or {}
        if "question" in d:
            f.question = str(d.get("question") or "").strip()[:500] or f.question
        if "answer" in d:
            f.answer = str(d.get("answer") or "").strip()[:1500] or f.answer
            f.has_price = R.has_money(f.answer)
        if d.get("status") in ("approved", "suggested", "rejected"):
            f.status = d["status"]
        f.save()
        return Response({"ok": True, "faq": _faq_row(f)})


class FaqDeleteView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        from .models import BizFaq
        n, _ = BizFaq.objects.filter(business=prof, pk=pk).delete()
        return Response({"ok": bool(n)})


class FaqLearnView(APIView):
    def post(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        n = G1S.learn_faqs(prof)
        return Response({"ok": True, "suggested": n}, status=201 if n else 200)


def _link_row(l):
    return {"id": l.id, "post_id": l.post_id, "product_id": l.product_id,
            "product": l.product.name}


class PostLinksView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        rows = prof.biz_post_links.select_related("product").order_by("-id")[:200]
        return Response({"links": [_link_row(l) for l in rows], "comment_dm": a.comment_dm})

    def post(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        from .models import BizPostLink, Product
        lang = req_lang(request)
        post_id = str(request.data.get("post_id") or "").strip()
        if not post_id or len(post_id) > 80 or not all(c.isdigit() or c == "_" for c in post_id):
            return _err(lang, "পোস্টের আইডি সঠিক নয় (যেমন 123_456)।",
                        "The post id is not valid (e.g. 123_456).", status=422, code="bad_post")
        p = Product.objects.filter(pk=request.data.get("product_id"), user=prof.user).first()
        if not p:
            return _err(lang, "পণ্য পাওয়া যায়নি।", "Product not found.", status=404)
        link, _ = BizPostLink.objects.update_or_create(business=prof, post_id=post_id,
                                                       defaults={"product": p})
        return Response({"ok": True, "link": _link_row(link)}, status=201)


class PostLinkDeleteView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        n, _ = prof.biz_post_links.filter(pk=pk).delete()
        return Response({"ok": bool(n)})


class AgentReportView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        try:
            days = max(1, min(90, int(request.query_params.get("days") or 30)))
        except ValueError:
            days = 30
        rep = G1S.agent_report(prof, days=days)
        if role != "owner":
            rep["gross_profit"] = None       # cost prices are owner-only
            rep["profit"] = None
        st = G1S.rules_stats(days=days, business=prof)
        return Response({"days": days, "report": rep,
                         "rules": {k: st[k] for k in ("rule", "ai", "rule_pct",
                                                      "saved_seller_credits", "saved_seller_bdt",
                                                      "by_rule")}})


def _widget_state(a):
    return {"enabled": a.widget_enabled, "key": a.widget_key,
            "origins": a.widget_origins,
            "snippet": G1S.widget_snippet(a.widget_key) if a.widget_key else ""}


class WidgetView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        return Response(_widget_state(a))

    def post(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        d = request.data or {}
        if d.get("regenerate"):
            a.widget_key = ""
        if "origins" in d:
            a.widget_origins = "\n".join(
                o.strip().rstrip("/") for o in str(d.get("origins") or "").split()
                if o.strip().startswith(("https://", "http://localhost")))[:1000]
        if "enabled" in d:
            a.widget_enabled = bool(d.get("enabled"))
        a.save()
        if a.widget_enabled or d.get("regenerate"):
            G1S.ensure_widget_key(a)
            G1S.widget_channel(prof)
        return Response({"ok": True, **_widget_state(a)})


class OrderPaymentView(APIView):
    """Only the OWNER marks a payment verified (after checking their own
    bKash/Nagad/bank) — Assisto never moves or confirms money itself."""

    def post(self, request, pk):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        from .models import Order
        lang = req_lang(request)
        o = Order.objects.filter(pk=pk, business=prof).first()
        if not o:
            return _err(lang, "অর্ডার পাওয়া যায়নি।", "Order not found.", status=404)
        st = request.data.get("status")
        if st not in ("verified", "rejected"):
            return _err(lang, "verified অথবা rejected দিন।", "Use verified or rejected.",
                        status=422, code="bad_status")
        o.payment_status = st
        o.save(update_fields=["payment_status"])
        return Response({"ok": True, "payment_status": o.payment_status})


# =========================================================== public widget
def _cors(resp, origin, a):
    if origin and G1.origin_allowed(origin, a.widget_origins if a else ""):
        resp["Access-Control-Allow-Origin"] = origin
        resp["Vary"] = "Origin"
        resp["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        resp["Access-Control-Allow-Headers"] = "Content-Type"
        resp["Access-Control-Max-Age"] = "600"
    return resp


def _ip_hash(request):
    ip = (request.META.get("HTTP_X_FORWARDED_FOR", "").split(",")[0].strip()
          or request.META.get("REMOTE_ADDR", ""))
    return hashlib.sha256((ip + settings.SECRET_KEY[:8]).encode()).hexdigest()[:24]


def _widget_gate(request, key):
    """(agent, channel, error_response)."""
    a = G1S.agent_by_widget_key(key)
    origin = request.headers.get("Origin", "")
    if a is None:
        return None, None, JsonResponse({"ok": False, "error": "unknown_widget"}, status=404)
    if not G1.origin_allowed(origin, a.widget_origins):
        return None, None, JsonResponse({"ok": False, "error": "origin_not_allowed"}, status=403)
    ch = G1S.widget_channel(a.business)
    if not ch.enabled:
        return None, None, _cors(JsonResponse({"ok": False, "error": "disabled"}, status=403),
                                 origin, a)
    return a, ch, None


def _out_row(m):
    return {"id": m.id, "dir": m.direction, "text": m.text, "kind": m.kind,
            "image": (m.meta or {}).get("image_url", ""), "at": m.created_at.isoformat()}


@csrf_exempt
def widget_send(request, key):
    origin = request.headers.get("Origin", "")
    a, ch, bad = _widget_gate(request, key)
    if request.method == "OPTIONS":
        return _cors(HttpResponse(status=204), origin, a)
    if bad:
        return bad
    if request.method != "POST":
        return _cors(HttpResponse(status=405), origin, a)
    import json
    try:
        d = json.loads((request.body or b"{}")[:8000].decode("utf-8") or "{}")
    except (ValueError, UnicodeDecodeError):
        return _cors(JsonResponse({"ok": False, "error": "bad_json"}, status=400), origin, a)
    visitor = str(d.get("visitor") or "")
    text = str(d.get("text") or "").strip()[:1000]
    if not G1.valid_visitor(visitor) or not text:
        return _cors(JsonResponse({"ok": False, "error": "bad_request"}, status=422), origin, a)
    from .models import ChatThread, Message
    now = timezone.now()
    iph = _ip_hash(request)
    t = ChatThread.objects.filter(seller_channel=ch, external_user_id=visitor).first()
    recent = Message.objects.filter(thread__seller_channel=ch, direction="in")
    if t is not None:
        mine = recent.filter(thread=t)
        if mine.filter(created_at__gte=now - timedelta(minutes=1)).count() >= WIDGET_PER_MIN or \
                mine.filter(created_at__gte=now - timedelta(hours=1)).count() >= WIDGET_PER_HOUR:
            return _cors(JsonResponse({"ok": False, "error": "rate_limited"}, status=429), origin, a)
    if recent.filter(meta__ip=iph, created_at__gte=now - timedelta(hours=1)).count() >= \
            WIDGET_IP_PER_HOUR or recent.filter(created_at__gte=now - timedelta(hours=1)).count() \
            >= WIDGET_BIZ_PER_HOUR:
        return _cors(JsonResponse({"ok": False, "error": "rate_limited"}, status=429), origin, a)
    eid = "web-in-" + hashlib.sha256(("%s|%s|%s" % (visitor, text, now.isoformat()))
                                     .encode()).hexdigest()[:24]
    ev = {"channel": "website", "account_id": ch.external_id, "user_id": visitor,
          "event_id": eid, "text": text, "ts": int(now.timestamp()), "name": "",
          "kind": "message", "attachments": []}
    res = S.handle_message(ch, ev)
    Message.objects.filter(external_id=eid).update(meta={"ip": iph})
    t = ChatThread.objects.filter(seller_channel=ch, external_user_id=visitor).first()
    rows = [_out_row(m) for m in t.messages.filter(direction="out").exclude(
        status__in=("pending_approval", "rejected", "approved", "failed"))
        .order_by("-created_at", "-id")[:5]][::-1] if t else []
    return _cors(JsonResponse({"ok": True, "status": res, "messages": rows}), origin, a)


@csrf_exempt
def widget_messages(request, key):
    origin = request.headers.get("Origin", "")
    a, ch, bad = _widget_gate(request, key)
    if request.method == "OPTIONS":
        return _cors(HttpResponse(status=204), origin, a)
    if bad:
        return bad
    visitor = request.GET.get("visitor", "")
    if not G1.valid_visitor(visitor):
        return _cors(JsonResponse({"ok": False, "error": "bad_request"}, status=422), origin, a)
    from .models import ChatThread
    t = ChatThread.objects.filter(seller_channel=ch, external_user_id=visitor).first()
    try:
        after = int(request.GET.get("after") or 0)
    except ValueError:
        after = 0
    rows = []
    if t is not None:
        rows = [_out_row(m) for m in t.messages.filter(id__gt=after).exclude(
            status__in=("pending_approval", "rejected", "approved", "failed"))
            .order_by("created_at", "id")[:50]]
    return _cors(JsonResponse({"ok": True, "shop": a.business.shop_name or "",
                               "messages": rows}), origin, a)


WIDGET_JS = r"""/* Assisto website chat widget — the shop's AI sales assistant (official, rule-first,
   prices from the shop's catalog). Embed: <script src="https://api.lifeassisto.com/api/v1/bizagent/chat.js" data-key="w_..." async></script> */
(function(){
  var s=document.currentScript||document.querySelector('script[data-key][src*="/bizagent/chat.js"]');
  if(!s||window.__assistoChat)return; window.__assistoChat=1;
  var key=s.getAttribute('data-key')||'', base=s.src.replace(/\/chat\.js.*$/,'')+'/widget/'+encodeURIComponent(key);
  var bn=(document.documentElement.lang||navigator.language||'bn').indexOf('en')!==0;
  var T=bn?{t:'আমাদের সাথে চ্যাট করুন',p:'মেসেজ লিখুন…',s:'পাঠান',a:'এটি দোকানের AI সহকারী। প্রয়োজনে দোকানের একজন উত্তর দেবেন।',e:'পাঠানো যায়নি, আবার চেষ্টা করুন।'}
              :{t:'Chat with us',p:'Type a message…',s:'Send',a:"This is the shop's AI assistant. A person from the shop replies when needed.",e:'Could not send, please try again.'};
  var vid; try{vid=localStorage.getItem('assisto_vid');}catch(e){}
  if(!vid){vid='v'+Math.random().toString(36).slice(2)+Date.now().toString(36);try{localStorage.setItem('assisto_vid',vid);}catch(e){}}
  var last=0, open=false, timer=null, primed=false;
  var css='#asw-b{position:fixed;right:16px;bottom:16px;z-index:2147483000;width:56px;height:56px;border-radius:28px;border:0;background:linear-gradient(135deg,#06b6d4,#2563eb,#7c3aed);color:#fff;font-size:24px;cursor:pointer;box-shadow:0 4px 16px rgba(0,0,0,.25)}'+
   '#asw-p{position:fixed;right:16px;bottom:84px;z-index:2147483000;width:min(360px,calc(100vw - 32px));height:min(480px,calc(100vh - 120px));background:#fff;color:#111;border-radius:16px;box-shadow:0 8px 32px rgba(0,0,0,.25);display:none;flex-direction:column;overflow:hidden;font:14px/1.5 system-ui,"Noto Sans Bengali",sans-serif}'+
   '#asw-h{padding:12px 16px;background:#1d4ed8;color:#fff;font-weight:600}#asw-n{padding:6px 16px;font-size:12px;color:#374151;background:#f3f4f6}'+
   '#asw-m{flex:1;overflow-y:auto;padding:12px;display:flex;flex-direction:column;gap:8px}.asw-i,.asw-o{max-width:85%;padding:8px 12px;border-radius:12px;white-space:pre-wrap;word-wrap:break-word}'+
   '.asw-i{align-self:flex-end;background:#1d4ed8;color:#fff}.asw-o{align-self:flex-start;background:#f3f4f6;color:#111}.asw-o img{max-width:100%;border-radius:8px;display:block;margin-bottom:4px}'+
   '#asw-f{display:flex;gap:8px;padding:8px;border-top:1px solid #e5e7eb}#asw-t{flex:1;min-height:40px;border:1px solid #d1d5db;border-radius:8px;padding:8px;font:inherit;color:#111;background:#fff}#asw-s{min-width:64px;min-height:40px;border:0;border-radius:8px;background:#1d4ed8;color:#fff;font:inherit;cursor:pointer}'+
   '@media (prefers-color-scheme:dark){#asw-p{background:#111827;color:#f9fafb}#asw-n{background:#1f2937;color:#d1d5db}.asw-o{background:#1f2937;color:#f9fafb}#asw-t{background:#111827;color:#f9fafb;border-color:#374151}#asw-f{border-color:#374151}}';
  var st=document.createElement('style');st.textContent=css;document.head.appendChild(st);
  var b=document.createElement('button');b.id='asw-b';b.setAttribute('aria-label',T.t);b.textContent='\u{1F4AC}';
  var p=document.createElement('div');p.id='asw-p';p.setAttribute('role','dialog');p.setAttribute('aria-label',T.t);
  p.innerHTML='<div id="asw-h"></div><div id="asw-n"></div><div id="asw-m" aria-live="polite"></div><form id="asw-f"><input id="asw-t" maxlength="1000" autocomplete="off"><button id="asw-s" type="submit"></button></form>';
  document.body.appendChild(b);document.body.appendChild(p);
  var h=p.querySelector('#asw-h'),n=p.querySelector('#asw-n'),m=p.querySelector('#asw-m'),f=p.querySelector('#asw-f'),t=p.querySelector('#asw-t'),sb=p.querySelector('#asw-s');
  h.textContent=T.t;n.textContent=T.a;t.placeholder=T.p;sb.textContent=T.s;
  function add(r){ if(r.id&&r.id<=last)return; if(r.id)last=r.id; if(r.dir==='in'&&primed)return; var d=document.createElement('div');d.className=r.dir==='in'?'asw-i':'asw-o';
    if(r.image&&/^https:\/\//.test(r.image)){var im=document.createElement('img');im.src=r.image;im.alt=r.text||'';d.appendChild(im);}
    d.appendChild(document.createTextNode(r.text||''));m.appendChild(d);m.scrollTop=m.scrollHeight;}
  function poll(){fetch(base+'/messages?visitor='+vid+'&after='+last).then(function(r){return r.json()}).then(function(j){(j.messages||[]).forEach(add);primed=true;if(j.shop)h.textContent=j.shop;}).catch(function(){});}
  b.onclick=function(){open=!open;p.style.display=open?'flex':'none';if(open){poll();timer=setInterval(poll,5000);t.focus();}else{clearInterval(timer);}};
  f.onsubmit=function(e){e.preventDefault();var v=t.value.trim();if(!v)return;t.value='';
    var d=document.createElement('div');d.className='asw-i';d.textContent=v;m.appendChild(d);m.scrollTop=m.scrollHeight;
    fetch(base+'/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({visitor:vid,text:v})})
     .then(function(r){return r.json()}).then(function(j){if(!j.ok){var x=document.createElement('div');x.className='asw-o';x.textContent=T.e;m.appendChild(x);}setTimeout(poll,600);})
     .catch(function(){var x=document.createElement('div');x.className='asw-o';x.textContent=T.e;m.appendChild(x);});};
})();
"""


def widget_js(request):
    resp = HttpResponse(WIDGET_JS, content_type="application/javascript; charset=utf-8")
    resp["Cache-Control"] = "public, max-age=3600"
    resp["Access-Control-Allow-Origin"] = "*"
    resp["X-Content-Type-Options"] = "nosniff"
    return resp
