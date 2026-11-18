"""gap-city: a tiny MADE-UP Dhaka transit sample for CI only (seed_reality
-> the emulator City Service flow). Public landmark names, rounded sample
coordinates, no real user data. Never imported on the live server: the real
dataset comes from the transit-data release (city_tick)."""
import gzip
import json

from . import city_service as CS


def sample_net(version="ci-sample-1"):
    stops = [
        ["mrt6-UTN", "Uttara North", "উত্তরা উত্তর", 23.8690, 90.3670, "metro", "v", "UTN"],
        ["mrt6-AGA", "Agargaon", "আগারগাঁও", 23.7780, 90.3800, "metro", "v", "AGA"],
        ["mrt6-FAR", "Farmgate", "ফার্মগেট", 23.7580, 90.3900, "metro", "v", "FAR"],
        ["mrt6-SHB", "Shahbag", "শাহবাগ", 23.7390, 90.3960, "metro", "v", "SHB"],
        ["mrt6-MOT", "Motijheel", "মতিঝিল", 23.7280, 90.4190, "metro", "v", "MOT"],
        ["n1", "Farmgate", "ফার্মগেট", 23.7572, 90.3902, "bus", "v", ""],
        ["n2", "Karwan Bazar", "কারওয়ান বাজার", 23.7510, 90.3930, "bus", "r", ""],
        ["n3", "Shahbag", "শাহবাগ", 23.7385, 90.3955, "bus", "v", ""],
        ["n4", "Paltan", "পল্টন", 23.7340, 90.4120, "bus", "r", ""],
        ["n5", "Motijheel", "মতিঝিল", 23.7332, 90.4175, "bus", "v", ""],
    ]
    ix = {s[0]: i for i, s in enumerate(stops)}

    def r(rid, mode, name, ids, km, st="r", **kw):
        d = {"id": rid, "mode": mode, "name": name, "name_bn": "", "ref": "", "op": name, "st": st,
             "src": [{"s": "ci-sample"}], "stops": [ix[x] for x in ids], "km": km}
        d.update(kw)
        return d

    routes = [
        r("mrt6-a", "metro", "MRT Line 6", ["mrt6-UTN", "mrt6-AGA", "mrt6-FAR", "mrt6-SHB", "mrt6-MOT"],
          [0, 11.73, 14.0, 16.4, 20.1], "v", hw=8, spd=38.0, dwell=30),
        r("mrt6-b", "metro", "MRT Line 6", ["mrt6-MOT", "mrt6-SHB", "mrt6-FAR", "mrt6-AGA", "mrt6-UTN"],
          [0, 3.7, 6.1, 8.37, 20.1], "v", hw=8, spd=38.0, dwell=30),
        r("busA-a", "bus", "Sample Paribahan", ["n1", "n2", "n3", "n4", "n5"], [0, 0.9, 2.4, 4.2, 4.9], "v"),
        r("busA-b", "bus", "Sample Paribahan", ["n5", "n4", "n3", "n2", "n1"], [0, 0.7, 2.5, 4.0, 4.9], "v"),
    ]
    gates = [
        {"st": ix["mrt6-MOT"], "ref": "A", "name": "Gate A", "name_bn": "গেট এ", "lat": 23.7286,
         "lon": 90.4200, "side": "E", "near": [["Sample Square", "নমুনা চত্বর", "landmark", 80]],
         "stands": [ix["n5"]], "routes": [2, 3], "lift": True, "status": "reported"},
    ]
    return {"fmt": 1, "city": "dhaka", "version": version, "built": "2026-11-17T00:00:00Z",
            "osm_timestamp": "2026-11-16T00:00:00Z", "attribution": CS.ATTRIBUTION,
            "bbox": [23.66, 90.30, 23.95, 90.52],
            "stops": {"cols": ["id", "name", "name_bn", "lat", "lon", "kind", "st", "code"], "rows": stops},
            "routes": routes, "gates": gates,
            "metro": {"line": {"name": "MRT Line 6"}, "service": {"hours_fri": "15:00-21:40"},
                      "recharge": {"text_en": "At every station (sample)"}},
            "counts": {"routes": len(routes), "stops": len(stops), "stations": 5, "coverage_pct": 1.0}}


def sample_dir():
    return {"items": [
        {"id": "o-ci-passport", "kind": "office", "name": "Sample Passport Office",
         "name_bn": "নমুনা পাসপোর্ট অফিস", "lat": 23.7787, "lon": 90.3790, "address": "Agargaon (sample)",
         "hours": "Sun-Thu 09:00-17:00", "papers_en": ["NID card"], "papers_bn": ["জাতীয় পরিচয়পত্র"],
         "status": "r", "sources": [{"s": "ci-sample"}]},
        {"id": "t-ci-terminal", "kind": "terminal", "name": "Sample Bus Terminal",
         "name_bn": "নমুনা বাস টার্মিনাল", "lat": 23.7330, "lon": 90.4180, "routes": ["Chattogram"],
         "routes_bn": ["চট্টগ্রাম"], "status": "r", "sources": [{"s": "ci-sample"}]},
    ]}


def import_sample():
    """CI only (seed_reality refuses any real database before this runs)."""
    blob = gzip.compress(json.dumps(sample_net()).encode())
    dirs = gzip.compress(json.dumps(sample_dir()).encode())
    return CS.import_city("dhaka", blob, dirs, {"ci_sample": True})
