#!/usr/bin/env python3
"""nearby (owner 3 Nov 18:50): turn a filtered OpenStreetMap extract into the
small per-country emergency-place files the Assisto server imports.

Runs ONLY in GitHub Actions (.github/workflows/nearby_data.yml) — never on the
server (owner: no data processing on the 7.8 GB box). Steps there:
  1. download one Geofabrik extract (one at a time, monthly);
  2. `osmium tags-filter` keeps only the six emergency categories;
  3. `osmium export -f geojsonseq -a type,id` -> this script `rows`;
  4. after every region: this script `finalize` writes nearby_<CC>.json.gz
     + manifest.json (merged with the previous release's manifest so a partial
     run never drops a country) and the job uploads them as release assets.

Licence: the output is a Derivative Database of OpenStreetMap, offered under
the ODbL 1.0 like the source ("© OpenStreetMap contributors"). Country
assignment uses Natural Earth admin-0 polygons (public domain).

Output row (compact list, same order as FIELDS):
    [osm id ("n123"/"w45"/"r6"), category, name, name_en, lat, lon, phone]
"""
import argparse
import gzip
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

FIELDS = ["id", "cat", "name", "name_en", "lat", "lon", "phone"]
CATEGORIES = ("hospital", "clinic", "pharmacy", "police", "fire", "ambulance")
ATTRIBUTION = "© OpenStreetMap contributors"
LICENCE = "ODbL-1.0 (https://opendatacommons.org/licenses/odbl/1-0/)"
# Places without any name are kept only where the building itself is the
# help (a hospital / police / fire / ambulance station); an unnamed pharmacy
# or clinic is noise in a list.
_KEEP_UNNAMED = {"hospital", "police", "fire", "ambulance"}


def category(tags):
    """OSM tags -> one of CATEGORIES, or None."""
    a = tags.get("amenity") or ""
    h = tags.get("healthcare") or ""
    if a == "hospital" or (h == "hospital" and not a):
        return "hospital"
    if a == "clinic" or (h == "clinic" and not a):
        return "clinic"
    if a == "pharmacy" or (h == "pharmacy" and not a):
        return "pharmacy"
    if a == "police":
        return "police"
    if a == "fire_station":
        return "fire"
    if tags.get("emergency") == "ambulance_station":
        return "ambulance"
    return None


def clean(s, n):
    s = " ".join(str(s or "").split())
    return s[:n]


def phone_of(tags):
    for k in ("phone", "contact:phone", "emergency:phone", "contact:mobile", "mobile"):
        v = tags.get(k)
        if v:
            first = str(v).replace(",", ";").split(";")[0]
            first = "".join(ch for ch in first if ch.isdigit() or ch in "+ -()")
            first = " ".join(first.split())
            if sum(ch.isdigit() for ch in first) >= 3:
                return first[:32]
    return ""


def centroid(geom):
    """A representative point: the point itself, else the mean of the
    (largest) outer ring / line. Good to a few metres for a building."""
    t = geom.get("type")
    c = geom.get("coordinates")
    if not c:
        return None
    if t == "Point":
        return c[0], c[1]
    if t == "LineString":
        pts = c
    elif t == "Polygon":
        pts = c[0]
    elif t == "MultiPolygon":
        pts = max((p[0] for p in c if p and p[0]), key=len, default=None)
    elif t == "MultiLineString":
        pts = max(c, key=len, default=None)
    else:
        return None
    if not pts:
        return None
    if len(pts) > 1 and pts[0] == pts[-1]:
        pts = pts[:-1]
    return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))


def parse_feature(line):
    """One geojsonseq line -> (id, cat, name, name_en, lat, lon, phone) or None."""
    line = line.strip().lstrip("\x1e")
    if not line:
        return None
    try:
        f = json.loads(line)
    except ValueError:
        return None
    tags = f.get("properties") or {}
    cat = category(tags)
    if cat is None:
        return None
    typ = str(tags.get("@type") or "")[:1]
    oid = tags.get("@id")
    if typ not in ("n", "w", "r") or oid is None:
        return None
    pt = centroid(f.get("geometry") or {})
    if pt is None:
        return None
    lon, lat = pt
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    name = clean(tags.get("name"), 160)
    name_en = clean(tags.get("name:en"), 160)
    if name_en == name:
        name_en = ""
    if not name and not name_en and cat not in _KEEP_UNNAMED:
        return None
    return ("%s%s" % (typ, oid), cat, name, name_en,
            round(lat, 6), round(lon, 6), phone_of(tags))


class CountryIndex:
    """Point -> ISO-3166 alpha-2 with Natural Earth admin-0 polygons."""

    def __init__(self, ne_path):
        import shapely
        from shapely.geometry import shape
        from shapely.strtree import STRtree
        with open(ne_path, encoding="utf-8") as fh:
            data = json.load(fh)
        geoms, codes = [], []
        for feat in data["features"]:
            p = feat.get("properties") or {}
            code = ""
            for k in ("ISO_A2_EH", "ISO_A2", "iso_a2", "WB_A2"):
                v = str(p.get(k) or "")
                if len(v) == 2 and v.isalpha() and v.upper() != "XX":
                    code = v.upper()
                    break
            if not code:
                continue
            geoms.append(shape(feat["geometry"]))
            codes.append(code)
        self._shapely = shapely
        self._geoms = geoms
        self._codes = codes
        self._tree = STRtree(geoms)

    def lookup(self, lonlats):
        """[(lon, lat), ...] -> [code or ""]; a coastal point just outside the
        polygons (Natural Earth is ~100 m) takes the nearest one within ~5 km."""
        sh = self._shapely
        pts = sh.points([list(p) for p in lonlats]) if lonlats else []
        out = [""] * len(lonlats)
        if not lonlats:
            return out
        hit = self._tree.query(pts, predicate="intersects")
        for i, g in zip(hit[0], hit[1]):
            if not out[i]:
                out[i] = self._codes[g]
        missing = [i for i, c in enumerate(out) if not c]
        if missing:
            near = self._tree.query_nearest(pts[missing], max_distance=0.05)
            for j, g in zip(near[0], near[1]):
                i = missing[j]
                if not out[i]:
                    out[i] = self._codes[g]
        return out


def cmd_rows(a):
    """geojsonseq -> append rows per kept country to <out>/rows_<CC>.jsonl."""
    keep = set(c.strip().upper() for c in a.countries.split(",") if c.strip())
    idx = CountryIndex(a.ne)
    os.makedirs(a.out, exist_ok=True)
    handles = {}
    stats = {"features": 0, "kept": 0, "other_country": 0}

    def flush(batch):
        codes = idx.lookup([(r[5], r[4]) for r in batch])
        for r, cc in zip(batch, codes):
            if not cc:
                if len(keep) == 1 and "*" not in keep:
                    cc = next(iter(keep))   # single-country extract: border fuzz
                else:
                    stats["other_country"] += 1
                    continue
            if "*" not in keep and cc not in keep:
                stats["other_country"] += 1
                continue
            fh = handles.get(cc)
            if fh is None:
                fh = handles[cc] = open(os.path.join(a.out, "rows_%s.jsonl" % cc), "a",
                                        encoding="utf-8")
            fh.write(json.dumps(list(r), ensure_ascii=False, separators=(",", ":")) + "\n")
            stats["kept"] += 1

    batch = []
    with open(a.geojsonseq, encoding="utf-8") as fh:
        for line in fh:
            r = parse_feature(line)
            if r is None:
                continue
            stats["features"] += 1
            batch.append(r)
            if len(batch) >= 50000:
                flush(batch)
                batch = []
    if batch:
        flush(batch)
    for fh in handles.values():
        fh.close()
    # the region's source line for finalize
    with open(os.path.join(a.out, "regions.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"region": a.region, "osm_timestamp": a.osm_timestamp,
                             "countries": sorted(handles)}) + "\n")
    print("rows %s: %s" % (a.region, json.dumps(stats)))


def cmd_finalize(a):
    """rows_<CC>.jsonl -> nearby_<CC>.json.gz + merged manifest.json."""
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    old = {}
    if a.manifest_in and os.path.exists(a.manifest_in):
        try:
            with open(a.manifest_in, encoding="utf-8") as fh:
                old = json.load(fh) or {}
        except ValueError:
            old = {}
    countries = dict(old.get("countries") or {})
    regions = {}
    rp = os.path.join(a.out, "regions.jsonl")
    if os.path.exists(rp):
        with open(rp, encoding="utf-8") as fh:
            for line in fh:
                r = json.loads(line)
                for cc in r["countries"]:
                    regions.setdefault(cc, r)
    for fn in sorted(os.listdir(a.out)):
        if not (fn.startswith("rows_") and fn.endswith(".jsonl")):
            continue
        cc = fn[5:7]
        seen = {}
        with open(os.path.join(a.out, fn), encoding="utf-8") as fh:
            for line in fh:
                r = json.loads(line)
                seen[r[0]] = r          # dedupe: a place in two extracts once
        rows = sorted(seen.values(), key=lambda r: r[0])
        reg = regions.get(cc) or {}
        doc = {"country": cc, "generated_at": now, "source": "openstreetmap",
               "extract": "https://download.geofabrik.de/%s-latest.osm.pbf" % reg.get("region", ""),
               "osm_timestamp": reg.get("osm_timestamp", ""),
               "attribution": ATTRIBUTION, "licence": LICENCE,
               "fields": FIELDS, "rows": rows}
        raw = json.dumps(doc, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        name = "nearby_%s.json.gz" % cc
        path = os.path.join(a.out, name)
        with open(path, "wb") as fh:
            fh.write(gzip.compress(raw, 9, mtime=0))
        blob = open(path, "rb").read()
        by_cat = {}
        for r in rows:
            by_cat[r[1]] = by_cat.get(r[1], 0) + 1
        countries[cc] = {"file": name, "records": len(rows), "by_category": by_cat,
                         "bytes": len(blob), "sha256": hashlib.sha256(blob).hexdigest(),
                         "generated_at": now, "osm_timestamp": reg.get("osm_timestamp", ""),
                         "region": reg.get("region", "")}
    manifest = {"schema": 1, "updated_at": now, "attribution": ATTRIBUTION,
                "licence": LICENCE, "fields": FIELDS, "countries": countries}
    with open(a.manifest_out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)
    tot_r = sum(c["records"] for c in countries.values())
    tot_b = sum(c["bytes"] for c in countries.values())
    print("finalize: %d countries, %d records, %d bytes" % (len(countries), tot_r, tot_b))
    for cc in sorted(countries):
        c = countries[cc]
        print("  %s %7d records %9d bytes %s" % (cc, c["records"], c["bytes"],
                                                json.dumps(c.get("by_category", {}))))


def main(argv=None):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rows")
    r.add_argument("--geojsonseq", required=True)
    r.add_argument("--countries", required=True)
    r.add_argument("--ne", required=True)
    r.add_argument("--region", required=True)
    r.add_argument("--osm-timestamp", default="")
    r.add_argument("--out", required=True)
    f = sub.add_parser("finalize")
    f.add_argument("--out", required=True)
    f.add_argument("--manifest-in", default="")
    f.add_argument("--manifest-out", required=True)
    a = p.parse_args(argv)
    {"rows": cmd_rows, "finalize": cmd_finalize}[a.cmd](a)
    return 0


if __name__ == "__main__":
    sys.exit(main())
