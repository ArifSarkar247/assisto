"""
SMS gateway adapters (o1-otp + smsotp) — provider-agnostic, config-driven,
key-gated.

smsotp: besides the generic entry below (integration slug "sms"), each common
gateway has its OWN integration entry with exactly the fields its public API
asks for — see GATEWAYS at the bottom (SSL Wireless, BulkSMSBD, Alpha SMS,
Infobip, Twilio). All adapters share ONE interface:

    send_result(to_canon, text, secret="") -> SendResult(ok, provider,
                                              message_id, detail, http_status)
    send(to_canon, text, secret="")        -> (ok, detail)        (legacy)
    check(test_to=None)                    -> (ok, detail)        (honest test)

`chain()` returns the CONNECTED primary (+ optional secondary) in failover
order; `adapter()` wraps that chain for the older callers. Segments, cost,
caps and logging live one level up in core/sms_service.py.

The generic entry (slug "sms"):

ONE generic HTTP adapter covers the common Bangladeshi gateways (SSL Wireless,
BulkSMSBD, Alpha SMS / sms.net.bd, MiM SMS, Infobip, ...). Everything the
gateway needs is data the owner pastes into Integrations → "SMS Gateway":

  provider        preset name (ssl_wireless | bulksmsbd | alpha_sms | mim_sms |
                  infobip | custom). A preset only fills in DEFAULTS; any field
                  the owner enters overrides it.
  api_url         the send endpoint (https preferred)
  api_key         API key / token (secret — Fernet-encrypted at rest)
  sender_id       approved masking name or non-masking number
  username        (some gateways, e.g. MiM SMS)
  method          GET | POST                    (default POST)
  body_format     form | json                   (default form)
  param_to / param_message / param_api_key / param_sender / param_username
                  the gateway's parameter names (form/query style)
  body_template   OPTIONAL JSON body with placeholders {to} {text} {sender}
                  {api_key} {username} {uid} — for nested JSON APIs (Infobip)
  auth_header     OPTIONAL "Header-Name: value with {api_key}"
  number_format   880 | +880 | 0               (how the gateway wants the number)
  success_json    OPTIONAL "dotted.path=value" checked in the JSON reply
  success_contains OPTIONAL substring that must appear in the reply
  balance_url     OPTIONAL balance-check URL (used by the honest connection test)
  test_phone      OPTIONAL number that receives ONE real test SMS on "Test"
  app_hash        OPTIONAL Android SMS-Retriever 11-char app hash appended to
                  the OTP text (future native autofill; harmless when blank)

SECURITY: the message text (which contains the OTP) is NEVER logged, and any
gateway reply echoed back in an error detail is scrubbed of digits runs that
could be the code. Network calls go through `_http()` so tests mock ONE
function.
"""
import json
import re
import secrets
import urllib.error
import urllib.parse
import urllib.request

# ------------------------------------------------------------------ presets
# Defaults per well-known gateway. These are the publicly documented shapes at
# the time of writing; the owner can override every field in Integrations if a
# provider changes its API. `custom` = fill everything yourself.
PRESETS = {
    "ssl_wireless": {
        "label": "SSL Wireless (ISMS)",
        "api_url": "https://smsplus.sslwireless.com/api/v3/send-sms",
        "method": "POST", "body_format": "json",
        "body_template": ('{"api_token": "{api_key}", "sid": "{sender}", '
                          '"msisdn": "{to}", "sms": "{text}", "csms_id": "{uid}"}'),
        "number_format": "880",
        "success_json": "status=SUCCESS",
    },
    "bulksmsbd": {
        "label": "BulkSMSBD",
        "api_url": "http://bulksmsbd.net/api/smsapi",
        "method": "POST", "body_format": "form",
        "param_api_key": "api_key", "param_to": "number",
        "param_message": "message", "param_sender": "senderid",
        "extra": {"type": "text"},
        "number_format": "880",
        "success_json": "response_code=202",
        "balance_url": "http://bulksmsbd.net/api/getBalanceApi?api_key={api_key}",
    },
    "alpha_sms": {
        "label": "Alpha SMS (sms.net.bd)",
        "api_url": "https://api.sms.net.bd/sendsms",
        "method": "POST", "body_format": "form",
        "param_api_key": "api_key", "param_to": "to",
        "param_message": "msg", "param_sender": "sender_id",
        "number_format": "880",
        "success_json": "error=0",
        "balance_url": "https://api.sms.net.bd/user/balance/?api_key={api_key}",
    },
    "mim_sms": {
        "label": "MiM SMS",
        "api_url": "https://api.mimsms.com/api/SmsSending/SMS",
        "method": "POST", "body_format": "json",
        "body_template": ('{"UserName": "{username}", "Apikey": "{api_key}", '
                          '"MobileNumber": "{to}", "CampaignId": "null", '
                          '"SenderName": "{sender}", "TransactionType": "T", '
                          '"Message": "{text}"}'),
        "number_format": "880",
        "success_json": "statusCode=200",
    },
    "infobip": {
        "label": "Infobip",
        "api_url": "https://YOUR-BASE.api.infobip.com/sms/2/text/advanced",
        "method": "POST", "body_format": "json",
        "body_template": ('{"messages": [{"destinations": [{"to": "{to}"}], '
                          '"from": "{sender}", "text": "{text}"}]}'),
        "auth_header": "Authorization: App {api_key}",
        "number_format": "880",
        "success_contains": "messageId",
    },
    "custom": {"label": "Other / custom HTTP gateway"},
}

_DEFAULTS = {
    "method": "POST", "body_format": "form",
    "param_to": "to", "param_message": "message",
    "param_api_key": "api_key", "param_sender": "sender_id",
    "param_username": "username",
    "number_format": "880",
}

TIMEOUT = 15


class SmsError(Exception):
    pass


def resolve_config(cfg):
    """Merge DEFAULTS < preset < owner-entered fields (non-blank only)."""
    cfg = dict(cfg or {})
    preset = PRESETS.get((cfg.get("provider") or "custom").strip().lower(),
                         PRESETS["custom"])
    out = dict(_DEFAULTS)
    out.update({k: v for k, v in preset.items() if k != "label"})
    for k, v in cfg.items():
        if v not in (None, ""):
            out[k] = v
    return out


def format_number(canon, fmt):
    """canon is +8801XXXXXXXXX. fmt: 880 | +880 | 0."""
    digits = canon.lstrip("+")            # 8801XXXXXXXXX
    if fmt == "+880":
        return "+" + digits
    if fmt == "0":
        return digits[2:]                 # 01XXXXXXXXX
    return digits


def _json_escape(v):
    return json.dumps(str(v), ensure_ascii=False)[1:-1]


_SECRET_KEYS = ("api_key", "api_token", "auth_token", "password", "app_password")


def _scrub(text, secret="", cfg=None):
    """Never echo an OTP / message / credential back into logs or details."""
    s = str(text or "")
    if secret:
        s = s.replace(secret, "******")
    for k in _SECRET_KEYS:
        v = str((cfg or {}).get(k) or "")
        if len(v) >= 4:
            s = s.replace(v, "****")
    return re.sub(r"\b\d{4,8}\b", "***", s)[:200]


def _json_path(body, path):
    cur = body
    for part in path.split("."):
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        elif isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def success(cfg, http_status, body_text):
    """Did the gateway accept the message? 2xx AND (success_json and/or
    success_contains when configured). With neither configured, 2xx counts."""
    if not (200 <= int(http_status) < 300):
        return False
    sj = (cfg.get("success_json") or "").strip()
    sc = (cfg.get("success_contains") or "").strip()
    if sj:
        path, _, want = sj.partition("=")
        try:
            body = json.loads(body_text or "")
        except ValueError:
            return False
        got = _json_path(body, path.strip())
        if got is None or str(got).strip().lower() != want.strip().lower():
            return False
    if sc and sc not in (body_text or ""):
        return False
    sr = (cfg.get("success_regex") or "").strip()
    if sr:
        try:
            if not re.search(sr, body_text or ""):
                return False
        except re.error:
            return False
    return True


def _http(method, url, data=None, headers=None):
    """The ONE network call (tests mock this). Returns (status, text)."""
    req = urllib.request.Request(url, data=data, headers=headers or {},
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read(64 * 1024).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        try:
            txt = e.read(8 * 1024).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            txt = ""
        return e.code, txt


def _fill(s, values, json_mode=False):
    out = str(s)
    for k, v in values.items():
        out = out.replace("{" + k + "}", _json_escape(v) if json_mode else str(v))
    return out


def _fill_url(s, values):
    out = str(s)
    for k, v in values.items():
        out = out.replace("{" + k + "}", urllib.parse.quote(str(v), safe=""))
    return out


def build_request(cfg, to_canon, text):
    """Pure: (method, url, body_bytes|None, headers). Exposed for tests."""
    c = resolve_config(cfg)
    url = (c.get("api_url") or "").strip()
    if not url.startswith(("http://", "https://")) or "YOUR-BASE" in url:
        raise SmsError("api_url missing or not a URL")
    if not (c.get("api_key") or "").strip():
        raise SmsError("api_key missing")
    values = {
        "to": format_number(to_canon, c.get("number_format", "880")),
        "text": text,
        "sender": c.get("sender_id", ""),
        "api_key": c.get("api_key", ""),
        "username": c.get("username", ""),
        "uid": secrets.token_hex(8),
    }
    method = (c.get("method") or "POST").upper()
    headers = {"User-Agent": "Assisto-SMS/1"}
    ah = (c.get("auth_header") or "").strip()
    if ah and ":" in ah:
        name, _, val = ah.partition(":")
        headers[name.strip()] = _fill(val.strip(), values)

    # smsotp: URL TEMPLATE — {to} {text} {sender} {api_key} {username} {uid}
    # placed straight in the URL (URL-encoded). Then no parameters are added.
    url_tmpl = any("{%s}" % k in url for k in values)
    if url_tmpl:
        url = _fill_url(url, values)

    tmpl = (c.get("body_template") or "").strip()
    if tmpl and not tmpl.startswith(("{", "[")):
        # form-style body template: "to={to}&msg={text}"
        body = _fill_url(tmpl, values)
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        return "POST" if method == "GET" else method, url, body.encode("utf-8"), headers
    if tmpl:
        body = _fill(tmpl, values, json_mode=True)
        json.loads(body)  # must be valid JSON after filling (raises ValueError)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        return "POST" if method == "GET" else method, url, body.encode("utf-8"), headers
    if url_tmpl:
        return method, url, (None if method == "GET" else b""), headers

    params = {}
    extra = c.get("extra") or {}
    if isinstance(extra, str):
        try:
            extra = json.loads(extra) if extra.strip() else {}
        except ValueError:
            extra = {}
    params.update({k: str(v) for k, v in (extra or {}).items()})
    params[c["param_api_key"]] = values["api_key"]
    params[c["param_to"]] = values["to"]
    params[c["param_message"]] = text
    if values["sender"]:
        params[c["param_sender"]] = values["sender"]
    if values["username"]:
        params[c["param_username"]] = values["username"]

    if method == "GET":
        sep = "&" if "?" in url else "?"
        return "GET", url + sep + urllib.parse.urlencode(params), None, headers
    if (c.get("body_format") or "form") == "json":
        headers["Content-Type"] = "application/json"
        return method, url, json.dumps(params, ensure_ascii=False).encode("utf-8"), headers
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    return method, url, urllib.parse.urlencode(params).encode("utf-8"), headers


class SendResult:
    """What one gateway call returned. `detail` is scrubbed (no OTP, no
    digit runs); the message text is never kept."""
    __slots__ = ("ok", "provider", "message_id", "detail", "http_status")

    def __init__(self, ok, provider, message_id="", detail="", http_status=0):
        self.ok = bool(ok)
        self.provider = provider
        self.message_id = str(message_id or "")[:80]
        self.detail = str(detail or "")[:200]
        self.http_status = int(http_status or 0)

    def __repr__(self):  # never includes the text
        return "SendResult(ok=%s, provider=%s, id=%s)" % (self.ok, self.provider,
                                                          self.message_id)


_ID_KEYS = ("message_id", "messageId", "request_id", "reference_id", "sid", "id")


def _guess_message_id(txt):
    """Best-effort provider message id from a JSON reply (common key names,
    one level of nesting / first list item)."""
    try:
        body = json.loads(txt or "")
    except ValueError:
        return ""
    stack = [body]
    for _ in range(4):
        nxt = []
        for node in stack:
            if isinstance(node, dict):
                for k in _ID_KEYS:
                    v = node.get(k)
                    if isinstance(v, (str, int)) and str(v):
                        return str(v)
                nxt.extend(v for v in node.values() if isinstance(v, (dict, list)))
            elif isinstance(node, list) and node:
                nxt.append(node[0])
        stack = nxt
    return ""


class HttpSmsAdapter:
    """The GENERIC gateway (integration slug "sms"): presets + URL template +
    success regex, so any HTTP GET/POST gateway works. Never raises, never
    logs `text`. `secret` (the OTP) is scrubbed from any detail."""
    slug = "sms"
    label = "Generic HTTP gateway"

    def __init__(self, cfg):
        self.cfg = resolve_config(cfg)

    def send_result(self, to_canon, text, secret=""):
        try:
            method, url, body, headers = build_request(self.cfg, to_canon, text)
        except (SmsError, ValueError) as e:
            return SendResult(False, self.slug, detail=f"config: {str(e)[:120]}")
        try:
            st, txt = _http(method, url, body, headers)
        except Exception as e:  # noqa: BLE001 — network down, DNS, TLS
            return SendResult(False, self.slug, detail=f"network: {type(e).__name__}")
        if success(self.cfg, st, txt):
            return SendResult(True, self.slug, _guess_message_id(txt),
                              f"HTTP {st} accepted", st)
        return SendResult(False, self.slug, detail=f"HTTP {st}: {_scrub(txt, secret, self.cfg)}",
                          http_status=st)

    def send(self, to_canon, text, secret=""):
        r = self.send_result(to_canon, text, secret=secret)
        return r.ok, r.detail

    def check(self, test_to=None):
        if test_to:
            return _test_send(self, test_to)
        return self._check()

    def _check(self):
        """Honest connection test (no fake 'working'):
          1) config must be complete;
          2) if balance_url → GET it, 2xx = credentials reach the gateway;
          3) else if test_phone → send ONE real test SMS and require the
             gateway's success check;
          4) else → not verifiable; say so."""
        c = self.cfg
        try:
            build_request(c, "+8801700000000", "test")
        except (SmsError, ValueError) as e:
            return False, f"config: {str(e)[:120]}"
        bu = (c.get("balance_url") or "").strip()
        if bu:
            url = _fill(bu, {"api_key": urllib.parse.quote(str(c.get("api_key", ""))),
                             "username": urllib.parse.quote(str(c.get("username", "")))})
            try:
                st, txt = _http("GET", url, None, {"User-Agent": "Assisto-SMS/1"})
            except Exception as e:  # noqa: BLE001
                return False, f"balance check network: {type(e).__name__}"
            if 200 <= st < 300 and not re.search(r"invalid|unauthori[sz]ed|error\"?\s*:\s*[1-9]",
                                                 txt or "", re.I):
                return True, f"✓ ব্যালান্স চেক সফল / balance check OK: {_scrub(txt, cfg=c)[:80]}"
            return False, f"balance check HTTP {st}: {_scrub(txt, cfg=c)}"
        tp = (c.get("test_phone") or "").strip()
        if tp:
            from .otp import normalize_bd_phone
            canon = normalize_bd_phone(tp)
            if not canon:
                return False, "test_phone is not a valid Bangladeshi mobile number"
            ok, detail = self.send(canon, "Assisto: SMS gateway test / এসএমএস গেটওয়ে পরীক্ষা")
            if ok:
                return True, "✓ টেস্ট SMS পাঠানো হয়েছে / test SMS accepted — check the phone"
            return False, detail
        return False, ("যাচাই করা যায়নি — balance_url অথবা test_phone দিন / "
                       "cannot verify — add a balance_url or a test_phone, then Test")


TEST_TEXT = "Assisto: SMS gateway test / এসএমএস গেটওয়ে পরীক্ষা"


def _test_send(ad, test_to):
    """"Send test SMS" to a number the owner typed: ONE real SMS; working only
    when the gateway's own success check passes."""
    from .otp import normalize_bd_phone
    canon = normalize_bd_phone(test_to)
    if not canon:
        return False, "test number is not a valid Bangladeshi mobile number"
    r = ad.send_result(canon, TEST_TEXT)
    if r.ok:
        return True, ("✓ টেস্ট SMS পাঠানো হয়েছে / test SMS accepted%s — check the phone"
                      % ((" (id %s)" % r.message_id[:24]) if r.message_id else ""))
    return False, r.detail


# ======================================================== dedicated adapters
# One class per gateway, built from its PUBLIC API documentation (cited on
# each class). Field names = the integration entry's field keys. Anything the
# docs leave open is marked "verify with your account manager" in
# owner_actions/SMS_EMAIL_SETUP_BN.md.

def _need(cfg, *keys):
    for k in keys:
        if not str(cfg.get(k) or "").strip():
            raise SmsError("%s missing" % k)


def _json(txt):
    try:
        return json.loads(txt or "")
    except ValueError:
        return None


class _Dedicated:
    slug = ""
    label = ""
    required = ()

    def __init__(self, cfg):
        self.cfg = {k: (v.strip() if isinstance(v, str) else v)
                    for k, v in dict(cfg or {}).items()}

    # subclasses: request(to, text) -> (method, url, body|None, headers)
    #             parse(status, txt) -> (ok, message_id)
    #             balance() -> (method, url, body, headers) | None
    def validate(self):
        _need(self.cfg, *self.required)

    def send_result(self, to_canon, text, secret=""):
        try:
            self.validate()
            method, url, body, headers = self.request(to_canon, text)
        except (SmsError, ValueError) as e:
            return SendResult(False, self.slug, detail=f"config: {str(e)[:120]}")
        try:
            st, txt = _http(method, url, body, headers)
        except Exception as e:  # noqa: BLE001
            return SendResult(False, self.slug, detail=f"network: {type(e).__name__}")
        try:
            ok, mid = self.parse(st, txt)
        except Exception:  # noqa: BLE001 — unexpected reply shape
            ok, mid = False, ""
        if ok:
            return SendResult(True, self.slug, mid, f"HTTP {st} accepted", st)
        return SendResult(False, self.slug, detail=f"HTTP {st}: {_scrub(txt, secret, self.cfg)}",
                          http_status=st)

    def send(self, to_canon, text, secret=""):
        r = self.send_result(to_canon, text, secret=secret)
        return r.ok, r.detail

    def balance(self):
        return None

    def balance_ok(self, st, txt):
        return 200 <= st < 300 and not re.search(
            r"invalid|unauthori[sz]ed|error\"?\s*:\s*[1-9]|FAILED", txt or "", re.I)

    def check(self, test_to=None):
        try:
            self.validate()
            self.request("+8801700000000", "test")
        except (SmsError, ValueError) as e:
            return False, f"config: {str(e)[:120]}"
        test_to = test_to or self.cfg.get("test_phone")
        if test_to:
            return _test_send(self, test_to)
        req = self.balance()
        if req is None:
            return False, ("যাচাই করা যায়নি — একটি টেস্ট নম্বর লিখে 'Send test SMS' চাপুন / "
                           "cannot verify — type a test number and press Send test SMS")
        try:
            st, txt = _http(*req)
        except Exception as e:  # noqa: BLE001
            return False, f"balance check network: {type(e).__name__}"
        if self.balance_ok(st, txt):
            return True, f"✓ ব্যালান্স চেক সফল / balance check OK: {_scrub(txt, cfg=self.cfg)[:80]}"
        return False, f"balance check HTTP {st}: {_scrub(txt, cfg=self.cfg)}"


class SslWirelessAdapter(_Dedicated):
    """SSL Wireless ISMS Plus API v3 — POST {api_base}/api/v3/send-sms, JSON
    {api_token, sid, msisdn, sms, csms_id}. Reply: {"status":"SUCCESS",
    "smsinfo":[{"sms_status":"SUCCESS","reference_id":...}]}.
    Doc: SSL Wireless "ISMS API v3" PDF (smsplus.sslwireless.com, given with
    the account). csms_id = our unique id per message (max 20 chars)."""
    slug = "sms_ssl_wireless"
    label = "SSL Wireless (ISMS)"
    required = ("api_token", "sid")
    BASE = "https://smsplus.sslwireless.com"

    def _base(self):
        return (self.cfg.get("api_base") or self.BASE).rstrip("/")

    def request(self, to, text):
        body = {"api_token": self.cfg["api_token"], "sid": self.cfg["sid"],
                "msisdn": format_number(to, "880"), "sms": text,
                "csms_id": ("as" + secrets.token_hex(9))[:20]}
        return ("POST", self._base() + "/api/v3/send-sms",
                json.dumps(body, ensure_ascii=False).encode("utf-8"),
                {"Content-Type": "application/json", "Accept": "application/json",
                 "User-Agent": "Assisto-SMS/1"})

    def parse(self, st, txt):
        j = _json(txt) or {}
        info = (j.get("smsinfo") or [{}])
        info = info[0] if isinstance(info, list) and info else {}
        ok = (200 <= st < 300 and str(j.get("status", "")).upper() == "SUCCESS"
              and str(info.get("sms_status", "SUCCESS")).upper() == "SUCCESS")
        return ok, str(info.get("reference_id") or info.get("csms_id") or "")

    def balance(self):
        # verify with your account manager: balance endpoint of ISMS v3
        body = json.dumps({"api_token": self.cfg["api_token"], "sid": self.cfg["sid"]})
        return ("POST", self._base() + "/api/v3/balance", body.encode("utf-8"),
                {"Content-Type": "application/json", "User-Agent": "Assisto-SMS/1"})

    def balance_ok(self, st, txt):
        j = _json(txt) or {}
        return 200 <= st < 300 and str(j.get("status", "")).upper() == "SUCCESS"


class BulkSmsBdAdapter(_Dedicated):
    """BulkSMSBD — POST {api_url} form api_key, type=text, number, senderid,
    message. Reply {"response_code":202,"message_id":..,"success_message":..}.
    Balance GET /api/getBalanceApi?api_key=. Doc: bulksmsbd.net → API
    (dashboard "Developer API" page)."""
    slug = "sms_bulksmsbd"
    label = "BulkSMSBD"
    required = ("api_key", "senderid")
    URL = "https://bulksmsbd.net/api/smsapi"

    def request(self, to, text):
        params = {"api_key": self.cfg["api_key"], "type": "text",
                  "number": format_number(to, "880"),
                  "senderid": self.cfg["senderid"], "message": text}
        return ("POST", self.cfg.get("api_url") or self.URL,
                urllib.parse.urlencode(params).encode("utf-8"),
                {"Content-Type": "application/x-www-form-urlencoded",
                 "User-Agent": "Assisto-SMS/1"})

    def parse(self, st, txt):
        j = _json(txt) or {}
        return (200 <= st < 300 and str(j.get("response_code")) == "202",
                str(j.get("message_id") or ""))

    def balance(self):
        base = (self.cfg.get("api_url") or self.URL).rsplit("/", 1)[0]
        return ("GET", base + "/getBalanceApi?" + urllib.parse.urlencode(
            {"api_key": self.cfg["api_key"]}), None, {"User-Agent": "Assisto-SMS/1"})


class AlphaSmsAdapter(_Dedicated):
    """Alpha SMS / sms.net.bd — POST https://api.sms.net.bd/sendsms form
    api_key, msg, to, sender_id (optional, approved only). Reply {"error":0,
    "msg":"Request successfully submitted","data":{"request_id":..}}.
    Balance GET /user/balance/?api_key=. Doc: https://www.sms.net.bd/api"""
    slug = "sms_alpha"
    label = "Alpha SMS (sms.net.bd)"
    required = ("api_key",)
    BASE = "https://api.sms.net.bd"

    def request(self, to, text):
        params = {"api_key": self.cfg["api_key"], "msg": text,
                  "to": format_number(to, "880")}
        if self.cfg.get("sender_id"):
            params["sender_id"] = self.cfg["sender_id"]
        return ("POST", self.BASE + "/sendsms",
                urllib.parse.urlencode(params).encode("utf-8"),
                {"Content-Type": "application/x-www-form-urlencoded",
                 "User-Agent": "Assisto-SMS/1"})

    def parse(self, st, txt):
        j = _json(txt) or {}
        data = j.get("data") if isinstance(j.get("data"), dict) else {}
        return (200 <= st < 300 and str(j.get("error")) == "0",
                str(data.get("request_id") or ""))

    def balance(self):
        return ("GET", self.BASE + "/user/balance/?" + urllib.parse.urlencode(
            {"api_key": self.cfg["api_key"]}), None, {"User-Agent": "Assisto-SMS/1"})

    def balance_ok(self, st, txt):
        j = _json(txt) or {}
        return 200 <= st < 300 and str(j.get("error")) == "0"


class InfobipAdapter(_Dedicated):
    """Infobip — POST {base_url}/sms/2/text/advanced, header
    "Authorization: App {api_key}", JSON {"messages":[{"destinations":[{"to":
    "8801.."}],"from":sender,"text":..}]}. Reply messages[0].messageId +
    status.groupName (PENDING/DELIVERED = accepted; REJECTED/UNDELIVERABLE =
    failed). Balance GET {base_url}/account/1/balance.
    Doc: https://www.infobip.com/docs/api/channels/sms/sms-messaging/outbound-sms/send-sms-message"""
    slug = "sms_infobip"
    label = "Infobip"
    required = ("base_url", "api_key", "sender")

    def _base(self):
        b = self.cfg["base_url"].rstrip("/")
        if not b.startswith("http"):
            b = "https://" + b
        if not b.startswith("https://"):
            raise SmsError("base_url must be https")
        return b

    def _h(self):
        return {"Authorization": "App " + self.cfg["api_key"],
                "Content-Type": "application/json", "Accept": "application/json",
                "User-Agent": "Assisto-SMS/1"}

    def request(self, to, text):
        body = {"messages": [{"destinations": [{"to": format_number(to, "880")}],
                              "from": self.cfg["sender"], "text": text}]}
        return ("POST", self._base() + "/sms/2/text/advanced",
                json.dumps(body, ensure_ascii=False).encode("utf-8"), self._h())

    def parse(self, st, txt):
        j = _json(txt) or {}
        m = (j.get("messages") or [{}])[0]
        group = str(((m.get("status") or {}).get("groupName") or "")).upper()
        return (200 <= st < 300 and bool(m.get("messageId"))
                and group in ("PENDING", "DELIVERED", ""), str(m.get("messageId") or ""))

    def balance(self):
        h = dict(self._h())
        h.pop("Content-Type", None)
        return ("GET", self._base() + "/account/1/balance", None, h)


class TwilioAdapter(_Dedicated):
    """Twilio (international fallback) — POST
    https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Messages.json,
    HTTP Basic auth account_sid:auth_token, form To (+880…), From, Body.
    Reply 201 {"sid":"SM…","status":"queued","num_segments":"1"}.
    Check: GET Accounts/{account_sid}.json.
    Doc: https://www.twilio.com/docs/messaging/api/message-resource#create-a-message-resource"""
    slug = "sms_twilio"
    label = "Twilio"
    required = ("account_sid", "auth_token", "from_number")
    BASE = "https://api.twilio.com/2010-04-01/Accounts/"

    def _h(self):
        import base64
        tok = base64.b64encode(("%s:%s" % (self.cfg["account_sid"],
                                           self.cfg["auth_token"])).encode()).decode()
        return {"Authorization": "Basic " + tok, "User-Agent": "Assisto-SMS/1"}

    def request(self, to, text):
        sid = urllib.parse.quote(self.cfg["account_sid"], safe="")
        frm = self.cfg["from_number"]
        params = {"To": format_number(to, "+880"), "Body": text}
        if frm.startswith("MG"):
            params["MessagingServiceSid"] = frm
        else:
            params["From"] = frm
        h = self._h()
        h["Content-Type"] = "application/x-www-form-urlencoded"
        return ("POST", self.BASE + sid + "/Messages.json",
                urllib.parse.urlencode(params).encode("utf-8"), h)

    def parse(self, st, txt):
        j = _json(txt) or {}
        sid = str(j.get("sid") or "")
        return (200 <= st < 300 and sid.startswith(("SM", "MM"))
                and str(j.get("status", "")) not in ("failed", "undelivered"), sid)

    def balance(self):
        sid = urllib.parse.quote(self.cfg["account_sid"], safe="")
        return ("GET", self.BASE + sid + ".json", None, self._h())

    def balance_ok(self, st, txt):
        return 200 <= st < 300 and '"sid"' in (txt or "")


# Order = auto-pick order when the owner names no primary.
GATEWAYS = {
    "sms_ssl_wireless": SslWirelessAdapter,
    "sms_bulksmsbd": BulkSmsBdAdapter,
    "sms_alpha": AlphaSmsAdapter,
    "sms_infobip": InfobipAdapter,
    "sms_twilio": TwilioAdapter,
    "sms": HttpSmsAdapter,            # generic HTTP GET/POST (any BD gateway)
}


def make(slug, cfg):
    cls = GATEWAYS.get(slug)
    if cls is None:
        raise SmsError("unknown gateway")
    ad = cls(cfg)
    ad.slug = slug
    return ad


def routing():
    """(primary, secondary) slugs from Owner Admin → Pricing → sms."""
    try:
        from . import billing
        from .logic import pricing as P
        c = P.sms_cfg(billing.get_config().data)
        return c.get("primary", ""), c.get("secondary", "")
    except Exception:  # noqa: BLE001
        return "", ""


def chain():
    """CONNECTED gateways in failover order: [primary] or [primary, secondary].
    Only entries whose honest Test passed (status 'working') take part.
    Primary = the owner's choice when connected, else the first connected in
    GATEWAYS order; secondary only when the owner named one (and it works)."""
    from . import integrations
    from .models import Integration
    working = set(Integration.objects.filter(slug__in=list(GATEWAYS), status="working")
                  .values_list("slug", flat=True))
    if not working:
        return []
    want_p, want_s = routing()
    primary = want_p if want_p in working else next(s for s in GATEWAYS if s in working)
    out = [make(primary, integrations.get(primary))]
    if want_s and want_s in working and want_s != primary:
        out.append(make(want_s, integrations.get(want_s)))
    return out


def ready():
    """True when at least one SMS gateway is CONNECTED."""
    try:
        from .models import Integration
        return Integration.objects.filter(slug__in=list(GATEWAYS),
                                          status="working").exists()
    except Exception:  # noqa: BLE001
        return False


def active():
    """The adapters to send through, in failover order: chain(), or — when
    that is empty — whatever adapter() yields (tests patch adapter() with a
    fake; in production adapter() is None exactly when chain() is empty)."""
    try:
        ads = chain()
    except Exception:  # noqa: BLE001
        ads = []
    if ads:
        return ads
    ad = adapter()
    if ad is None:
        return []
    return list(ad.ads) if isinstance(ad, ChainAdapter) else [ad]


def _result_of(ad, to_canon, text, secret):
    if hasattr(ad, "send_result"):
        return ad.send_result(to_canon, text, secret=secret)
    ok, detail = ad.send(to_canon, text)          # minimal legacy adapter
    return SendResult(ok, getattr(ad, "slug", "") or "adapter", detail=_scrub(detail, secret))


def send_with_failover(ads, to_canon, text, secret=""):
    """Try each adapter in order; stop at the first success.
    Returns (SendResult, adapter_used | None, failed_over: bool)."""
    last = SendResult(False, "", detail="no gateway connected")
    for i, ad in enumerate(ads):
        r = _result_of(ad, to_canon, text, secret)
        if r.ok:
            return r, ad, i > 0
        last = r
    return last, None, len(ads) > 1


class ChainAdapter:
    """Legacy facade over chain() for older callers (booking reminders,
    retention, payments): .send(to, text, secret) -> (ok, detail), with
    failover. `.cfg` is the primary's config (app_hash etc.)."""

    def __init__(self, ads):
        self.ads = ads
        self.cfg = getattr(ads[0], "cfg", {}) if ads else {}

    def send_result(self, to_canon, text, secret=""):
        return send_with_failover(self.ads, to_canon, text, secret)[0]


    def send(self, to_canon, text, secret=""):
        r = self.send_result(to_canon, text, secret)
        return r.ok, r.detail


def adapter():
    """The CONNECTED gateway chain as one adapter, or None when no SMS gateway
    has passed its Test."""
    try:
        ads = chain()
    except Exception:  # noqa: BLE001
        return None
    return ChainAdapter(ads) if ads else None
