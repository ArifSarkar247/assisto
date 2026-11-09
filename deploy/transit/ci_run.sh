#!/usr/bin/env bash
# citydata (owner 9 Nov 11:45): GitHub Actions only — never on the server.
# One Geofabrik download (Bangladesh), cut to small city boxes, polite public
# crawl, build the compact network + GTFS + directory + report per city.
set -euo pipefail
WORK="${1:-$PWD/transit_work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$WORK/out"
mkdir -p "$WORK" "$OUT"
UA="AssistoTransitData/1.0 (+https://lifeassisto.com; monthly)"
URL="https://download.geofabrik.de/asia/bangladesh-latest.osm.pbf"
curl -fL --retry 3 --retry-delay 30 -A "$UA" -o "$WORK/bd.osm.pbf" "$URL"
TS="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$WORK/bd.osm.pbf" 2>/dev/null || true)"
echo "osm timestamp: $TS"
declare -A BOX=( [dhaka]="90.30,23.66,90.52,23.95" [chattogram]="91.70,22.20,91.95,22.45" )
for city in dhaka chattogram; do
  osmium extract --overwrite -s smart -b "${BOX[$city]}" -o "$WORK/$city.osm.pbf" "$WORK/bd.osm.pbf"
  ls -la "$WORK/$city.osm.pbf"
  python3 -I "$HERE/crawl_public.py" --city "$city" --out "$WORK" || echo "crawl $city failed (non-fatal)"
  python3 -I "$HERE/build_transit.py" --city "$city" --pbf "$WORK/$city.osm.pbf" \
    --public "$WORK/public_$city.json" --out "$OUT" --osm-timestamp "$TS"
  cp "$WORK/public_$city.json" "$OUT/public_$city.json" 2>/dev/null || true
done
rm -f "$WORK/bd.osm.pbf"
python3 -I - "$OUT" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
man = {"files": {}}
for f in sorted(os.listdir(out)):
    if f.startswith(("transit_", "directory_")):
        b = open(os.path.join(out, f), "rb").read()
        man["files"][f] = {"sha256": hashlib.sha256(b).hexdigest(), "bytes": len(b)}
for f in sorted(os.listdir(out)):
    if f.startswith("report_"):
        r = json.load(open(os.path.join(out, f)))
        man.setdefault("cities", {})[r["city"]] = {"version": r["version"], "counts": r["counts"],
                                                    "top50": {k: r.get("top50", {}).get(k) for k in ("pass", "total", "p95_ms")}}
json.dump(man, open(os.path.join(out, "manifest.json"), "w"), indent=1)
print(json.dumps(man, indent=1)[:3000])
PY
du -ch "$OUT"/* | tail -1
