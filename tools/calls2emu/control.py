#!/usr/bin/env python3
"""calls-2emu: test-only CONTROL channel between two app instances on two
emulators (A = flow driver on emulator-5554, B = call peer on emulator-5556).

Runs on the CI runner only (never on a server): both emulators reach it at
http://10.0.2.2:8710. Standard library only, no auth (the runner is throw-away
and the port is not exposed outside it).

  A  POST /cmd      {"cmd": "...", "args": {...}}      -> {"id": n}
  B  GET  /next?after=n[&wait=s]                       -> {"id","cmd","args"} | {}
  B  POST /done     {"id": n, "ok": bool, "result": {...}, "error": "..."}
  A  GET  /result?id=n                                 -> {"pending": true} | the done body
  *  POST /hello    {"side": "B", ...}                 -> B announces it signed in
  *  GET  /state                                       -> {"hello": {...}, "last_id": n}
  *  POST /evidence {"case","side","t","data"}         -> <out>/evidence/<case>_<side>_<t>.json
  *  POST /sample   {"case": ..., ...}                 -> appended to <out>/samples.jsonl
  *  POST /log      {"side", "line"}                   -> appended to <out>/peer_<side>.log
  A  POST /rec      {"case": "a", "on": true|false}    -> host screenrecord on BOTH emulators
                                                          (best effort, never fails a case)

usage: control.py --out DIR [--port 8710] [--serials emulator-5554,emulator-5556]
"""
import argparse
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOCK = threading.Condition()
CMDS = []          # [{"id", "cmd", "args", "at"}]
DONE = {}          # id -> body
HELLO = {}
OUT = "."
SERIALS = []
REC = {}           # case -> [Popen]
SAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def _append(name, line):
    with open(os.path.join(OUT, name), "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def _rec(case, on):
    case = SAFE.sub("_", case)[:40] or "case"
    if on:
        procs = []
        os.makedirs(os.path.join(OUT, "videos"), exist_ok=True)
        for s, side in zip(SERIALS, "AB"):
            # screenrecord stops by itself after 170 s; stop() ends it earlier.
            # Its own output is kept (run 44181263539 produced no video, no reason).
            lg = open(os.path.join(OUT, "videos", "rec_%s_%s.log" % (case, side)), "w")
            procs.append(subprocess.Popen(
                ["timeout", "200", "adb", "-s", s, "shell", "screenrecord", "--verbose",
                 "--time-limit", "170", "/sdcard/c2e_%s.mp4" % case],
                stdout=lg, stderr=subprocess.STDOUT))
        REC[case] = procs
        return {"recording": case}
    for s in SERIALS:
        subprocess.run(["timeout", "15", "adb", "-s", s, "shell", "pkill", "-INT", "screenrecord"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for p in REC.pop(case, []):
        try:
            p.wait(timeout=15)
        except Exception:
            p.kill()
    os.makedirs(os.path.join(OUT, "videos"), exist_ok=True)
    got = []
    for s, side in zip(SERIALS, "AB"):
        dst = os.path.join(OUT, "videos", "%s_%s.mp4" % (case, side))
        time.sleep(1)
        with open(os.path.join(OUT, "videos", "rec_%s_%s.log" % (case, side)), "a") as lg:
            subprocess.run(["timeout", "60", "adb", "-s", s, "pull", "/sdcard/c2e_%s.mp4" % case, dst],
                           stdout=lg, stderr=subprocess.STDOUT)
        subprocess.run(["timeout", "15", "adb", "-s", s, "shell", "rm", "-f", "/sdcard/c2e_%s.mp4" % case],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            got.append(os.path.basename(dst))
    return {"videos": got}


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a):
        _append("control_http.log", "%s %s" % (time.strftime("%H:%M:%S"), fmt % a))

    def _send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _body(self):
        raw = b""
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            while True:  # HTTP/1.1 chunked body (a client that sends no length)
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                raw += self.rfile.read(size)
                self.rfile.readline()
        else:
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            return json.loads(raw or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/health":
            return self._send(200, {"ok": True})
        if u.path == "/state":
            with LOCK:
                return self._send(200, {"hello": HELLO, "last_id": len(CMDS)})
        if u.path == "/next":
            after = int(q.get("after", "0"))
            wait = min(float(q.get("wait", "8")), 20.0)
            end = time.time() + wait
            with LOCK:
                while len(CMDS) <= after and time.time() < end:
                    LOCK.wait(timeout=max(0.05, end - time.time()))
                if len(CMDS) > after:
                    c = CMDS[after]
                    return self._send(200, {"id": c["id"], "cmd": c["cmd"], "args": c["args"]})
            return self._send(200, {})
        if u.path == "/result":
            i = int(q.get("id", "0"))
            wait = min(float(q.get("wait", "0")), 5.0)
            end = time.time() + wait
            with LOCK:
                while i not in DONE and time.time() < end:
                    LOCK.wait(timeout=max(0.05, end - time.time()))
                return self._send(200, DONE.get(i) or {"pending": True})
        return self._send(404, {"error": "unknown path"})

    def do_POST(self):
        u = urlparse(self.path)
        b = self._body()
        if u.path == "/cmd":
            with LOCK:
                c = {"id": len(CMDS) + 1, "cmd": str(b.get("cmd")), "args": b.get("args") or {},
                     "at": time.time()}
                CMDS.append(c)
                LOCK.notify_all()
            _append("commands.log", "%s -> B #%d %s %s" % (time.strftime("%H:%M:%S"), c["id"], c["cmd"],
                                                            json.dumps(c["args"])))
            return self._send(200, {"id": c["id"]})
        if u.path == "/done":
            with LOCK:
                DONE[int(b.get("id", 0))] = b
                LOCK.notify_all()
            _append("commands.log", "%s <- B #%s ok=%s %s" % (
                time.strftime("%H:%M:%S"), b.get("id"), b.get("ok"),
                (b.get("error") or json.dumps(b.get("result")))[:400]))
            return self._send(200, {"ok": True})
        if u.path == "/hello":
            with LOCK:
                HELLO.update(b)
                HELLO["at"] = time.time()
            _append("commands.log", "%s hello %s" % (time.strftime("%H:%M:%S"), json.dumps(b)))
            return self._send(200, {"ok": True, "last_id": len(CMDS)})
        if u.path == "/evidence":
            os.makedirs(os.path.join(OUT, "evidence"), exist_ok=True)
            name = "%s_%s_%s.json" % tuple(SAFE.sub("_", str(b.get(k, "x")))[:30] for k in ("case", "side", "t"))
            with open(os.path.join(OUT, "evidence", name), "w", encoding="utf-8") as f:
                json.dump(b.get("data"), f, indent=1)
            return self._send(200, {"ok": True, "file": name})
        if u.path == "/sample":
            _append("samples.jsonl", json.dumps(b))
            return self._send(200, {"ok": True})
        if u.path == "/log":
            side = SAFE.sub("_", str(b.get("side", "B")))[:4]
            _append("peer_%s.log" % side, "%s %s" % (time.strftime("%H:%M:%S"), b.get("line", "")))
            return self._send(200, {"ok": True})
        if u.path == "/rec":
            try:
                return self._send(200, _rec(str(b.get("case", "case")), bool(b.get("on"))))
            except Exception as e:  # recording is evidence only
                return self._send(200, {"error": repr(e)})
        return self._send(404, {"error": "unknown path"})


def main():
    global OUT, SERIALS
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=8710)
    ap.add_argument("--serials", default="emulator-5554,emulator-5556")
    a = ap.parse_args()
    OUT = a.out
    SERIALS = [s for s in a.serials.split(",") if s]
    os.makedirs(OUT, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
