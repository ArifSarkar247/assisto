"""
P1 Business AI Agent — Meta Graph API send clients (Messenger, Instagram,
WhatsApp Cloud API). OFFICIAL endpoints only.

* The Graph API version lives in ONE constant (GRAPH_VERSION); the owner can
  override it in Owner Admin → Integrations → "Meta app" (graph_version).
* Every call goes through `transport(method, url, headers, body) -> (status,
  json)` so tests inject recorded fake responses (no network in tests).
* Honest results: {"ok": bool, "id": str, "error": str, "status": int}. We
  never report a send as done unless Graph returned an id.
* 24 h rule: callers decide with business_ai.outbound_message_plan(); outside
  the window WhatsApp gets ONLY an approved template, Messenger/Instagram get
  nothing (the seller is told why).
"""
import json
import urllib.error
import urllib.request

GRAPH_VERSION = "v23.0"
GRAPH_HOST = "https://graph.facebook.com"
TIMEOUT_S = 10   # srvperf/H: bounded; plus the shared 'graph' circuit


def graph_version():
    try:
        from . import integrations
        v = (integrations.get("meta_app").get("graph_version") or "").strip()
        if v.startswith("v") and len(v) <= 8:
            return v
    except Exception:
        pass
    return GRAPH_VERSION


def base_url():
    return "%s/%s" % (GRAPH_HOST, graph_version())


def http_transport(method, url, headers, body):
    """Real network call (urllib). Returns (status, parsed_json_or_{})."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            raw = r.read().decode() or "{}"
            try:
                return r.status, json.loads(raw)
            except ValueError:
                return r.status, {"raw": raw[:300]}
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}
    except Exception as e:  # noqa: BLE001 — network error is an honest failure
        return 0, {"error": {"message": type(e).__name__}}


_transport = http_transport


def set_transport(fn):
    """Tests: install a fake transport. Returns the previous one."""
    global _transport
    prev = _transport
    _transport = fn or http_transport
    return prev


def _call(method, url, headers, body):
    """srvperf/H: every Graph call goes through the shared 'graph' circuit
    (core/ext_breaker.py): when Meta is down, callers get an honest
    'graph_unavailable' at once instead of a 10 s wait each."""
    from . import ext_breaker as XB
    if not XB.allow("graph"):
        return 0, {"error": {"message": "graph_unavailable"}}
    status, js = _transport(method, url, headers, body)
    XB.book("graph", bool(status) and status < 500, "http %s" % status)
    return status, js


def _result(status, js):
    if 200 <= status < 300:
        mid = (js.get("message_id") or js.get("id")
               or ((js.get("messages") or [{}])[0].get("id") if js.get("messages") else ""))
        if mid:
            return {"ok": True, "id": str(mid), "error": "", "status": status}
        return {"ok": True, "id": "", "error": "", "status": status}
    err = js.get("error") or {}
    msg = err.get("message") if isinstance(err, dict) else str(err)
    code = err.get("code") if isinstance(err, dict) else None
    return {"ok": False, "id": "", "status": status,
            "error": ("%s%s" % (msg or "send failed", (" (code %s)" % code) if code else ""))[:200]}


def _post(path, token, body):
    if not token:
        return {"ok": False, "id": "", "status": 0, "error": "no_token"}
    url = "%s/%s" % (base_url(), path.lstrip("/"))
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
    status, js = _call("POST", url, headers, body)
    return _result(status, js or {})


def _get(path, token):
    if not token:
        return {"ok": False, "status": 0, "error": "no_token", "json": {}}
    url = "%s/%s" % (base_url(), path.lstrip("/"))
    status, js = _call("GET", url, {"Authorization": "Bearer " + token}, None)
    r = _result(status, js or {})
    r["json"] = js or {}
    return r


# ------------------------------------------------------------- Messenger / IG
def _tagged(body, tag):
    """salesbar: tag="HUMAN_AGENT" = a PERSON's reply 24 h - 7 days after the
    customer's last message (Meta Human Agent feature; never an AI reply)."""
    if tag:
        body["messaging_type"] = "MESSAGE_TAG"
        body["tag"] = tag
    return body


def _quick_replies(quick):
    """bizsales-proof: Messenger / Instagram quick-reply chips (max 13, title
    max 20 chars, payload max 1000) — [{"id": payload, "title": label}]."""
    out = []
    for q in (quick or [])[:13]:
        if isinstance(q, dict) and q.get("id") and q.get("title"):
            out.append({"content_type": "text", "title": str(q["title"])[:20],
                        "payload": str(q["id"])[:1000]})
    return out


def send_messenger(page_token, psid, text, page_id="me", tag="", quick=None):
    """Messenger Send API: POST /{page-id}/messages (RESPONSE type — inside the
    24 h window only; MESSAGE_TAG + HUMAN_AGENT for a person's late reply)."""
    msg = {"text": (text or "")[:2000]}
    qr = _quick_replies(quick)
    if qr:
        msg["quick_replies"] = qr
    return _post("%s/messages" % (page_id or "me"), page_token, _tagged({
        "recipient": {"id": psid}, "messaging_type": "RESPONSE",
        "message": msg}, tag))


def send_instagram(page_token, igsid, text, ig_account_id="me", tag="", quick=None):
    """Instagram Messaging (via the linked Page token): POST /{ig-id|me}/messages."""
    msg = {"text": (text or "")[:1000]}
    qr = _quick_replies(quick)
    if qr:
        msg["quick_replies"] = qr
    body = {"recipient": {"id": igsid}, "message": msg}
    return _post("%s/messages" % (ig_account_id or "me"), page_token, _tagged(body, tag))


def send_messenger_image(page_token, psid, url, page_id="me"):
    """g1: one product photo (Messenger / Instagram attachment by URL)."""
    return _post("%s/messages" % (page_id or "me"), page_token, {
        "recipient": {"id": psid}, "messaging_type": "RESPONSE",
        "message": {"attachment": {"type": "image",
                                   "payload": {"url": url, "is_reusable": False}}}})


def private_reply(page_token, comment_id, text, page_id="me"):
    """Private reply to a Page/IG comment (one per comment, within 7 days):
    recipient={comment_id}."""
    return _post("%s/messages" % (page_id or "me"), page_token, {
        "recipient": {"comment_id": comment_id},
        "message": {"text": (text or "")[:2000]}})


def public_comment_reply(page_token, comment_id, text, instagram=False):
    """Public reply under a comment. Facebook: POST /{comment-id}/comments
    (pages_manage_engagement). Instagram: POST /{ig-comment-id}/replies."""
    path = ("%s/replies" if instagram else "%s/comments") % comment_id
    return _post(path, page_token, {"message": (text or "")[:800]})


def subscribe_page(page_token, page_id):
    """Subscribe our app to the Page's webhooks (messages + feed)."""
    return _post("%s/subscribed_apps" % page_id, page_token, {
        "subscribed_fields": ["messages", "messaging_postbacks", "message_echoes", "feed"]})


def page_info(page_token):
    """GET /me?fields=id,name — validates a Page token on connect."""
    return _get("me?fields=id,name", page_token)


def ig_account_info(token):
    """bizagent-iso: GET /me?fields=id,name,instagram_business_account — with a
    Page token `id` is the Page and instagram_business_account.id the linked
    IG account; with an Instagram-login token `id` is the IG user itself."""
    return _get("me?fields=id,name,instagram_business_account", token)


def _delete(path, token):
    if not token:
        return {"ok": False, "id": "", "status": 0, "error": "no_token"}
    url = "%s/%s" % (base_url(), path.lstrip("/"))
    status, js = _call("DELETE", url, {"Authorization": "Bearer " + token}, None)
    return _result(status, js or {})


def unsubscribe_page(page_token, page_id):
    """bizagent-iso: DELETE /{page-id}/subscribed_apps on disconnect."""
    return _delete("%s/subscribed_apps" % page_id, page_token)


def unsubscribe_waba(token, waba_id):
    """bizagent-iso: DELETE /{waba-id}/subscribed_apps on disconnect."""
    return _delete("%s/subscribed_apps" % waba_id, token)


def owned_id_matches(kind, info, external_id):
    """bizagent-iso: does the Graph answer for the token prove it owns
    `external_id`? Messenger: /me id == page id. Instagram: the Page's linked
    instagram_business_account id (or the IG-login user id) == IG id.
    WhatsApp: GET /{phone-number-id} answered with that same id."""
    js = (info or {}).get("json") or {}
    ext = str(external_id or "")
    if not ext or not (info or {}).get("ok"):
        return False
    if kind == "instagram":
        iba = js.get("instagram_business_account") or {}
        ids = {str(js.get("id") or ""), str(iba.get("id") or "") if isinstance(iba, dict) else ""}
        return ext in ids
    return str(js.get("id") or "") == ext


# ------------------------------------------------------------- WhatsApp Cloud
def send_whatsapp_text(token, phone_number_id, to, text):
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "recipient_type": "individual",
        "to": to, "type": "text", "text": {"preview_url": False, "body": (text or "")[:4096]}})


def send_whatsapp_buttons(token, phone_number_id, to, text, quick):
    """bizsales-proof: WhatsApp Cloud API interactive reply buttons (max 3,
    title max 20 chars, id max 256) — inside the 24 h window only."""
    btns = [{"type": "reply", "reply": {"id": str(q["id"])[:256], "title": str(q["title"])[:20]}}
            for q in (quick or [])[:3] if isinstance(q, dict) and q.get("id") and q.get("title")]
    if not btns:
        return send_whatsapp_text(token, phone_number_id, to, text)
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "recipient_type": "individual", "to": to,
        "type": "interactive",
        "interactive": {"type": "button", "body": {"text": (text or "")[:1024]},
                        "action": {"buttons": btns}}})


def send_whatsapp_template(token, phone_number_id, to, name, lang_code="bn", params=None,
                           button_payloads=None):
    comps = []
    if params:
        comps = [{"type": "body", "parameters": [{"type": "text", "text": str(p)[:200]}
                                                  for p in params]}]
    # bizsales-proof: the template's QUICK_REPLY buttons get their payload at
    # send time (one component per button index) — the reply webhook carries it
    for i, pl in enumerate((button_payloads or [])[:3]):
        comps.append({"type": "button", "sub_type": "quick_reply", "index": str(i),
                      "parameters": [{"type": "payload", "payload": str(pl)[:256]}]})
    tmpl = {"name": name, "language": {"code": lang_code}}
    if comps:
        tmpl["components"] = comps
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "to": to, "type": "template", "template": tmpl})


def send_whatsapp_image(token, phone_number_id, to, url, caption=""):
    """g1: one product photo by link (+ caption) on WhatsApp Cloud API."""
    img = {"link": url}
    if caption:
        img["caption"] = caption[:1024]
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "recipient_type": "individual",
        "to": to, "type": "image", "image": img})


def whatsapp_number_info(token, phone_number_id):
    """GET /{phone-number-id}?fields=display_phone_number,verified_name."""
    return _get("%s?fields=display_phone_number,verified_name" % phone_number_id, token)


def waba_ids_for_token(token, app_id, app_secret):
    """e2e-sales: the WhatsApp Business Account id(s) a token was granted
    (GET /debug_token, granular_scopes → whatsapp_business_messaging /
    _management target_ids — the documented Embedded-Signup way). Needs the
    Meta app's own access token (app_id|app_secret). [] when unknown."""
    if not (token and app_id and app_secret):
        return []
    from urllib.parse import quote
    r = _get("debug_token?input_token=%s" % quote(token, safe=""),
             "%s|%s" % (app_id, app_secret))
    data = (r.get("json") or {}).get("data") or {}
    out = []
    for g in data.get("granular_scopes") or []:
        if g.get("scope") in ("whatsapp_business_messaging", "whatsapp_business_management"):
            for t in g.get("target_ids") or []:
                if str(t).isdigit() and str(t) not in out:
                    out.append(str(t))
    return out


def subscribe_waba(token, waba_id):
    """Subscribe our app to the WABA's webhooks (POST /{waba-id}/subscribed_apps).
    Without it a seller's own number never sends us its messages."""
    return _post("%s/subscribed_apps" % waba_id, token, {})
