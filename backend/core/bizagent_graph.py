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
TIMEOUT_S = 15


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
    status, js = _transport("POST", url, headers, body)
    return _result(status, js or {})


def _get(path, token):
    if not token:
        return {"ok": False, "status": 0, "error": "no_token", "json": {}}
    url = "%s/%s" % (base_url(), path.lstrip("/"))
    status, js = _transport("GET", url, {"Authorization": "Bearer " + token}, None)
    r = _result(status, js or {})
    r["json"] = js or {}
    return r


# ------------------------------------------------------------- Messenger / IG
def send_messenger(page_token, psid, text, page_id="me"):
    """Messenger Send API: POST /{page-id}/messages (RESPONSE type — inside the
    24 h window only)."""
    return _post("%s/messages" % (page_id or "me"), page_token, {
        "recipient": {"id": psid}, "messaging_type": "RESPONSE",
        "message": {"text": (text or "")[:2000]}})


def send_instagram(page_token, igsid, text, ig_account_id="me"):
    """Instagram Messaging (via the linked Page token): POST /{ig-id|me}/messages."""
    return _post("%s/messages" % (ig_account_id or "me"), page_token, {
        "recipient": {"id": igsid}, "message": {"text": (text or "")[:1000]}})


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


# ------------------------------------------------------------- WhatsApp Cloud
def send_whatsapp_text(token, phone_number_id, to, text):
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "recipient_type": "individual",
        "to": to, "type": "text", "text": {"preview_url": False, "body": (text or "")[:4096]}})


def send_whatsapp_template(token, phone_number_id, to, name, lang_code="bn", params=None):
    comps = []
    if params:
        comps = [{"type": "body", "parameters": [{"type": "text", "text": str(p)[:200]}
                                                  for p in params]}]
    tmpl = {"name": name, "language": {"code": lang_code}}
    if comps:
        tmpl["components"] = comps
    return _post("%s/messages" % phone_number_id, token, {
        "messaging_product": "whatsapp", "to": to, "type": "template", "template": tmpl})


def whatsapp_number_info(token, phone_number_id):
    """GET /{phone-number-id}?fields=display_phone_number,verified_name."""
    return _get("%s?fields=display_phone_number,verified_name" % phone_number_id, token)
