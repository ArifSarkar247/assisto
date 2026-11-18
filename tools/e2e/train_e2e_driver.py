#!/usr/bin/env python3
"""train-e2e: the Train Tracker E2E — API proof (stdlib only, CI only).

Runs against the throw-away Django of train-e2e.yml (settings_e2eproof +
a real Redis service), BEFORE the emulator part (which shows the same
states on the phone, bn + en, with screenshots). Every rider point goes
through the REAL endpoints; ci-e2e/train-sim only moves the train modules'
clock and generates points along Rangpur Express 771's real OSM polyline.

Steps (each one a row in train_e2e.json; red unless all pass):
  data      771/772 found (number, English name, Bangla digits), official
            times + off days
  live      3 riders (mock=false) ping at train speed -> Redis train:live:771
            (TTL <= 15 min) -> /now + /live: between the right stations,
            speed, 3 live, next station ETA, freshness "live"
  latency   ping -> visible in /now (ms, per ping; p50 / max)
  payload   /now and /live bytes on the wire (gzip) and raw (2G budget)
  outlier   off-the-line rider + mock-location rider rejected, trust drops,
            still "3 live"
  stale     riders stop -> "N min ago"
  predicted live key expired (TTL aged with the clock) + learned delay
  timetable learned history removed -> timetable estimate, labelled
  text      a pasted 16318-style reply (2 people) -> the position moves
  checkin   2 agreeing reports accepted; a phone 55 km away rejected
Usage: train_e2e_driver.py OUT_DIR   (BASE env, default http://127.0.0.1:8700)
"""
import gzip
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("TRAIN_E2E_BASE", "http://127.0.0.1:8700") + "/api/v1"
NO = "771"
A, B = ("01700000001", "Reality#2026"), ("01700000002", "Reality#2026")
RIDERS = [("01999000101", "ci-train-rider-sample"), ("01999000102", "ci-train-rider-sample"),
          ("01999000103", "ci-train-rider-sample")]
NOW_GZ_BUDGET = 1500        # bytes on the wire, /now (polled by every watcher)
LIVE_GZ_BUDGET = 16000      # bytes on the wire, /live (the app's full screen answer)
LATENCY_BUDGET_MS = 3000


class Fail(Exception):
    pass


def http(method, path, token=None, body=None, gz=False):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept-Language", "en")
    if token:
        req.add_header("Authorization", "Token " + token)
    if gz:
        req.add_header("Accept-Encoding", "gzip")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            wire, status, enc = r.read(), r.status, r.headers.get("Content-Encoding")
    except urllib.error.HTTPError as e:
        wire, status, enc = e.read(), e.code, e.headers.get("Content-Encoding")
    raw = gzip.decompress(wire) if enc == "gzip" else wire
    try:
        js = json.loads(raw) if raw else {}
    except ValueError:
        js = {"_raw": raw[:200].decode("utf-8", "replace")}
    return status, js, len(wire), len(raw)


def login(who):
    s, j, _, _ = http("POST", "/auth/login", body={"identifier": who[0], "password": who[1]})
    if s != 200 or not j.get("token"):
        raise Fail("login %s: %s %s" % (who[0][-3:], s, j))
    return j["token"]


def sim(tok, **body):
    s, j, _, _ = http("POST", "/ci-e2e/train-sim", tok, body)
    if s != 200:
        raise Fail("train-sim %s: %s %s" % (body.get("op"), s, j))
    return j


def now_(tok, date):
    s, j, wire, raw = http("GET", "/train/%s/now?date=%s" % (NO, date), tok, gz=True)
    if s != 200:
        raise Fail("/now %s %s" % (s, j))
    return j, wire, raw


def live_(tok, date):
    s, j, wire, raw = http("GET", "/train/%s/live?date=%s" % (NO, date), tok, gz=True)
    if s != 200:
        raise Fail("/live %s %s" % (s, j))
    return j, wire, raw


class Run:
    def __init__(self, out):
        self.out, self.steps, self.metrics = out, [], {}

    def step(self, name, fn):
        t0 = time.time()
        row = {"step": name, "ok": False}
        try:
            row["detail"] = fn()
            row["ok"] = True
        except (Fail, AssertionError, KeyError, TypeError, ValueError) as e:
            row["error"] = "%s: %s" % (type(e).__name__, str(e)[:600])
        row["ms"] = int((time.time() - t0) * 1000)
        self.steps.append(row)
        print(("OK  " if row["ok"] else "BAD ") + name + " " +
              json.dumps(row.get("detail") or row.get("error"), ensure_ascii=False,
                         default=str)[:400], flush=True)
        return row["ok"]


def ensure(cond, msg):
    if not cond:
        raise Fail(msg)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    run = Run(out)
    ta, tb = login(A), login(B)
    tr = [login(r) for r in RIDERS]
    ctx = {}

    def data():
        got = {}
        for q in ("771", "Rangpur Express", "৭৭১"):
            s, j, _, _ = http("GET", "/train/search?q=" + urllib.request.quote(q), ta)
            ensure(s == 200, "search %s -> %s" % (q, s))
            got[q] = sorted(x["no"] for x in j["trains"] if x["no"] in ("771", "772"))
            ensure("771" in got[q], "771 not found by %r" % q)
        rows = {x["no"]: x for x in http("GET", "/train/search?q=Rangpur%20Express", ta)[1]["trains"]}
        want = {"771": ("09:10", "19:00", [0]), "772": ("20:00", "06:00", [6])}
        for no, w in want.items():
            x = rows.get(no) or {}
            ensure((x.get("dep"), x.get("arr"), x.get("off_days")) == w,
                   "%s times/off days %s" % (no, x))
            ensure(x.get("name_en") == "Rangpur Express", "%s name_en %s" % (no, x.get("name_en")))
        return {"found": got, "771": rows["771"]["dep"] + "-" + rows["771"]["arr"] + " off Mon",
                "772": rows["772"]["dep"] + "-" + rows["772"]["arr"] + " off Sun"}

    def live():
        c = sim(ta, op="clock", no=NO, minutes_after_dep=300)
        ctx["date"] = d = c["date"]
        ctx["stations"] = c["stations"]
        g = sim(ta, op="riders", no=NO, date=d, minutes=6, delay_min=10, spacing_s=10,
                ahead_s=25, stagger_s=1.5)
        ctx["g"] = g
        skew = g["now_ms"] / 1000.0 - time.time()        # the train modules' clock - ours
        tokens = []
        for k, t in enumerate(tr):
            s, j, _, _ = http("POST", "/train/%s/trip" % NO, t, {"date": d})
            ensure(s == 200 and j.get("token"), "trip %d: %s %s" % (k, s, j))
            tokens.append(j["token"])
        ctx["trips"] = tokens
        lat = []
        # catch-up batch: every point whose time has passed (queued on the phone)
        for k, pts in enumerate(g["riders"]):
            past = [p for p in pts if p["at"] <= g["now_ms"]]
            s, j, _, _ = http("POST", "/train/ping", tr[k], {"token": tokens[k], "points": past})
            ensure(s == 200 and j.get("accepted", 0) >= len(past) - 1,
                   "rider %d batch: %s" % (k, j))
            ensure(not j.get("reasons", {}).get("mock"), "mock flag was sent")
        # live rounds: each future point is sent the moment its time comes
        future = sorted(((p["at"], k, p) for k, pts in enumerate(g["riders"])
                         for p in pts if p["at"] > g["now_ms"]), key=lambda x: x[0])
        for at_ms, k, p in future:
            wait = at_ms / 1000.0 - (time.time() + skew) + 0.05
            if wait > 0:
                time.sleep(wait)
            t0 = time.time()
            s, j, _, _ = http("POST", "/train/ping", tr[k], {"token": tokens[k], "points": [p]})
            ensure(s == 200 and j.get("accepted") == 1, "rider %d live ping: %s" % (k, j))
            while True:
                st, _, _ = now_(ta, d)
                upd = (st.get("freshness") or {}).get("updated_at")
                if upd and st.get("contributors") == 3 and _ts(upd) >= at_ms / 1000.0 - 0.01:
                    break
                ensure(time.time() - t0 < 90, "ping %d not visible in 90 s: %s" % (k, st))
                time.sleep(0.05)
            lat.append(int((time.time() - t0) * 1000))
        ensure(len(lat) >= 6, "only %d live pings" % len(lat))
        ctx["lat"] = lat
        st = sim(ta, op="state", no=NO, date=d)
        ensure(st["redis"] and st["in_redis"], "live state not in Redis: %s" % st)
        ensure(0 < (st["ttl"] or 0) <= 900, "TTL %s" % st["ttl"])
        s = st["state"]
        ensure(s["mode"] == "live" and s["contributors"] == 3, "state %s" % s)
        n, wire, raw = now_(ta, d)
        e = g["expect"]
        ensure(n["freshness"]["state"] == "live", "freshness %s" % n["freshness"])
        ensure(n["contributors"] == 3, "contributors %s" % n["contributors"])
        ensure(20 <= (n["speed_kmh"] or 0) <= 130, "speed %s" % n["speed_kmh"])
        ensure(n["last"]["id"] == e["prev_halt"]["id"], "last %s vs %s" % (n["last"], e["prev_halt"]))
        ensure(n["next"]["id"] == e["next_halt"]["id"] and n["next"].get("eta"),
               "next %s vs %s" % (n["next"], e["next_halt"]))
        ensure(abs(n["ch"] - e["ch"]) < 1500, "position %s m vs truth %s m" % (n["ch"], e["ch"]))
        v, lwire, lraw = live_(ta, d)
        line = v["line"]
        here = line["stations"][line["now_index"]]["id"]
        nxt = line["stations"][line["next_index"]]["id"]
        ensure(here == e["prev"]["id"] and nxt == e["next"]["id"],
               "timeline %s->%s vs truth %s->%s" % (here, nxt, e["prev"]["id"], e["next"]["id"]))
        ensure(v["sharers"] == 3 and v["live"]["sharers"] == 3, "sharers %s" % v.get("sharers"))
        ensure(v["freshness"]["state"] == "live", "live freshness %s" % v["freshness"])
        ctx["sizes"] = {"now_gzip": wire, "now_raw": raw, "live_gzip": lwire, "live_raw": lraw}
        return {"date": d, "between": "%s -> %s" % (e["prev"]["en"], e["next"]["en"]),
                "speed_kmh": n["speed_kmh"], "contributors": n["contributors"],
                "next_eta": n["next"]["eta"][11:16], "delay_min": n["delay_min"],
                "redis_ttl_s": st["ttl"], "position_error_m": abs(n["ch"] - e["ch"])}

    def latency():
        lat = sorted(ctx["lat"])
        p50 = lat[len(lat) // 2]
        run.metrics["ping_to_live_ms"] = {"p50": p50, "max": lat[-1], "n": len(lat), "all": ctx["lat"]}
        ensure(lat[-1] <= LATENCY_BUDGET_MS, "max %d ms > %d" % (lat[-1], LATENCY_BUDGET_MS))
        return run.metrics["ping_to_live_ms"]

    def payload():
        s = ctx["sizes"]
        run.metrics["payload_bytes"] = s
        ensure(s["now_gzip"] <= NOW_GZ_BUDGET, "/now %d B > %d" % (s["now_gzip"], NOW_GZ_BUDGET))
        ensure(s["live_gzip"] <= LIVE_GZ_BUDGET, "/live %d B > %d" % (s["live_gzip"], LIVE_GZ_BUDGET))
        ensure(s["live_gzip"] < s["live_raw"], "/live is not compressed")
        # 2G: ~5 KB/s usable -> seconds per poll
        s["seconds_on_2g_now"] = round(s["now_gzip"] / 5000.0, 2)
        s["seconds_on_2g_live"] = round(s["live_gzip"] / 5000.0, 2)
        return s

    def outlier():
        d, g = ctx["date"], ctx["g"]
        res = {}
        for kind in ("off_line", "mock"):
            s, j, _, _ = http("POST", "/train/%s/trip" % NO, tb, {"date": d})
            ensure(s == 200, "outlier trip %s" % j)
            s, j, _, _ = http("POST", "/train/ping", tb, {"token": j["token"],
                                                           "points": g["outlier"][kind]})
            ensure(s == 200 and j["accepted"] == 0, "%s accepted: %s" % (kind, j))
            ensure(j["reasons"].get(kind, 0) >= 1, "%s reasons %s" % (kind, j["reasons"]))
            res[kind] = j["reasons"]
        st = sim(ta, op="state", no=NO, date=d)
        trust = [t["trust"] for t in st["trips"]]
        ensure(len(trust) == 5, "trips %s" % st["trips"])
        ensure(trust[3] < 0.6 and trust[4] < trust[3], "trust did not drop: %s" % trust)
        n, _, _ = now_(ta, d)
        ensure(n["contributors"] == 3, "outliers counted: %s" % n["contributors"])
        res["trust"] = trust
        return res

    def stale():
        d = ctx["date"]
        for k, t in enumerate(tr):
            s, j, _, _ = http("POST", "/train/trip/stop", t, {"token": ctx["trips"][k]})
            ensure(j.get("status") == "ended", "stop %s" % j)
        a = sim(ta, op="advance", no=NO, date=d, minutes=4)
        n, _, _ = now_(ta, d)
        f = n["freshness"]
        ensure(f["state"] == "stale" and 200 <= f["age_s"] <= 330, "freshness %s" % f)
        return {"freshness": f, "ttl_left": a["ttl_left"], "label": "%d min ago" % -(-f["age_s"] // 60)}

    def predicted():
        d = ctx["date"]
        sim(ta, op="learn", no=NO, date=d, weeks=4, delay_min=16)
        sim(ta, op="advance", no=NO, date=d, minutes=12)
        st = sim(ta, op="state", no=NO, date=d)
        ensure(not st["in_redis"], "live key still in Redis after 16 min: ttl %s" % st["ttl"])
        n, _, _ = now_(ta, d)
        ensure(n["mode"] == "predicted" and n["freshness"]["state"] == "predicted", "mode %s" % n["mode"])
        ensure(16 <= (n["delay_min"] or 0) <= 18, "delay %s" % n["delay_min"])
        ensure(n["confidence"] <= 0.3, "confidence %s" % n["confidence"])
        v, _, _ = live_(ta, d)
        ensure(v["freshness"]["state"] == "predicted" and "predicted" in v, "live view %s" % v["freshness"])
        return {"delay_min": n["delay_min"], "next": (n.get("next") or {}).get("en"),
                "learned_from": n.get("learned_from")}

    def timetable():
        d = ctx["date"]
        sim(ta, op="forget", no=NO)
        n, _, _ = now_(ta, d)
        ensure(n["mode"] == "timetable" and n["freshness"]["state"] == "timetable", "mode %s" % n["mode"])
        ensure(n["note_en"] == "Estimated from timetable", "note %s" % n.get("note_en"))
        ctx["tt_km"] = n["km"]
        v, _, _ = live_(ta, d)
        ensure(v["freshness"].get("note_bn") == "সময়সূচি থেকে আনুমানিক", "bn note %s" % v["freshness"])
        return {"state": n["state"], "km": n["km"], "note": n["note_en"]}

    def text():
        d = ctx["date"]
        x = sim(ta, op="text16318", no=NO, date=d, delay_min=12)
        s, j1, _, _ = http("POST", "/train/text", tr[0], {"text": x["text"], "source": "paste"})
        ensure(s == 200 and j1["parsed"] and j1["parsed"]["station_id"] == x["station"]["id"],
               "parse %s" % j1)
        ensure(j1["status"] == "pending" and not j1["applied"], "one report applied alone: %s" % j1)
        s, j2, _, _ = http("POST", "/train/text", tr[1], {"text": x["text"], "source": "paste"})
        ensure(j2.get("applied") is True, "second report not applied: %s" % j2)
        n, _, _ = now_(ta, d)
        ensure(n["mode"] == "reported" and n["src"] == "text", "mode %s src %s" % (n["mode"], n["src"]))
        ensure(n["ch"] >= x["station"]["ch"] - 200, "position %s before %s" % (n["ch"], x["station"]))
        return {"text": x["text"], "parsed": j1["parsed"]["station_en"], "km": n["km"],
                "timetable_km_before": ctx["tt_km"], "late_min": j1["parsed"]["late_min"]}

    def checkin():
        d, g = ctx["date"], ctx["g"]
        st = g["expect"]["next_halt"]
        info = next(s for s in ctx["stations"] if s["id"] == st["id"])
        body = {"date": d, "station_id": st["id"], "kind": "reached"}
        s, j1, _, _ = http("POST", "/train/%s/checkin" % NO, tr[0], body)
        ensure(s == 200 and j1["status"] == "pending", "first %s %s" % (s, j1))
        s, j2, _, _ = http("POST", "/train/%s/checkin" % NO, tr[1], body)
        ensure(s == 200 and j2["status"] == "accepted", "second %s %s" % (s, j2))
        far = dict(body, lat=info["lat"] + 0.5, lng=info["lng"], acc=15)
        s, j3, _, _ = http("POST", "/train/%s/checkin" % NO, tr[2], far)
        ensure(j3["status"] == "rejected" and j3.get("reason") == "far_from_station",
               "far %s %s" % (s, j3))
        n, _, _ = now_(ta, d)
        ensure(n.get("checkins", {}).get(st["id"]) == 2, "checkins %s" % n.get("checkins"))
        return {"station": st["en"], "first": j1["status"], "second": j2["status"],
                "far": j3["reason"], "points": j2["points"]}

    for name, fn in (("data", data), ("live", live), ("latency", latency),
                     ("payload", payload), ("outlier", outlier), ("stale", stale),
                     ("predicted", predicted), ("timetable", timetable), ("text", text),
                     ("checkin", checkin)):
        if not run.step(name, fn) and name == "live":
            break
    ok = all(r["ok"] for r in run.steps) and len(run.steps) == 10
    rep = {"ok": ok, "train": NO, "steps": run.steps, "metrics": run.metrics}
    with open(os.path.join(out, "train_e2e.json"), "w", encoding="utf-8") as fh:
        json.dump(rep, fh, ensure_ascii=False, indent=1, default=str)
    md = ["### Train Tracker E2E — API proof (Rangpur Express 771)", "",
          "| step | ok | detail |", "|---|---|---|"]
    for r in run.steps:
        md.append("| %s | %s | %s |" % (r["step"], "✅" if r["ok"] else "❌",
                                        json.dumps(r.get("detail") or r.get("error"),
                                                   ensure_ascii=False, default=str)[:300]
                                        .replace("|", "/")))
    md.append("")
    md.append("metrics: `%s`" % json.dumps(run.metrics, default=str))
    summ = os.environ.get("GITHUB_STEP_SUMMARY")
    if summ:
        with open(summ, "a", encoding="utf-8") as fh:
            fh.write("\n".join(md) + "\n")
    print("\n".join(md))
    return 0 if ok else 1


def _ts(iso):
    from datetime import datetime
    return datetime.fromisoformat(iso).timestamp()


if __name__ == "__main__":
    sys.exit(main())
