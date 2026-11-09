"""Incremental multipart/mixed parser for the DVRs' long-lived event streams
(Hikvision ISAPI /ISAPI/Event/notification/alertStream, Dahua
/cgi-bin/eventManager.cgi?action=attach). Feed raw chunks, get whole parts
(content-type, body). Bounded: a part over MAX_PART is dropped (an image we
do not want), the buffer never grows past MAX_BUFFER."""
from __future__ import annotations

import re
from typing import List, Optional, Tuple

MAX_PART = 512 * 1024
MAX_BUFFER = 2 * 1024 * 1024
_BOUNDARY = re.compile(r'boundary="?([^";,\s]+)"?', re.I)


def boundary_of(content_type: str) -> Optional[str]:
    m = _BOUNDARY.search(content_type or "")
    return m.group(1) if m else None


class MultipartStream:
    def __init__(self, boundary: str):
        b = boundary[2:] if boundary.startswith("--") else boundary
        self.delim = ("--" + b).encode()
        self.buf = b""

    def feed(self, chunk: bytes) -> List[Tuple[str, bytes]]:
        self.buf += chunk or b""
        out = []
        while True:
            start = self.buf.find(self.delim)
            if start < 0:
                self.buf = self.buf[-len(self.delim):] if len(self.buf) > MAX_BUFFER else self.buf
                return out
            nxt = self.buf.find(self.delim, start + len(self.delim))
            if nxt < 0:
                if len(self.buf) - start > MAX_PART + 4096:
                    self.buf = self.buf[start + len(self.delim):]   # oversized: skip it
                return out
            part = self.buf[start + len(self.delim):nxt]
            self.buf = self.buf[nxt:]
            p = _split(part)
            if p is not None:
                out.append(p)


def _split(part: bytes) -> Optional[Tuple[str, bytes]]:
    part = part.lstrip(b"\r\n")
    if part.startswith(b"--"):
        return None                       # closing delimiter
    sep = part.find(b"\r\n\r\n")
    n = 4
    if sep < 0:
        sep, n = part.find(b"\n\n"), 2
    if sep < 0:
        return None
    head, body = part[:sep].decode("latin-1", "replace"), part[sep + n:]
    ctype = ""
    length = None
    for line in head.splitlines():
        k, _, v = line.partition(":")
        if k.strip().lower() == "content-type":
            ctype = v.strip()
        elif k.strip().lower() == "content-length":
            try:
                length = int(v.strip())
            except ValueError:
                length = None
    if length is not None and 0 <= length <= len(body):
        body = body[:length]
    else:
        body = body.rstrip(b"\r\n")
    if len(body) > MAX_PART:
        return None
    return ctype, body
