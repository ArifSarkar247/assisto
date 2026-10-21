"""
SMS gateway adapter (o1-otp) — provider-agnostic, config-driven, key-gated.

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


def _scrub(text, secret=""):
    """Never echo an OTP / message back into logs or details."""
    s = str(text or "")
    if secret:
        s = s.replace(secret, "******")
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

    tmpl = (c.get("body_template") or "").strip()
    if tmpl:
        body = _fill(tmpl, values, json_mode=True)
        json.loads(body)  # must be valid JSON after filling (raises ValueError)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json"
        return "POST" if method == "GET" else method, url, body.encode("utf-8"), headers

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


class HttpSmsAdapter:
    """send(to_canon, text, secret='') -> (ok, detail). Never raises, never
    logs `text`. `secret` (the OTP) is scrubbed from any detail."""

    def __init__(self, cfg):
        self.cfg = resolve_config(cfg)

    def send(self, to_canon, text, secret=""):
        try:
            method, url, body, headers = build_request(self.cfg, to_canon, text)
        except (SmsError, ValueError) as e:
            return False, f"config: {str(e)[:120]}"
        try:
            st, txt = _http(method, url, body, headers)
        except Exception as e:  # noqa: BLE001 — network down, DNS, TLS
            return False, f"network: {type(e).__name__}"
        if success(self.cfg, st, txt):
            return True, f"HTTP {st} accepted"
        return False, f"HTTP {st}: {_scrub(txt, secret)}"

    def check(self):
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
                return True, f"✓ ব্যালান্স চেক সফল / balance check OK: {_scrub(txt)[:80]}"
            return False, f"balance check HTTP {st}: {_scrub(txt)}"
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


def adapter():
    """The configured adapter, or None when no SMS gateway key is saved."""
    from . import integrations
    cfg = integrations.get("sms")
    if not cfg or not (cfg.get("api_key") or "").strip():
        return None
    return HttpSmsAdapter(cfg)
