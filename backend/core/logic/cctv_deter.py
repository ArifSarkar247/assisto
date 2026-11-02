"""
cctv_deter.py — CCTV ESCALATION PLUS (owner CCTV order 3 Nov, section C;
audit rows C3-C6). PURE rules + thin vendor calls (the vendor client is passed
in, tests inject fake HTTP built from the official docs). No DB here.

  C3  ALARM CALL — after the owner's chain of people (each `escalate_min`
      unopened), the server rings the chain again as an Assisto CALL: the
      SAME call push the My Circle calls use (native full-screen CallStyle
      ring, Telecom, 45 s), carrying the alert's event id + snapshot link so
      the phone opens the alert's full-screen alarm page (with the snapshot)
      instead of a voice line. Bounded: at most CALL_ROUNDS passes over the
      chain and MAX_RINGS rings per alert; stops the moment anyone opens it.
  C4  999 CARD — the phone opens the DIALER with 999 (the person presses
      call; never automatic) and a ready share card: place + address, time,
      camera, the snapshot. Assisto never calls the police itself.
  C5  DETERRENCE — siren / white light / recorded Bangla warning, ONLY over
      official vendor APIs:
        * Imou Open Platform: siren = sirenStart / sirenStop (the vendor's own
          Py-Imou-Open-Api, const API_ENDPOINT_SIREN_START), older firmware
          falls back to setDeviceCameraStatus enableType "siren" (what
          cctvx already used); white light = setDeviceCameraStatus
          enableType "whiteLight" (ability WhiteLight / ChnWhiteLight).
          No documented HTTP voice-broadcast call -> voice "not on this
          camera".
        * EZVIZ Open Platform: voice = /api/lapp/voice/upload (file, once per
          clip) + /api/lapp/voice/send (deviceSerial, channelNo, fileUrl);
          device must support talk (/api/lapp/device/capacity support_talk);
          error 20015 = not supported. No on-demand siren / light call.
        * Hikvision: siren via the Shop Box (cctvx); light / voice not yet.
      Per-camera capability table with an honest "not on this camera" row.
      Confirm-before-sound on the phone; server cooldown + daily cap.
  C6  TWO-WAY TALK — Imou and EZVIZ offer talk only inside their NATIVE
      SDKs (LCOpenSDK / EZOpenSDK), not over HTTP; the phone-as-camera live
      session is one-way video today. So the table says honestly "not yet"
      with the way that works today (the vendor's own app).
"""
import re

from . import cctv_extras as CX

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ================================================================ C3 alarm call
CALL_ROUNDS = 2          # passes over the chain as calls (never forever)
MAX_RINGS = 6            # hard ceiling per alert, whatever the chain length
CALL_PREFIX = "cctv"


def alarm_call_id(event_id, uid, n):
    """A call id that can never collide with a CallRecord id (those are
    integers): "cctv-<event>-<uid>-<n>"."""
    return "%s-%d-%d-%d" % (CALL_PREFIX, int(event_id), int(uid), int(n))


def is_alarm_call_id(call_id):
    return bool(re.match(r"^%s-\d+-\d+-\d+$" % CALL_PREFIX, str(call_id or "")))


def call_order(chain, rounds=CALL_ROUNDS, max_rings=MAX_RINGS):
    """The ring order for the call phase: the chain again, `rounds` times,
    capped at max_rings. [] for an empty chain."""
    out = []
    for _ in range(max(0, int(rounds))):
        for u in chain:
            if len(out) >= max_rings:
                return out
            out.append(int(u))
    return out


def call_caller_name(lang, site_name, camera_name):
    place = site_name or pick(lang, "আপনার জায়গা", "your place")
    cam = camera_name or pick(lang, "ক্যামেরা", "camera")
    return pick(lang, "Assisto সতর্কতা: %s — %s" % (place, cam),
                "Assisto alert: %s — %s" % (place, cam))[:80]


def call_body(lang, owner_name):
    who = owner_name or pick(lang, "মালিক", "the owner")
    return pick(lang, "%s এখনো সতর্কতাটি দেখেননি — ধরে ছবি দেখুন" % who,
                "%s has not seen this alert — answer to see the photo" % who)


# ================================================================ C4 999 card
ADDRESS_MAX = 200


def clean_address(v):
    s = re.sub(r"\s+", " ", str(v or "")).strip()
    return s[:ADDRESS_MAX]


def police_card(lang, f):
    """The share text for the police / 999 call taker. FACTS only: place,
    address, time, camera, alert number, snapshot note. Never names or
    blames anyone. f = {site, address, when, camera, kind, event_id,
    has_photo}."""
    addr = f.get("address") or pick(lang, "[ঠিকানা লিখুন]", "[write the address]")
    site = f.get("site") or ""
    when = f.get("when") or ""
    cam = f.get("camera") or ""
    kind = f.get("kind") or ""
    eid = str(f.get("event_id") or "")
    photo = f.get("has_photo")
    if lang == "en":
        lines = ["CCTV alert — please help",
                 "Place: %s" % site if site else "",
                 "Address: %s" % addr,
                 "Time: %s" % when,
                 "Camera: %s" % cam if cam else "",
                 "What the camera saw: %s" % kind if kind else "",
                 "Alert no.: %s (Assisto)" % eid,
                 "Photo from the camera attached." if photo else "",
                 "Sent by the owner / family from the Assisto app."]
    else:
        lines = ["সিসিটিভি সতর্কতা — সাহায্য দরকার",
                 "জায়গা: %s" % site if site else "",
                 "ঠিকানা: %s" % addr,
                 "সময়: %s" % str(when).translate(_BN),
                 "ক্যামেরা: %s" % cam if cam else "",
                 "ক্যামেরা যা দেখেছে: %s" % kind if kind else "",
                 "সতর্কতা নং: %s (Assisto)" % eid.translate(_BN),
                 "ক্যামেরার ছবি সংযুক্ত।" if photo else "",
                 "Assisto অ্যাপ থেকে মালিক / পরিবার পাঠিয়েছেন।"]
    return "\n".join(x for x in lines if x)


NO_AUTO_POLICE = (
    "Assisto নিজে পুলিশকে কল করে না। ৯৯৯ চাপলে আপনার ফোনের ডায়ালার খুলবে — "
    "কল বাটন আপনি চাপবেন। তারপর এই কার্ডটি পাঠাতে পারেন।",
    "Assisto does not call the police for you. 999 opens your phone's "
    "dialer — you press call. Then you can send this card.")


# ================================================================ C5/C6 table
FEATURES = ("siren", "light", "voice", "talk")
DETER_SECONDS = {"light": (10, 120, 30), "siren": CX.SIREN_SECONDS + (CX.SIREN_DEFAULT_S,)}
COOLDOWN_S = 20          # one deterrent per camera per 20 s (all kinds)

REASONS = {
    "no": ("এই ক্যামেরায় নেই", "Not on this camera"),
    "imou_not_linked": CX.SIREN_REASONS["imou_not_linked"],
    "ezviz_not_linked": ("এই EZVIZ ক্যামেরা এখনো EZVIZ ক্লাউডে যুক্ত নয়।",
                         "This EZVIZ camera is not linked to the EZVIZ cloud yet."),
    "learned_no": ("এই ক্যামেরা আগের চেষ্টায় জানিয়েছে এটি নেই — এই ক্যামেরায় নেই।",
                   "This camera answered on an earlier try that it has no such "
                   "feature — not on this camera."),
    "light_no_api": ("এই ব্র্যান্ডে দূর থেকে আলো জ্বালানোর অফিসিয়াল উপায় নেই — এই ক্যামেরায় নেই।",
                     "This brand has no official way to switch the light on remotely "
                     "— not on this camera."),
    "voice_no_api": ("এই ব্র্যান্ডের খোলা প্ল্যাটফর্মে ক্যামেরার স্পিকারে বার্তা বাজানোর "
                     "অফিসিয়াল উপায় নেই — এই ক্যামেরায় নেই।",
                     "This brand's open platform has no official way to play a "
                     "message on the camera's speaker — not on this camera."),
    "voice_no_speaker": ("এই ক্যামেরায় স্পিকার / কথা বলার সুবিধা নেই — এই ক্যামেরায় নেই।",
                         "This camera has no speaker / talk support — not on this camera."),
    "talk_sdk": ("দুই দিকে কথা Imou / EZVIZ শুধু তাদের নিজস্ব অ্যাপের ভেতরের SDK-তে দেয় — "
                 "Assisto-তে এখনো নেই। এখন ক্যামেরার নিজের অ্যাপ থেকে কথা বলুন।",
                 "Imou / EZVIZ give two-way talk only inside their own app SDK — "
                 "not in Assisto yet. Use the camera's own app to talk for now."),
    "talk_phone": ("ফোন-ক্যামেরার লাইভ এখন এক দিকে (শুধু ছবি) — কথা বলা এখনো নেই।",
                   "The phone camera's live view is one-way (picture only) for now "
                   "— no talk yet."),
    "hik_light_voice": ("Hikvision-এ আলো / বার্তা এখনো যুক্ত হয়নি — শুধু সাইরেন (Shop Box দিয়ে)।",
                        "Hikvision light / message is not added yet — only the siren "
                        "(through the Shop Box)."),
}


def _learned_no(compat, feature):
    return (compat or {}).get("deter_no", {}).get(feature) is True


def capability(vendor, vendor_ref, gateway, has_host, compat, feature):
    """(route or None, reason_code). route: imou_cloud | ezviz_cloud |
    hik_lan. reason_code explains a None honestly (REASONS / SIREN_REASONS)."""
    compat = compat or {}
    if feature == "siren":
        route, why = CX.siren_route(vendor, vendor_ref, gateway, has_host)
        if route and _learned_no(compat, "siren"):
            return None, "learned_no"
        return route, why
    if feature == "light":
        if vendor == "imou":
            if not vendor_ref:
                return None, "imou_not_linked"
            abil = compat.get("abilities")
            if isinstance(abil, list) and not (
                    "WhiteLight" in abil or "ChnWhiteLight" in abil):
                return None, "no"
            if _learned_no(compat, "light"):
                return None, "learned_no"
            return "imou_cloud", ""
        if vendor == "hikvision":
            return None, "hik_light_voice"
        return None, "light_no_api"
    if feature == "voice":
        if vendor == "ezviz":
            if not vendor_ref:
                return None, "ezviz_not_linked"
            st = compat.get("support_talk")
            if st is not None and str(st) not in ("1", "3"):
                return None, "voice_no_speaker"
            if _learned_no(compat, "voice"):
                return None, "learned_no"
            return "ezviz_cloud", ""
        if vendor == "hikvision":
            return None, "hik_light_voice"
        return None, "voice_no_api"
    if feature == "talk":
        if vendor == "phone":
            return None, "talk_phone"
        return None, "talk_sdk"
    return None, "no"


def reason_text(code, lang):
    pair = REASONS.get(code) or CX.SIREN_REASONS.get(code) or REASONS["no"]
    return pick(lang, pair[0], pair[1])


def capability_table(vendor, vendor_ref, gateway, has_host, compat, lang="bn"):
    """[{feature, supported, route, reason, text}] — the per-camera table the
    phone shows ("এই ক্যামেরায় নেই" honestly)."""
    out = []
    for f in FEATURES:
        route, why = capability(vendor, vendor_ref, gateway, has_host, compat, f)
        out.append({"feature": f, "supported": route is not None, "route": route,
                    "reason": why or None,
                    "text": None if route else reason_text(why, lang)})
    return out


def learn_no(compat, feature):
    """compat after a vendor answered 'not supported' for `feature`."""
    c = dict(compat or {})
    d = dict(c.get("deter_no") or {})
    d[feature] = True
    c["deter_no"] = d
    return c


# Vendor codes meaning "this device has no such ability" (not offline).
IMOU_NOT_SUPPORTED = ("DV1001", "DV1002", "DV1006", "OP1009", "DV1036")
EZVIZ_NOT_SUPPORTED = ("20015", "60020")


def clamp_seconds(feature, v):
    lo, hi, default = DETER_SECONDS.get(feature, (5, 30, 15))
    try:
        v = int(v)
    except (TypeError, ValueError):
        v = default
    return max(lo, min(hi, v))


# ================================================================ warning clips
# The owner records ONE short warning in their own voice (record package,
# WAV 16 kHz mono) — read from one of these lines. Stored once per site; the
# vendor upload happens once per clip (cached url).
WARN_LINES_BN = (
    "সতর্কতা! এই জায়গা ক্যামেরায় রেকর্ড হচ্ছে। মালিককে জানানো হয়েছে। এখনই চলে যান।",
    "আপনাকে ক্যামেরায় দেখা যাচ্ছে। বাড়ির লোক ও প্রতিবেশীদের জানানো হয়েছে।",
    "দোকান বন্ধ। ভেতরে ঢোকা নিষেধ। ক্যামেরা চালু আছে।",
)
WARN_MAX_BYTES = 900 * 1024      # ~28 s of 16 kHz mono 16-bit WAV
WARN_MAX_S = 20


def wav_seconds(raw):
    """Duration of a PCM WAV (bytes), or None when it is not a WAV we accept
    (RIFF/WAVE, PCM, mono/stereo, 8-48 kHz)."""
    if not isinstance(raw, (bytes, bytearray)) or len(raw) < 44:
        return None
    if raw[0:4] != b"RIFF" or raw[8:12] != b"WAVE":
        return None
    i = 12
    fmt = None
    while i + 8 <= len(raw):
        cid = raw[i:i + 4]
        size = int.from_bytes(raw[i + 4:i + 8], "little")
        body = raw[i + 8:i + 8 + size]
        if cid == b"fmt " and len(body) >= 16:
            fmt = {"audio": int.from_bytes(body[0:2], "little"),
                   "ch": int.from_bytes(body[2:4], "little"),
                   "rate": int.from_bytes(body[4:8], "little"),
                   "bps": int.from_bytes(body[14:16], "little")}
        elif cid == b"data" and fmt:
            if fmt["audio"] != 1 or fmt["ch"] not in (1, 2) or \
                    not 8000 <= fmt["rate"] <= 48000 or fmt["bps"] not in (8, 16):
                return None
            per_s = fmt["rate"] * fmt["ch"] * fmt["bps"] // 8
            n = min(size, len(raw) - i - 8)
            return round(n / float(per_s), 2) if per_s else None
        i += 8 + size + (size & 1)
    return None


# ================================================================ vendor calls
def imou_siren(client, device_id, channel_id="0", on=True):
    """Official sirenStart / sirenStop first (Imou's own open-API library);
    an older platform that does not know the method falls back to
    setDeviceCameraStatus enableType "siren" (cctvx's original call)."""
    from .imou import ImouError
    method = "sirenStart" if on else "sirenStop"
    params = {"token": client.token(), "deviceId": device_id}
    try:
        if str(channel_id) not in ("", "None"):
            params["channels"] = [int(channel_id)]
    except (TypeError, ValueError):
        pass
    try:
        return client.call(method, params)
    except ImouError as e:
        if e.code in ("DV1007", "network"):     # offline / no network: same answer
            raise
        first = e
    try:
        return client.siren(device_id, channel_id, on=on)
    except ImouError:
        raise first


def imou_light(client, device_id, channel_id="0", on=True):
    """setDeviceCameraStatus enableType "whiteLight" (Imou ability
    WhiteLight / ChnWhiteLight)."""
    return client.call("setDeviceCameraStatus", {
        "token": client.token(), "deviceId": device_id,
        "channelId": str(channel_id), "enableType": "whiteLight",
        "enable": bool(on)})


def _default_multipart(url, fields, files, timeout):
    import requests
    r = requests.post(url, data=fields, files=files, timeout=timeout,
                      allow_redirects=False)
    return r.status_code, r.text


def ezviz_voice_upload(client, name, raw, http=None):
    """/api/lapp/voice/upload (multipart: accessToken, voiceName, force,
    voiceFile) -> the platform's file url. Once per clip (cache it)."""
    import json
    from .ezviz import EzvizError, TIMEOUT_S
    tok, area = client.token()
    send = http or _default_multipart
    try:
        status, text = send(area + "/api/lapp/voice/upload",
                            {"accessToken": tok, "voiceName": str(name)[:40],
                             "force": "true"},
                            {"voiceFile": ("%s.wav" % name, bytes(raw), "audio/wav")},
                            TIMEOUT_S * 2)
    except Exception as e:  # noqa: BLE001
        raise EzvizError("network", str(e)[:120])
    if status != 200:
        raise EzvizError("http_%s" % status)
    try:
        res = json.loads(text) or {}
    except ValueError:
        raise EzvizError("bad_json")
    if str(res.get("code", "")) != "200":
        raise EzvizError(str(res.get("code") or "unknown"), res.get("msg"))
    data = res.get("data") or {}
    url = data.get("url") if isinstance(data, dict) else None
    if not url:
        raise EzvizError("no_url")
    return url


def ezviz_voice_send(client, serial, channel, file_url):
    return client.call("/api/lapp/voice/send", {
        "deviceSerial": serial, "channelNo": int(channel or 1),
        "fileUrl": file_url})


def ezviz_capacity(client, serial):
    """/api/lapp/device/capacity -> {support_talk, ...} (strings)."""
    data = client.call("/api/lapp/device/capacity", {"deviceSerial": serial})
    return data if isinstance(data, dict) else {}


def ezviz_ref(vendor_ref):
    """(serial, channel) from cctvx's EZVIZ vendor_ref "ezviz:<serial>[:<ch>]"."""
    parts = str(vendor_ref or "").split(":")
    serial = parts[1] if len(parts) > 1 else ""
    try:
        ch = int(parts[2]) if len(parts) > 2 and parts[2] else 1
    except ValueError:
        ch = 1
    return serial, ch
