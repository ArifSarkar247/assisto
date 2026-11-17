"""gboxlinux — the owner tapped "Siren" or "Warning" on an alert (cctvact
"play" task): the Guard Box sounds it through ITS OWN speaker (a Raspberry
Pi's 3.5 mm / HDMI / USB speaker, a mini PC's or a Windows PC's sound card).

Same contract as the phone Guard Box (app/lib/ipcam/box_siren.dart):
  {id, sound: "siren"|"warn", seconds: 3..60, warn_url: "/api/v1/shop/device/..."}
  * warn  -> the owner's recorded warning, fetched with THIS box's token from
             the path the server named (never typed here), played on repeat
             for `seconds`; kept only in a temp file, deleted after;
  * siren -> a loud two-tone siren generated here (no file to download);
  * a warning that cannot be fetched or played falls back to the siren
    (it still deters) and the result says so honestly.

Players: Linux `aplay` (ALSA, package alsa-utils) for WAV, else `paplay`,
`pw-play` or `ffplay`; a non-WAV clip is first decoded to WAV with PyAV when
it is bundled. Windows: winsound. No player -> {"ok": false, "code":
"no_player"}, never a fake success.
"""
from __future__ import annotations

import io
import logging
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from typing import Callable, List, Optional

log = logging.getLogger(__name__)

RATE = 22050
MIN_S, MAX_S = 3, 60
WARN_PREFIX = "/api/v1/shop/device/"


def clean_task(t) -> Optional[dict]:
    """A play request from the heartbeat or a gateway task -> safe values."""
    if not isinstance(t, dict):
        return None
    try:
        tid = int(t.get("id"))
    except (TypeError, ValueError):
        return None
    req = t.get("request") if isinstance(t.get("request"), dict) else t
    sound = "warn" if req.get("sound") == "warn" else "siren"
    try:
        secs = int(req.get("seconds") or 20)
    except (TypeError, ValueError):
        secs = 20
    url = str(req.get("warn_url") or "")
    return {"id": tid, "sound": sound, "seconds": max(MIN_S, min(MAX_S, secs)),
            "warn_url": url if url.startswith(WARN_PREFIX) and ".." not in url else ""}


def siren_wav(seconds: float = 2.0, rate: int = RATE) -> bytes:
    """A two-tone (650 / 1000 Hz) siren as 16-bit mono WAV, generated."""
    n = int(rate * seconds)
    buf = bytearray()
    for i in range(n):
        t = i / rate
        f = 650.0 if int(t * 2) % 2 == 0 else 1000.0
        v = 0.8 * math.sin(2 * math.pi * f * t)
        buf += struct.pack("<h", int(v * 32767))
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(buf))
    return out.getvalue()


def to_wav(data: bytes) -> Optional[bytes]:
    """The clip as WAV: WAV as is; anything else (m4a / ogg / mp3) decoded
    with PyAV when available. None when it cannot be decoded."""
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return data
    try:
        import av  # bundled with the optional live view
    except Exception:
        return None
    try:
        src = av.open(io.BytesIO(data))
        res = av.AudioResampler(format="s16", layout="mono", rate=RATE)
        pcm = bytearray()
        for frame in src.decode(audio=0):
            for f in res.resample(frame) or []:
                pcm += bytes(f.planes[0])[: f.samples * 2]
            if len(pcm) > RATE * 2 * 120:
                break
        src.close()
        if not pcm:
            return None
        out = io.BytesIO()
        with wave.open(out, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(bytes(pcm))
        return out.getvalue()
    except Exception:
        return None


def wav_seconds(data: bytes) -> float:
    try:
        with wave.open(io.BytesIO(data), "rb") as w:
            return w.getnframes() / float(w.getframerate() or 1)
    except Exception:
        return 0.0


def find_player() -> Optional[List[str]]:
    if sys.platform == "win32":
        return ["winsound"]
    for cmd in (["aplay", "-q"], ["paplay"], ["pw-play"],
                ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"]):
        if shutil.which(cmd[0]):
            return cmd
    return None


def _play_file(player: List[str], path: str, timeout: float) -> bool:
    if player == ["winsound"]:
        try:
            import winsound
            winsound.PlaySound(path, winsound.SND_FILENAME)
            return True
        except Exception:
            return False
    try:
        r = subprocess.run(player + [path], timeout=timeout + 5,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class Speaker:
    """Plays play-tasks one at a time (a repeated id is ignored)."""

    def __init__(self, fetch: Callable[[str], Optional[bytes]],
                 player: Optional[List[str]] = None,
                 play_file: Callable[[List[str], str, float], bool] = _play_file,
                 clock: Callable[[], float] = time.monotonic):
        self.fetch = fetch
        self.player = player if player is not None else find_player()
        self.play_file = play_file
        self.clock = clock
        self._done: List[int] = []
        self._lock = threading.Lock()
        self.last: Optional[dict] = None

    def _loop(self, wav: bytes, seconds: int) -> bool:
        fd, path = tempfile.mkstemp(prefix="assisto_play_", suffix=".wav")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(wav)
            one = max(0.5, wav_seconds(wav))
            end = self.clock() + seconds
            played = False
            while True:
                if not self.play_file(self.player, path, one):
                    return played
                played = True
                if self.clock() + 0.2 >= end:
                    return True
        finally:
            try:
                os.remove(path)
            except OSError:
                pass

    def play(self, task: dict) -> dict:
        """-> {ok, code, played: "warn"|"siren"|"", seconds}. Blocking."""
        t = clean_task(task)
        if t is None:
            return {"ok": False, "code": "bad_task", "played": "", "seconds": 0}
        with self._lock:
            if t["id"] in self._done:
                return {"ok": True, "code": "duplicate", "played": "", "seconds": 0}
            self._done = (self._done + [t["id"]])[-100:]
            if not self.player:
                self.last = {"ok": False, "code": "no_player", "played": "", "seconds": 0}
                return self.last
            note = ""
            if t["sound"] == "warn":
                wav = None
                if t["warn_url"]:
                    try:
                        raw = self.fetch(t["warn_url"])
                    except Exception:
                        raw = None
                    wav = to_wav(raw) if raw else None
                    note = "" if wav else ("clip_unplayable" if raw else "clip_unavailable")
                else:
                    note = "no_clip"
                if wav and self._loop(wav, t["seconds"]):
                    self.last = {"ok": True, "code": "ok", "played": "warn",
                                 "seconds": t["seconds"]}
                    return self.last
            ok = self._loop(siren_wav(), t["seconds"])
            self.last = {"ok": ok, "code": ("ok" if ok else "play_failed"),
                         "played": "siren" if ok else "", "seconds": t["seconds"] if ok else 0}
            if note:
                self.last["fallback"] = note
            return self.last

    def play_async(self, tasks) -> None:
        tasks = [t for t in (tasks or []) if isinstance(t, dict)]
        if not tasks:
            return

        def run():
            for t in tasks:
                try:
                    r = self.play(t)
                    log.info("play task %s: %s", t.get("id"), r.get("code"))
                except Exception:
                    log.exception("play task failed")
        threading.Thread(target=run, name="speaker", daemon=True).start()


def device_fetcher(base_url: str, token_for: Callable[[], tuple],
                   timeout: float = 20.0, max_bytes: int = 8 * 1024 * 1024):
    """fetch(path) for the owner's warning clip: GET <server>/<path> with the
    box's token in the header (never in the URL). token_for() -> (token,
    server camera id or None); a SITE token names the camera."""
    from urllib.parse import urlsplit, urlunsplit

    parts = urlsplit(base_url)
    origin = urlunsplit((parts.scheme, parts.netloc, "", "", ""))

    def fetch(path: str) -> Optional[bytes]:
        import requests
        tok, cam = token_for()
        if not tok or not path.startswith(WARN_PREFIX):
            return None
        headers = {"X-Shop-Token": tok}
        if cam is not None:
            headers["X-Shop-Camera"] = str(int(cam))
        try:
            r = requests.get(origin + path, headers=headers,
                             timeout=timeout, stream=True, allow_redirects=False)
            if r.status_code != 200:
                return None
            data = r.raw.read(max_bytes + 1, decode_content=True)
            return data if 0 < len(data) <= max_bytes else None
        except Exception:
            return None
    return fetch
