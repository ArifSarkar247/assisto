"""sc1 — server-side scrubbing + grouping of app crash/error reports.

The phone already scrubs (app/lib/diag/crash_scrub.dart); the server scrubs
AGAIN with the same rules so an old build, a buggy client or a hand-made POST
can never store personal data:
  * quoted text ("…", '…', «…», “…”) dropped — exception messages quote input;
  * URLs (whole, incl. query), e-mails, phone-like digit runs (7+ digits,
    optional +/spaces/dashes) and any 5+ digit number → placeholders;
  * file paths under /data /storage /sdcard /mnt /private /var /Users /home →
    <path> (file names can be people's names);
  * opaque tokens (20+ chars of base64/hex alphabet) → <token>;
  * capped length.
Frames keep only code locations "fn (package:x/y.dart:12)"; anything else is
dropped. The fingerprint is computed HERE (client value ignored):
sha256(type | first 3 frames without line numbers)[:20].
"""
import hashlib
import re

MAX_MESSAGE = 300
MAX_FRAMES = 8

_QUOTED = re.compile(r'"[^"\n]*"|\'[^\'\n]*\'|«[^»\n]*»|“[^”\n]*”')
_URL = re.compile(r"\b(?:https?|wss?|ftp|content|file)://\S+", re.I)
_EMAIL = re.compile(r"[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+")
_PATH = re.compile(r"(?:/(?:data|storage|sdcard|mnt|private|var|Users|home)(?:/[^\s:,;)\]]+)+)")
_TOKEN = re.compile(r"\b[A-Za-z0-9_\-+/=]{20,}\b")
_PHONE = re.compile(r"\+?\d[\d \-]{5,}\d")
_BIGNUM = re.compile(r"\d{5,}")
_WS = re.compile(r"\s+")
_FRAME_OK = re.compile(r"^(?P<fn>[^()\n]{1,80}) \((?P<loc>(?:package|dart|org-dartlang-sdk):[^()\s]{1,160})\)$")
_DART_FRAME = re.compile(r"#\d+\s+(\S.*?)\s+\(((?:package|dart|org-dartlang-sdk):[^)]*)\)")
_TYPE = re.compile(r"^[A-Za-z_$][\w.$]{0,79}$")
_SAFE_FIELD = re.compile(r"[^\w .,()\-+/]")


def message(raw) -> str:
    s = str(raw or "")
    s = _QUOTED.sub('"…"', s)
    s = _URL.sub("<url>", s)
    s = _EMAIL.sub("<email>", s)
    s = _PATH.sub("<path>", s)
    s = _TOKEN.sub("<token>", s)
    s = _PHONE.sub("<num>", s)
    s = _BIGNUM.sub("<num>", s)
    s = _WS.sub(" ", s).strip()
    if len(s) > MAX_MESSAGE:
        s = s[:MAX_MESSAGE] + "…"
    return s


def _clean_frame(f: str):
    f = str(f or "").strip()
    m = _FRAME_OK.match(f)
    if not m:
        return None
    fn = _QUOTED.sub('"…"', m.group("fn")).strip()
    return f"{fn} ({m.group('loc')})"


def frames(raw) -> list:
    out = []
    if isinstance(raw, (list, tuple)):
        for f in raw[:40]:
            c = _clean_frame(f)
            if c:
                out.append(c)
            if len(out) >= MAX_FRAMES:
                break
    return out


def frames_from_text(log: str) -> list:
    """Code frames out of a raw Dart stack trace (the v1 StartupGuard log)."""
    out = []
    for line in str(log or "").splitlines():
        m = _DART_FRAME.search(line)
        if not m:
            continue
        loc = re.sub(r":(\d+):\d+$", r":\1", m.group(2))
        c = _clean_frame(f"{m.group(1)[:80]} ({loc})")
        if c:
            out.append(c)
        if len(out) >= MAX_FRAMES:
            break
    return out


def error_type(raw) -> str:
    t = str(raw or "").strip().split("<")[0]
    return t if _TYPE.match(t) else "Error"


def type_and_message_from_log(log: str):
    """v1 body: first line looks like 'TypeName: detail' (or just a message)."""
    first = (str(log or "").strip().splitlines() or [""])[0]
    m = re.match(r"^\s*(?:\[[\w ]+\]\s*)?([A-Za-z_$][\w.$]*(?:Exception|Error))\s*:?\s*(.*)$", first)
    if m:
        return error_type(m.group(1)), message(m.group(2))
    return "StartupCrash", message(first)


def field(raw, n: int) -> str:
    """Device/version fields: plain characters only, capped."""
    return _SAFE_FIELD.sub("", str(raw or ""))[:n].strip()


def fingerprint(etype: str, frs: list) -> str:
    top = "|".join(re.sub(r":\d+\)$", ")", f) for f in frs[:3])
    return hashlib.sha256(f"{etype}|{top}".encode()).hexdigest()[:20]


def user_hash(user_id) -> str:
    """Same opaque tag the phone gives Crashlytics (CrashScrub.userHash)."""
    if user_id is None:
        return ""
    return hashlib.sha256(f"assisto-crash-v1:{user_id}".encode()).hexdigest()[:16]
