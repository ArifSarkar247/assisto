#!/usr/bin/env python3
"""sjalarm: SYNTHETIC GPS traces for the destination-alarm CI replay
(app/test/dest_trace_replay_test.dart). Owner order 3 Nov, Card 2 PROOF.

These are NOT real trips. Every file says "synthetic": true and its note
starts with "SYNTHETIC". They exist so CI checks the decision code against
realistic phone behaviour (1 Hz fixes, 5-20 m accuracy with drifting error,
urban-canyon bursts, missing Doppler speed, traffic jams, dwell at stops, a
bus that does not stop, a tunnel-like GPS gap) until the owner records real
traces with the in-app trip recorder (owner-only) — real files go next to
these as real_<mode>_<date>.json and replace nothing.

Deterministic (fixed seeds): re-running produces identical files.
Usage: python3 tools/train/make_synthetic_traces.py [out_dir]
"""
import json
import math
import os
import random
import sys
from datetime import datetime, timedelta, timezone

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "..", "app", "test", "testdata", "dest_traces")
R = 6371000.0


def hav(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(h)))


class Path:
    def __init__(self, pts):
        self.pts = pts
        self.cum = [0.0]
        for i in range(1, len(pts)):
            self.cum.append(self.cum[-1] + hav(pts[i - 1], pts[i]))
        self.length = self.cum[-1]

    def at(self, s):
        s = max(0.0, min(self.length, s))
        for i in range(1, len(self.pts)):
            if s <= self.cum[i]:
                seg = self.cum[i] - self.cum[i - 1] or 1.0
                f = (s - self.cum[i - 1]) / seg
                a, b = self.pts[i - 1], self.pts[i]
                return (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]))
        return self.pts[-1]

    def chainage_of(self, p):
        best, bs = 1e18, 0.0
        s = 0.0
        while s <= self.length:
            d = hav(self.at(s), p)
            if d < best:
                best, bs = d, s
            s += 5.0
        return bs


def simulate(rng, path, target_s, cruise, *, dwell_at=(), jams=(), stops_at_target=True,
             accel=1.0, decel=1.2, after_s=60, canyon=(), gaps=(), doppler=True,
             acc_range=(6, 18), start=None, start_s=0.0):
    """1 Hz kinematics along [path]: cruise speed with slow random variation,
    dwell at (chainage, seconds) stops, jams (from_s, to_s, seconds, crawl
    m/s), braking to stop at the target (or driving through it)."""
    t0 = start or datetime(2026, 11, 1, 2, 0, 0, tzinfo=timezone.utc)
    s, v, t = start_s, 0.0, 0
    pts = []
    ox = oy = 0.0
    acc = (acc_range[0] + acc_range[1]) / 2
    dwell = {round(c): d for c, d in dwell_at}
    dwelled = set()
    jam_left = {i: j[2] for i, j in enumerate(jams)}
    cruise_now = cruise
    end_s = min(path.length, target_s + (0 if stops_at_target else 400))
    post = 0
    waiting = 0
    while True:
        t += 1
        if t % 20 == 0:
            cruise_now = max(0.5, cruise * rng.uniform(0.75, 1.15))
        want = cruise_now
        for i, (a, b, secs, crawl) in enumerate(jams):
            if a <= s <= b and jam_left[i] > 0:
                want = crawl if rng.random() < 0.5 else 0.0
                jam_left[i] -= 1
        # brake for dwell stops and the target
        for c, d in dwell.items():
            if c not in dwelled and 0 <= c - s:
                want = min(want, max(0.7, math.sqrt(2 * decel * (c - s))))
        if stops_at_target:
            want = min(want, max(0.7, math.sqrt(2 * decel * max(0.0, target_s - s))))
        if waiting > 0:
            waiting -= 1
            want = 0.0
            if waiting == 0:
                v = 0.0
        if want > v:
            v = min(want, v + accel)
        else:
            v = max(want, v - decel)
        for c, d in dwell.items():
            if c not in dwelled and abs(c - s) < 4:
                dwelled.add(c)
                waiting = d
        s += v
        if stops_at_target and s >= target_s - 1.5:
            s = target_s
            v = 0.0
        if s >= end_s or (stops_at_target and s >= target_s):
            post += 1
            if post > after_s:
                break
        if t > 4 * 3600:
            break
        # GPS: slowly varying accuracy, AR(1) drifting error, canyon bursts
        acc = min(acc_range[1], max(acc_range[0], acc + rng.gauss(0, 0.8)))
        a_now = acc
        if any(a <= s <= b for a, b in canyon):
            a_now = rng.uniform(25, 45)
        sig = a_now / 2.0
        ox = 0.9 * ox + rng.gauss(0, sig * math.sqrt(1 - 0.81))
        oy = 0.9 * oy + rng.gauss(0, sig * math.sqrt(1 - 0.81))
        if any(a <= s <= b for a, b in gaps):
            continue  # no fix (tunnel / covered platform / phone dozing)
        lat, lng = path.at(s)
        lat += oy / 111320.0
        lng += ox / (111320.0 * math.cos(math.radians(lat)))
        sp = None
        if doppler:
            sp = round(max(0.0, v + rng.gauss(0, 0.3)), 2)
        pts.append({"t": (t0 + timedelta(seconds=t)).isoformat().replace("+00:00", "Z"),
                    "lat": round(lat, 7), "lng": round(lng, 7), "acc": round(a_now, 1),
                    "speed": sp})
    return pts


def write(name, mode, note, path, target_s, set_m, pts, stop_name, min_lead, max_lead):
    tlat, tlng = path.at(target_s)
    doc = {
        "format": "assisto-trip-trace/1",
        "synthetic": True,
        "note": "SYNTHETIC — generated by tools/train/make_synthetic_traces.py (fixed seed); "
                "not a real trip. " + note,
        "mode": mode, "set_m": set_m,
        "stop": {"name": stop_name, "lat": round(tlat, 7), "lng": round(tlng, 7)},
        "expect": {"min_lead_s": min_lead, "max_lead_s": max_lead},
        "points": pts,
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, name), "w") as f:
        json.dump(doc, f, ensure_ascii=False, separators=(",", ":"))
    print(name, len(pts), "points", round(path.length), "m")


def main():
    # 1) Dhaka local bus Farmgate -> Shahbag: dwell at Karwan Bazar, jam at
    #    Bangla Motor, stops at Shahbag. Setting 10 m (city bus default).
    p = Path([(23.7580, 90.3897), (23.7540, 90.3912), (23.7509, 90.3925), (23.7465, 90.3945),
              (23.7420, 90.3953), (23.7385, 90.3960), (23.7350, 90.3965)])
    tgt = p.chainage_of((23.7385, 90.3960))
    rng = random.Random(301)
    pts = simulate(rng, p, tgt, 8.0, dwell_at=[(p.chainage_of((23.7509, 90.3925)), 40)],
                   jams=[(p.chainage_of((23.7470, 90.3943)), p.chainage_of((23.7440, 90.3950)), 180, 1.5)],
                   canyon=[(p.chainage_of((23.7509, 90.3925)) - 80, p.chainage_of((23.7509, 90.3925)) + 120)])
    write("synthetic_dhaka_local_bus_farmgate_shahbag.json", "cityBus",
          "Dhaka local bus, stop-and-go, Karwan Bazar dwell, Bangla Motor jam, stops at Shahbag.",
          p, tgt, 10, pts, "Shahbag", 20, 300)

    # 2) Bus that does NOT stop at your stop, no Doppler speed from the phone
    #    (speed from positions only). Mohakhali -> Kakoli -> on.
    p = Path([(23.7778, 90.4005), (23.7840, 90.4018), (23.7900, 90.4030), (23.7950, 90.4040),
              (23.8000, 90.4052), (23.8040, 90.4065)])
    tgt = p.chainage_of((23.7950, 90.4040))
    rng = random.Random(302)
    pts = simulate(rng, p, tgt, 11.0, stops_at_target=False, doppler=False)
    write("synthetic_dhaka_bus_passes_stop_no_doppler.json", "cityBus",
          "Dhaka bus drives through Kakoli at ~40 km/h without stopping; phone gives no speed.",
          p, tgt, 10, pts, "Kakoli", 20, 300)

    # 3) Stuck in a jam 400 m before the stop for 6 minutes with noisy
    #    fixes (25-35 m accuracy): the speed rule must NOT ring from jitter.
    p = Path([(23.7300, 90.4100), (23.7330, 90.4140), (23.7360, 90.4175), (23.7390, 90.4205)])
    tgt = p.chainage_of((23.7390, 90.4205))
    jam_at = tgt - 400
    rng = random.Random(303)
    pts = simulate(rng, p, tgt, 7.0, jams=[(jam_at, jam_at + 60, 360, 0.0)],
                   canyon=[(jam_at - 30, jam_at + 40)], start_s=0.0)
    write("synthetic_dhaka_jam_jitter.json", "cityBus",
          "6-minute standstill 400 m before the stop with 25-45 m GPS jitter; must not ring "
          "during the jam (max lead 240 s), must ring before the stop.",
          p, tgt, 10, pts, "Motijheel", 20, 240)

    # 4) Long-distance bus Daudkandi -> Cumilla, ~80 km/h, setting 2 km.
    p = Path([(23.5310, 90.7210), (23.5050, 90.8300), (23.4850, 90.9800), (23.4400, 91.1300),
              (23.4560, 91.1800)])
    tgt = p.length - 150
    rng = random.Random(304)
    pts = simulate(rng, p, tgt, 22.0, accel=0.8, decel=1.0)
    write("synthetic_long_distance_bus_daudkandi_cumilla.json", "longBus",
          "Dhaka-Chattogram highway coach, 70-90 km/h, setting 2 km (long-distance default).",
          p, tgt, 2000, pts, "Cumilla", 60, 600)

    # 5) Train Joydebpur -> Tongi (dwell) -> Dhaka Airport station, with a
    #    40 s GPS gap (no fix) 1.5 km before the station; setting 2 km.
    p = Path([(23.9987, 90.4200), (23.9500, 90.4130), (23.8960, 90.4060), (23.8700, 90.4070),
              (23.8521, 90.4084), (23.8400, 90.4090)])
    tgt = p.chainage_of((23.8521, 90.4084))
    rng = random.Random(305)
    pts = simulate(rng, p, tgt, 17.0, accel=0.5, decel=0.7,
                   dwell_at=[(p.chainage_of((23.8960, 90.4060)), 120)],
                   gaps=[(tgt - 1600, tgt - 1000)])
    write("synthetic_train_joydebpur_airport.json", "train",
          "Intercity train, Tongi dwell 2 min, GPS gap near the platform roof, setting 2 km.",
          p, tgt, 2000, pts, "Dhaka Airport", 60, 600)

    # 6) Walking in Dhanmondi, preset 100 m.
    p = Path([(23.7562, 90.3740), (23.7530, 90.3755), (23.7500, 90.3770), (23.7480, 90.3785)])
    tgt = p.chainage_of((23.7500, 90.3770))
    rng = random.Random(306)
    pts = simulate(rng, p, tgt, 1.3, accel=0.5, decel=0.8, acc_range=(5, 15))
    write("synthetic_walking_dhanmondi.json", "walking",
          "Walking 1.3 m/s, preset 100 m.", p, tgt, 100, pts, "Dhanmondi Lake", 30, 300)


if __name__ == "__main__":
    main()
