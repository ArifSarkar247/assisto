"""citydata (owner 9 Nov 11:25): Assisto's own light transit router.

A frequency-based, multi-criteria RAPTOR over our compact GTFS-derived
network (deploy/transit/build_transit.py makes it in GitHub Actions; the
server only imports the small result). No Google, no OTP, no Java: one
process-wide in-memory Network (a few MB for Dhaka) and a query touches only
routes reachable in <= MAX_ROUNDS vehicle legs.

Model
  * Stops and directional route patterns (ordered stop list + cumulative km).
  * No timetables exist for Dhaka buses/legunas, so every pattern has a
    headway (expected wait = headway / 2) and an average speed + dwell.
  * Labels per stop carry (time, fare_low, fare_high, vehicle_legs, walk_m)
    and a parent pointer; per stop we keep a small Pareto set (time, fare,
    legs) so one search yields Fastest, Cheapest and Fewest changes.
  * Access / egress: walk (<= WALK_MAX m) or rickshaw (RICK_MIN..RICK_MAX m).
    Transfers: walking footpaths between stops <= XFER_M apart.
  * Direct ways (CNG, ride share bike / car, rickshaw, walk) are priced from
    fares.py; ride share is only an estimate range — we never call their APIs.
"""
import math
import time as _time

from . import fares as F

WALK_SPEED = 1.2          # m/s (Dhaka footpaths)
DETOUR = 1.3              # straight line -> street distance
WALK_MAX = 1200           # m, access/egress on foot
RICK_MIN, RICK_MAX = 700, 3500
RICK_KMH, CNG_KMH, CAR_KMH, BIKE_KMH = 9.0, 16.0, 15.0, 20.0
XFER_M = 450
MAX_ROUNDS = 4            # vehicle legs
MAX_LABELS = 4            # per stop
CELL = 0.005              # grid cell (deg) ~ 550 m
MODES = ("metro", "bus", "leguna", "water")
DEFAULTS = {"metro": (8, 38.0, 30), "bus": (10, 12.0, 25), "leguna": (10, 14.0, 20),
            "water": (30, 12.0, 60)}
STATUS = {"v": "verified", "r": "reported"}


def hav(a, b, c, d):
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = p2 - p1, math.radians(d - b)
    x = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 12742000.0 * math.asin(min(1.0, math.sqrt(x)))


def _cell(lat, lon):
    return (int(math.floor(lat / CELL)), int(math.floor(lon / CELL)))


def bearing_side(lat0, lon0, lat1, lon1):
    """'N' | 'E' | 'S' | 'W' of point 1 seen from point 0."""
    dy = lat1 - lat0
    dx = (lon1 - lon0) * math.cos(math.radians(lat0))
    if abs(dy) >= abs(dx):
        return "N" if dy >= 0 else "S"
    return "E" if dx >= 0 else "W"


def peak_factor(minute):
    """Dhaka road speed factor by minute of day (lower = slower)."""
    h = (minute // 60) % 24
    if 8 <= h < 11 or 17 <= h < 21:
        return 0.75
    if 22 <= h or h < 6:
        return 1.35
    return 1.0


class Network:
    def __init__(self, net, overrides=None):
        ov = overrides or {}
        self.meta = {k: net.get(k) for k in ("city", "version", "built", "osm_timestamp",
                                             "attribution", "sources", "bbox", "counts")}
        self.rates = F.rates(ov.get("rates"))
        cols = net["stops"]["cols"]
        ix = {c: i for i, c in enumerate(cols)}
        hidden_s = set(ov.get("hide_stops") or ())
        stop_edit = ov.get("stops") or {}
        self.stops = []
        for row in net["stops"]["rows"]:
            s = {"id": row[ix["id"]], "name": row[ix["name"]] or "",
                 "name_bn": row[ix["name_bn"]] or "", "lat": row[ix["lat"]],
                 "lon": row[ix["lon"]], "kind": row[ix["kind"]], "st": row[ix["st"]],
                 "code": row[ix["code"]] if "code" in ix else ""}
            e = stop_edit.get(s["id"])
            if e:
                for k in ("name", "name_bn", "lat", "lon", "st"):
                    if e.get(k) not in (None, ""):
                        s[k] = e[k]
            s["hidden"] = s["id"] in hidden_s
            self.stops.append(s)
        self.by_id = {s["id"]: i for i, s in enumerate(self.stops)}
        hidden_r = set(ov.get("hide_routes") or ())
        route_edit = ov.get("routes") or {}
        self.routes = []
        for r in net["routes"]:
            r = dict(r)
            e = route_edit.get(r["id"])
            if e:
                for k in ("name", "name_bn", "st", "hw", "spd"):
                    if e.get(k) not in (None, ""):
                        r[k] = e[k]
            r["hidden"] = r["id"] in hidden_r
            hw, spd, dwell = DEFAULTS.get(r["mode"], DEFAULTS["bus"])
            r.setdefault("hw", hw)
            r.setdefault("spd", spd)
            r["dwell"] = r.get("dwell", dwell)
            km = r["km"]
            t, acc = [0.0], 0.0
            for i in range(1, len(km)):
                acc += (km[i] - km[i - 1]) * 3600.0 / float(r["spd"]) + r["dwell"]
                t.append(acc)
            r["t"] = t
            self.routes.append(r)
        self.night = {k: float(v) for k, v in (ov.get("night") or {}).items()}
        self.gates = {}
        for g in net.get("gates") or ():
            self.gates.setdefault(g["st"], []).append(g)
        for g in ov.get("gates") or ():           # owner-approved user gate info
            if isinstance(g, dict) and g.get("st") in range(len(self.stops)):
                self.gates.setdefault(g["st"], []).append(g)
        self._index()

    # ---------------------------------------------------------------- index
    def _index(self):
        self.stop_routes = [[] for _ in self.stops]
        for ri, r in enumerate(self.routes):
            if r["hidden"]:
                continue
            for pos, si in enumerate(r["stops"]):
                self.stop_routes[si].append((ri, pos))
        self.grid = {}
        for i, s in enumerate(self.stops):
            if not s["hidden"] and self.stop_routes[i]:
                self.grid.setdefault(_cell(s["lat"], s["lon"]), []).append(i)
        self.foot = [[] for _ in self.stops]
        for i, s in enumerate(self.stops):
            if s["hidden"] or not self.stop_routes[i]:
                continue
            for j, d in self.near(s["lat"], s["lon"], XFER_M):
                if j != i:
                    self.foot[i].append((j, d * DETOUR / WALK_SPEED, int(d * DETOUR)))

    def near(self, lat, lon, radius_m):
        n = int(math.ceil(radius_m / 500.0)) + 1
        c0, c1 = _cell(lat, lon)
        out = []
        for a in range(c0 - n, c0 + n + 1):
            for b in range(c1 - n, c1 + n + 1):
                for i in self.grid.get((a, b), ()):
                    s = self.stops[i]
                    d = hav(lat, lon, s["lat"], s["lon"])
                    if d <= radius_m:
                        out.append((i, d))
        out.sort(key=lambda x: x[1])
        return out

    def covers(self, lat, lon):
        bb = self.meta.get("bbox")
        if not bb:
            return False
        return bb[0] <= lat <= bb[2] and bb[1] <= lon <= bb[3]

    # ---------------------------------------------------------------- legs
    def _first_mile(self, lat, lon, modes):
        """[(stop, seconds, fare_lo, fare_hi, leg)] reachable from a point."""
        out = []
        for i, d in self.near(lat, lon, RICK_MAX):
            if not any(self.routes[ri]["mode"] in modes for ri, _ in self.stop_routes[i]):
                continue
            street = d * DETOUR
            if d <= WALK_MAX:
                out.append((i, street / WALK_SPEED, 0, 0, ("walk", int(street))))
            if d >= RICK_MIN and "rickshaw" in modes:
                f = F.rickshaw(street / 1000.0, self.rates)
                out.append((i, street / (RICK_KMH / 3.6) + 180, f["low"], f["high"],
                            ("rickshaw", int(street))))
        return out

    # ---------------------------------------------------------------- search
    def plan(self, olat, olon, dlat, dlon, minute=None, modes=None, deadline_s=0.45):
        t0 = _time.time()
        if minute is None:
            lt = _time.localtime(_time.time() + 6 * 3600 - (-_time.timezone))
            minute = lt.tm_hour * 60 + lt.tm_min
        modes = set(modes or MODES + ("rickshaw",))
        pf = peak_factor(minute)
        crow = hav(olat, olon, dlat, dlon)
        egress = {}
        for i, sec, flo, fhi, leg in self._first_mile(dlat, dlon, modes):
            cur = egress.get(i)
            egress.setdefault(i, []).append((sec, flo, fhi, leg)) if cur is None else cur.append(
                (sec, flo, fhi, leg))
        # label = (time_s, fare_lo, fare_hi, nveh, parent, leg, route_idx)
        bags = {}
        marked = set()
        for i, sec, flo, fhi, leg in self._first_mile(olat, olon, modes):
            lab = (sec, flo, fhi, 0, None, ("access",) + leg, -1)
            if self._insert(bags, i, lab):
                marked.add(i)
        results = []
        for rnd in range(1, MAX_ROUNDS + 1):
            if not marked or _time.time() - t0 > deadline_s:
                break
            queue = {}
            for si in marked:
                for ri, pos in self.stop_routes[si]:
                    r = self.routes[ri]
                    if r["mode"] not in modes:
                        continue
                    if pos < len(r["stops"]) - 1 and queue.get(ri, 1 << 30) > pos:
                        queue[ri] = pos
            prev = {si: [l for l in bags.get(si, ()) if l[3] == rnd - 1] for si in marked}
            new_marked = set()
            for ri, start in queue.items():
                r = self.routes[ri]
                rs, T, K = r["stops"], r["t"], r["km"]
                wait = r["hw"] * 30.0
                spd_fac = 1.0 if r["mode"] == "metro" else pf
                carried = []      # (dep_time - T[pos], fare_lo, fare_hi, pos, label)
                for pos in range(start, len(rs)):
                    si = rs[pos]
                    if carried:
                        for adj, flo, fhi, bpos, blab in carried:
                            arr = adj + T[bpos] + (T[pos] - T[bpos]) / spd_fac
                            km = K[pos] - K[bpos]
                            f = F.leg_fare(r["mode"], km, 0, self.stops[rs[bpos]]["code"],
                                           self.stops[si]["code"], self.rates)
                            lab = (arr, flo + f["low"], fhi + f["high"], rnd, blab,
                                   ("ride", ri, bpos, pos, f), ri)
                            if self._insert(bags, si, lab):
                                new_marked.add(si)
                    if pos < len(rs) - 1 and si in prev:
                        for l in prev[si]:
                            if l[6] == ri:
                                continue
                            adj = l[0] + wait - T[pos]
                            cand = (adj, l[1], l[2], pos, l)
                            if not any(c[0] <= adj and c[1] <= l[1] for c in carried):
                                carried = [c for c in carried
                                           if not (adj <= c[0] and l[1] <= c[1])] + [cand]
                                if len(carried) > 3:
                                    carried.sort(key=lambda c: c[0])
                                    carried = carried[:3]
            # transfers on foot from stops reached by a vehicle this round
            for si in list(new_marked):
                for l in [l for l in bags.get(si, ()) if l[3] == rnd and l[5][0] == "ride"]:
                    for sj, sec, m in self.foot[si]:
                        lab = (l[0] + sec, l[1], l[2], rnd, l, ("xfer", m), l[6])
                        if self._insert(bags, sj, lab):
                            new_marked.add(sj)
            for si in new_marked:
                for eg in egress.get(si, ()):
                    for l in bags.get(si, ()):
                        if l[3] == rnd:
                            results.append((l[0] + eg[0], l[1] + eg[1], l[2] + eg[2], rnd, l,
                                            ("egress",) + eg[3], si))
            marked = new_marked
        return self._answer(results, olat, olon, dlat, dlon, crow, minute, pf,
                            int((_time.time() - t0) * 1000))

    @staticmethod
    def _insert(bags, si, lab):
        bag = bags.setdefault(si, [])
        t, flo, n = lab[0], lab[1], lab[3]
        for b in bag:
            if b[0] <= t and b[1] <= flo and b[3] <= n:
                return False
        bag[:] = [b for b in bag if not (t <= b[0] and flo <= b[1] and n <= b[3])]
        bag.append(lab)
        if len(bag) > MAX_LABELS:
            bag.sort(key=lambda b: (b[0], b[1]))
            fast, cheap = bag[0], min(bag, key=lambda b: (b[1], b[0]))
            few = min(bag, key=lambda b: (b[3], b[0]))
            keep = []
            for b in [fast, cheap, few] + bag:
                if b not in keep:
                    keep.append(b)
            bag[:] = keep[:MAX_LABELS]
        return lab in bag

    # ---------------------------------------------------------------- output
    def _pt(self, si):
        s = self.stops[si]
        return {"id": s["id"], "name": s["name"], "name_bn": s["name_bn"],
                "lat": round(s["lat"], 6), "lon": round(s["lon"], 6),
                "status": STATUS.get(s["st"], "reported")}

    def best_gate(self, si, lat, lon):
        gs = self.gates.get(si) or []
        if not gs:
            return None
        g = min(gs, key=lambda g: hav(g["lat"], g["lon"], lat, lon))
        return {k: g.get(k) for k in ("ref", "name", "name_bn", "side", "lat", "lon", "near",
                                      "status")}

    def _legs(self, res, olat, olon, dlat, dlon):
        chain = []
        lab = res
        while lab is not None:
            chain.append(lab)
            lab = lab[4]
        chain.reverse()
        legs = []
        for k, l in enumerate(chain):
            leg = l[5]
            kind = leg[0]
            if kind in ("access", "egress"):
                mode, meters = leg[1], leg[2]
                if kind == "access":
                    nxt = chain[k + 1] if k + 1 < len(chain) else None
                    to_si = self.routes[nxt[5][1]]["stops"][nxt[5][2]] if nxt and nxt[5][0] == "ride" else None
                    a = {"name": "", "lat": olat, "lon": olon, "here": True}
                    b = self._pt(to_si) if to_si is not None else {"lat": dlat, "lon": dlon}
                else:
                    a = self._pt(l[6])
                    b = {"name": "", "lat": dlat, "lon": dlon, "dest": True}
                legs.append(self._simple_leg(mode, meters, a, b))
            elif kind == "xfer":
                prev_si = self.routes[chain[k - 1][5][1]]["stops"][chain[k - 1][5][3]]
                nxt = chain[k + 1] if k + 1 < len(chain) else None
                to_si = (self.routes[nxt[5][1]]["stops"][nxt[5][2]]
                         if nxt and nxt[5][0] == "ride" else None)
                if to_si is None:     # walked to a stop then egress from there
                    to_si = self._xfer_target(chain, k)
                legs.append(self._simple_leg("walk", leg[1], self._pt(prev_si),
                                             self._pt(to_si) if to_si is not None else {}))
            elif kind == "ride":
                _, ri, bpos, apos, f = leg
                r = self.routes[ri]
                rs = r["stops"]
                ride_s = (r["t"][apos] - r["t"][bpos])
                legs.append({
                    "mode": r["mode"], "route_id": r["id"], "route": r.get("name") or r.get("ref"),
                    "route_bn": r.get("name_bn") or "", "ref": r.get("ref") or "",
                    "status": STATUS.get(r.get("st"), "reported"), "source": r.get("src", ""),
                    "board": self._pt(rs[bpos]), "alight": self._pt(rs[apos]),
                    "towards": self._pt(rs[-1]), "stops": apos - bpos,
                    "via": [self.stops[s]["name"] for s in rs[bpos + 1:apos]][:12],
                    "via_bn": [self.stops[s]["name_bn"] for s in rs[bpos + 1:apos]][:12],
                    "wait_min": int(round(r["hw"] / 2.0)), "minutes": int(round(ride_s / 60.0)),
                    "km": round(r["km"][apos] - r["km"][bpos], 1), "fare": f,
                    "headway_min": r["hw"],
                })
        # which exit gate after a metro ride
        for idx, lg in enumerate(legs):
            if lg["mode"] == "metro":
                nxt = legs[idx + 1] if idx + 1 < len(legs) else None
                tgt = (nxt.get("to") or nxt.get("board") or {}) if nxt else {}
                if nxt and nxt["mode"] in ("bus", "leguna", "metro"):
                    tgt = nxt["board"]
                lat, lon = tgt.get("lat", dlat), tgt.get("lon", dlon)
                si = self.by_id.get(lg["alight"]["id"])
                lg["exit_gate"] = self.best_gate(si, lat, lon) if si is not None else None
        return legs

    def _xfer_target(self, chain, k):
        # the stop the transfer label sits on = the egress label's stop
        for l in chain[k + 1:]:
            if l[5][0] == "egress":
                return l[6]
        return None

    def _simple_leg(self, mode, meters, a, b):
        km = meters / 1000.0
        if mode == "walk":
            mins = meters / WALK_SPEED / 60.0
            fare = None
        else:
            mins = meters / (RICK_KMH / 3.6) / 60.0 + 3
            fare = F.rickshaw(km, self.rates)
        return {"mode": mode, "meters": int(meters), "minutes": max(1, int(round(mins))),
                "from": a, "to": b, "fare": fare}

    def _direct(self, crow, minute, pf):
        street = crow * 1.35
        km = street / 1000.0
        out = []
        if crow <= 2000:
            out.append(("walk", street / WALK_SPEED, None))
        if crow <= 5000:
            out.append(("rickshaw", street / (RICK_KMH * pf / 3.6) + 180, F.rickshaw(km, self.rates)))
        if crow >= 800:
            cmin = street / (CNG_KMH * pf / 3.6) / 60.0
            out.append(("cng", cmin * 60 + 300, F.cng(km, cmin, self.rates)))
            bmin = street / (BIKE_KMH * pf / 3.6) / 60.0
            out.append(("ride_bike", bmin * 60 + 360, F.ride("bike", km, bmin, self.rates)))
            vmin = street / (CAR_KMH * pf / 3.6) / 60.0
            out.append(("ride_car", vmin * 60 + 480, F.ride("car", km, vmin, self.rates)))
        return [{"mode": m, "minutes": max(1, int(round(sec / 60.0))), "km": round(km, 1),
                 "fare": f} for m, sec, f in out]

    def _option(self, res, olat, olon, dlat, dlon):
        legs = self._legs(res, olat, olon, dlat, dlon)
        veh = [l for l in legs if l["mode"] in MODES]
        walk_m = sum(l.get("meters", 0) for l in legs if l["mode"] == "walk")
        labels = sorted({(l.get("fare") or {}).get("label") for l in legs if l.get("fare")})
        return {
            "minutes": int(round(res[0] / 60.0)),
            "fare": {"low": int(res[1]), "high": int(res[2]),
                     "label": "official" if labels == ["official"] else
                     ("estimate" if labels == ["estimate"] else "mixed")},
            "changes": max(0, len(veh) - 1), "walk_m": int(walk_m),
            "modes": [l["mode"] for l in legs],
            "status": "verified" if veh and all(l["status"] == "verified" for l in veh)
            else "reported",
            "legs": legs,
        }

    def _night_cost(self, o):
        cost = o["minutes"] + o["walk_m"] / 40.0
        for l in o["legs"]:
            if l["mode"] == "rickshaw":
                cost += 12
            if l["mode"] in ("bus", "leguna", "water"):
                cost += 6 + (4 if l["status"] != "verified" else 0)
                rating = self.night.get(l.get("route_id"))
                if rating:
                    cost += (3.0 - rating) * 6     # 1..5 stars, 3 = neutral
        return cost

    def _answer(self, results, olat, olon, dlat, dlon, crow, minute, pf, ms):
        # drop journeys that ride a vehicle for a trivially short hop
        res = [r for r in results if r[0] > 0]
        options = {}
        if res:
            fastest = min(res, key=lambda r: (r[0], r[2]))
            cap = fastest[0] * 1.6 + 20 * 60
            ok = [r for r in res if r[0] <= cap]
            cheapest = min(ok, key=lambda r: (r[2], r[1], r[0]))
            fewest = min(ok, key=lambda r: (r[3], r[0], r[2]))
            for k, r in (("fastest", fastest), ("cheapest", cheapest), ("fewest_changes", fewest)):
                options[k] = self._option(r, olat, olon, dlat, dlon)
            # Safer at night: metro first, little walking, no rickshaw legs,
            # Verified routes, and users' night safety ratings per route.
            pool = sorted(ok, key=lambda r: r[0])[:12]
            cand = [self._option(r, olat, olon, dlat, dlon) for r in pool]
            options["safer_night"] = min(cand, key=self._night_cost)
        direct = self._direct(crow, minute, pf)
        warn = []
        if any(l["mode"] == "metro" for o in options.values() for l in o["legs"]):
            h = minute // 60
            if h < 7 or h >= 21:
                warn.append("metro_hours")
        return {"ok": bool(options), "options": options, "other_ways": direct,
                "crow_km": round(crow / 1000.0, 2), "warnings": warn, "ms": ms,
                "fare_sources": F.sources(self.rates)}

    # ---------------------------------------------------------------- guides
    def stations(self):
        out = []
        for i, s in enumerate(self.stops):
            if s["kind"] == "metro" and not s["hidden"]:
                p = self._pt(i)
                p["code"] = s["code"]
                p["gates"] = len(self.gates.get(i) or ())
                out.append(p)
        order = {}
        for r in self.routes:
            if r["mode"] == "metro" and not r["hidden"]:
                for k, si in enumerate(r["stops"]):
                    order.setdefault(self.stops[si]["id"], k)
                break
        out.sort(key=lambda p: order.get(p["id"], 999))
        return out

    def station_guide(self, stop_id, lat=None, lon=None):
        si = self.by_id.get(stop_id)
        if si is None or self.stops[si]["kind"] != "metro":
            return None
        s = self._pt(si)
        s["code"] = self.stops[si]["code"]
        gates = []
        for g in self.gates.get(si) or ():
            gg = {k: g.get(k) for k in ("ref", "name", "name_bn", "side", "lat", "lon", "near",
                                        "status")}
            gg["stands"] = [self._pt(x) for x in g.get("stands") or ()]
            gg["buses"] = sorted({(self.routes[x].get("name") or self.routes[x].get("ref") or "")
                                  for x in g.get("routes") or () if not self.routes[x]["hidden"]})
            gates.append(gg)
        gates.sort(key=lambda g: str(g.get("ref") or ""))
        best = self.best_gate(si, lat, lon) if lat is not None and lon is not None else None
        # connecting buses near the station even when gates are not mapped
        buses = set()
        for j, _d in self.near(s["lat"], s["lon"], 350):
            for ri, _p in self.stop_routes[j]:
                r = self.routes[ri]
                if r["mode"] != "metro":
                    buses.add(r.get("name") or r.get("ref") or "")
        return {"station": s, "gates": gates, "which_gate": best,
                "connecting_buses": sorted(b for b in buses if b)[:40]}
