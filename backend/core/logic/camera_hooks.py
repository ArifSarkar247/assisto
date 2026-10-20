"""
camera_hooks.py — PURE parsers that turn an IP camera's own event push into the
neutral camera events shop_guard understands. NO Django, NO DB, NO network.

Supported pushes (the camera POSTs to /api/v1/shop/hook/<vendor>/<camera_token>):
  * Hikvision ISAPI "HTTP Listening" / Alarm Server: an `EventNotificationAlert`
    XML body, or multipart/form-data carrying that XML plus a JPEG of the moment.
  * Dahua event push: JSON ({"Code": "CrossLineDetection", "Action": "Start", ...},
    optionally wrapped as {"Events": [...]}) or the eventManager text form
    ("Code=CrossLineDetection;action=Start;index=0"), optionally multipart + JPEG.

We only act on the START of an event (Hikvision eventState=active, Dahua
Action=Start). Heartbeats / "inactive" / "Stop" are acknowledged and dropped.

map_event() turns a vendor event into (shop_guard type, signals) or None.
Wording downstream is always "please check camera X", never "theft".
"""
import json
import re
import xml.etree.ElementTree as ET
from datetime import datetime, time as dtime
from email.parser import BytesParser
from email.policy import HTTP

# vendor event code (lower-cased) -> family
_INTRUSION = {
    # Hikvision
    "linedetection", "fielddetection", "regionentrance",
    # Dahua
    "crosslinedetection", "crossregiondetection", "intrusion",
}
_MOTION = {"vmd", "videomotion", "motiondetection"}

MAX_IMAGE_BYTES = 2 * 1024 * 1024   # refuse anything bigger than a still photo


def _strip_ns(tag):
    return tag.rsplit("}", 1)[-1]


def _xml_text(root, name):
    for el in root.iter():
        if _strip_ns(el.tag).lower() == name.lower():
            return (el.text or "").strip()
    return ""


def _parse_hik_xml(raw):
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        return None
    if _strip_ns(root.tag) != "EventNotificationAlert":
        return None
    return {
        "event": _xml_text(root, "eventType").lower(),
        "active": _xml_text(root, "eventState").lower() == "active",
        "at": _xml_text(root, "dateTime") or None,
        "channel": _xml_text(root, "channelID") or _xml_text(root, "dynChannelID"),
    }


def _multipart_parts(content_type, body):
    """Yield (content_type, payload_bytes) for each part of a multipart body."""
    msg = BytesParser(policy=HTTP).parsebytes(
        b"Content-Type: " + content_type.encode("latin-1") + b"\r\n\r\n" + body)
    if not msg.is_multipart():
        return
    for part in msg.iter_parts():
        yield (part.get_content_type(), part.get_payload(decode=True) or b"")


def _first_image(content_type, body):
    for ctype, payload in _multipart_parts(content_type, body):
        if ctype in ("image/jpeg", "image/jpg") and 0 < len(payload) <= MAX_IMAGE_BYTES:
            return payload
    return None


def parse_hikvision(content_type, body):
    """-> list of {event, active, at, channel, image}. Empty when unparseable."""
    content_type = content_type or ""
    xml_raw, image = None, None
    if content_type.startswith("multipart/"):
        for ctype, payload in _multipart_parts(content_type, body):
            if ctype in ("application/xml", "text/xml") or payload.lstrip()[:1] == b"<":
                xml_raw = xml_raw or payload
        image = _first_image(content_type, body)
    else:
        xml_raw = body
    ev = _parse_hik_xml(xml_raw) if xml_raw else None
    if ev is None:
        return []
    ev["image"] = image
    return [ev]


_DAHUA_KV = re.compile(r"(\w+)=([^;\r\n]*)")


def _dahua_from_obj(obj):
    code = str(obj.get("Code") or obj.get("code") or "").lower()
    action = str(obj.get("Action") or obj.get("action") or "").lower()
    data = obj.get("Data") if isinstance(obj.get("Data"), dict) else {}
    return {
        "event": code,
        "active": action in ("start", "pulse"),
        "at": data.get("LocaleTime") or data.get("UTC") or None,
        "channel": str(obj.get("Index", obj.get("index", ""))),
    }


def parse_dahua(content_type, body):
    """-> list of {event, active, at, channel, image}. Empty when unparseable."""
    content_type = content_type or ""
    image = None
    texts = []
    if content_type.startswith("multipart/"):
        for ctype, payload in _multipart_parts(content_type, body):
            if not ctype.startswith("image/"):
                texts.append(payload)
        image = _first_image(content_type, body)
    else:
        texts.append(body)

    out = []
    for raw in texts:
        txt = raw.decode("utf-8", "replace").strip()
        if not txt:
            continue
        if txt[:1] in "{[":
            try:
                obj = json.loads(txt)
            except ValueError:
                continue
            items = obj.get("Events") if isinstance(obj, dict) and "Events" in obj else obj
            for it in (items if isinstance(items, list) else [items]):
                if isinstance(it, dict):
                    out.append(_dahua_from_obj(it))
        else:
            for line in txt.splitlines():
                kv = {k.lower(): v.strip() for k, v in _DAHUA_KV.findall(line)}
                if kv.get("code"):
                    out.append(_dahua_from_obj(kv))
    for ev in out:
        ev["image"] = image
    return out


PARSERS = {"hikvision": parse_hikvision, "dahua": parse_dahua}


def _parse_hhmm(v):
    try:
        h, m = str(v).split(":")
        return dtime(int(h), int(m))
    except (ValueError, TypeError):
        return None


def is_after_hours(hours, local_now):
    """hours = {"open": "09:00", "close": "22:00"} (local time). Handles
    overnight shops (close < open). No hours configured → never after-hours."""
    if not isinstance(hours, dict):
        return False
    o, c = _parse_hhmm(hours.get("open")), _parse_hhmm(hours.get("close"))
    if o is None or c is None or o == c:
        return False
    t = local_now.time() if isinstance(local_now, datetime) else local_now
    if o < c:
        return not (o <= t < c)
    return c <= t < o        # overnight: closed between close and open


def map_event(ev, zone_config, local_now):
    """Vendor event -> (shop_guard type, signals) or None (acknowledge + drop).

    zone_config (the camera's): {"hours": {"open","close"},
    "restricted_zone": bool (default True — the owner drew the camera's rule
    around a staff-only area: behind the counter, stock room, back door)}."""
    if not ev.get("active"):
        return None
    code = ev.get("event") or ""
    zc = zone_config if isinstance(zone_config, dict) else {}
    after = is_after_hours(zc.get("hours"), local_now)
    base = {"camera_rule": code, "source": "camera_webhook"}
    if code in _INTRUSION:
        if after:
            return ("after_hours", dict(base, after_hours=True))
        if zc.get("restricted_zone", True):
            return ("motion", dict(base, zone_breach=True))
        return ("motion", base)          # logged as lone motion, no alert
    if code in _MOTION:
        return ("motion", dict(base, after_hours=after) if after else base)
    return None
