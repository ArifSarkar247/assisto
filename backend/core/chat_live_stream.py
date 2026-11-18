"""aichat-nine (owner AI answer quality rule + WORLD CLASS speed): REAL token
streaming for Assisto AI (POST chat/sessions/<id>/stream).

Before, the server produced the WHOLE answer (model + every guard) and only
then chunked it into SSE events, so the first visible word arrived after the
full generation (n=1 live: 3.4 s). Now the model streams (ai._anthropic_stream)
and this module releases text to the app as soon as it is SAFE:

  * only COMPLETE lines / sentences are released (never a half word);
  * the released prefix must pass the same guards the final answer passes
    (no "I sent / called / paid" claim, no cure / dose, no internal words,
    no invented taka amount on an own-data question, no table, never the
    ACTION line); a heading / list marker / "...:" line is held until the
    line after it arrives (a cut answer drops a dangling heading);
  * PII tokens are unmasked and Bangla digits applied, exactly as the final
    text; when a guard would change text that is already on the screen, the
    preview STOPS (frozen) and the rest arrives with the final answer.

The FINAL answer (finish_reply + consult line, saved, charged) is still the
single source of truth: after the model is done the server sends the rest
of it as tokens (when the preview is its prefix — always, except a frozen or
failed-over preview) and the `done` event carries the full text, which the
app shows (app/lib/screens/ai_chat_screen.dart replaces the bubble with it).

Charging, the cut/Continue rules, Stop, the credout 402 and the replay of a
client_id are unchanged: the credit check happens before the model is
called, so a 402 still comes back as plain JSON before any token.

The producer runs in a worker thread that SHARES the request's database
connection (Django thread sharing, like LiveServerTestCase): the request
thread only waits on a queue while the worker uses it, and the SSE
generator joins the worker before the response is closed. Switch:
settings.AI_LIVE_STREAM (default on).
"""
import logging
import queue
import re
import threading
import time

log = logging.getLogger(__name__)

_BOUNDARY = re.compile(r"(?<![0-9০-৯])[.!?।](?=\s)|\n")
_WS = re.compile(r"[ \t]{2,}")
_ACTION = re.compile(r"^\s*ACTION\s*:", re.M)
_TABLE_ROW = re.compile(r"^\s*\|.*\|\s*$", re.M)
FIRST_WAIT_S = 240          # the longest a producer may take before a first event


def enabled():
    try:
        from django.conf import settings
        return bool(getattr(settings, "AI_LIVE_STREAM", True))
    except Exception:  # noqa: BLE001
        return False


class LiveSink:
    """Collects raw model deltas; puts ("token", text) items on `q` when a
    safe, guarded prefix grows. `configure()` is called by the producer once
    it knows the reply language, the PII vault and the money sources."""

    def __init__(self):
        self.q = queue.Queue()
        self.buf = ""
        self.released = ""
        self.frozen = False
        self.ready = False
        self.first_at = None
        self._lock = threading.Lock()
        self.lang = "bn"
        self.vault = None
        self.text = ""
        self.data_reply = ""
        self.history = []
        self.strict = False

    # -- set up by the producer (views_chat._produce_reply)
    def configure(self, *, lang, vault=None, text="", data_reply="", history=None, strict=False):
        self.lang, self.vault, self.text = lang, vault, text or ""
        self.data_reply = data_reply or ""
        self.history = [h.get("content", "") for h in (history or [])]
        self.strict = bool(strict)
        self.ready = True

    # -- fed by the provider seam (ai._anthropic_stream / CI fakes)
    def reset(self):
        with self._lock:
            self.buf = ""
            if self.released:
                # a failover after text was shown: the new answer differs;
                # no more previews — the final text arrives with `done`
                self.frozen = True

    def feed(self, delta):
        with self._lock:
            if not delta or self.frozen or not self.ready:
                return
            self.buf += delta
            self._release()

    # -- internals
    def _safe_prefix(self):
        ends = [m.end() for m in _BOUNDARY.finditer(self.buf)]
        if not ends:
            return ""
        p = self.buf[:ends[-1]]
        m = _ACTION.search(p)
        if m:
            p = p[:m.start()]              # the ACTION line never reaches the user
        from .views_chat import _DANGLING
        lines = p.rstrip("\n").split("\n")
        while lines and (not lines[-1].strip() or _DANGLING.match(lines[-1])):
            lines.pop()                    # hold a heading until its body arrives
        return "\n".join(lines)

    def transform(self, p):
        """The guarded text of prefix `p` exactly as the final answer would
        show it, or None when a guard would change it (-> freeze)."""
        from . import ai_guard
        from . import ai_prompt as AP
        from . import views_chat as VC
        t = self.vault.unmask(p) if self.vault is not None else p
        t = _WS.sub(" ", AP.normalize_output(t))
        if not t:
            return ""
        if _TABLE_ROW.search(t):
            return None
        cleaned, _f = ai_guard.clean_assistant_answer(t, self.lang)
        if _WS.sub(" ", cleaned).strip() != t.strip():
            return None
        if VC.scrub_internal(t) != t.strip():
            return None
        money, _n = ai_guard.scrub_ungrounded_money(
            t, self.text, self.data_reply, self.history, lang=self.lang, strict=self.strict)
        if money != t and not money.startswith(t.rstrip()):
            return None                    # an amount would be cut out of shown text
        if self.lang == "bn":
            t = VC.bangla_digits(t)
        return t

    def _release(self):
        p = self._safe_prefix()
        if not p.strip() or len(p) <= 0:
            return
        try:
            t = self.transform(p)
        except Exception:  # noqa: BLE001 — a preview bug: final text only
            log.exception("live stream: preview guard failed")
            t = None
        if t is None or not t.startswith(self.released):
            self.frozen = True
            return
        new = t[len(self.released):]
        if new:
            self.released = t
            if self.first_at is None:
                self.first_at = time.monotonic()
            self.q.put(("token", new))

    def finish(self, item):
        self.q.put(item)


def suffix_chunks(final, released, step=120):
    """The rest of the final answer after what the preview already showed
    (all of it when the preview is not its prefix — the app then replaces)."""
    rest = final[len(released):] if released and final.startswith(released) else (
        "" if released else final)
    return [rest[i:i + step] for i in range(0, len(rest), step)]


def run_worker(target):
    """Run `target()` in a thread that shares this thread's DB connection."""
    from django.db import connections
    conn = connections["default"]
    conn.inc_thread_sharing()

    def body():
        connections["default"] = conn
        try:
            target()
        finally:
            conn.dec_thread_sharing()
    th = threading.Thread(target=body, name="chat-live-stream", daemon=True)
    th.start()
    return th
