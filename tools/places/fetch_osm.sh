#!/usr/bin/env bash
# qjourney + sjstart2: download the raw OpenStreetMap layers for Assisto's
# free Bangladesh place list (ODbL). Runs in GitHub Actions only
# (.github/workflows/bd_places.yml), never on the server.
# Usage: fetch_osm.sh <empty-out-dir>; then
#   python3 -I tools/places/build_bd_places.py <out-dir> backend/core/data/bd_places.json
# sjstart2: the heavy layers (admin 7-10 for unions, villages for union
# matching, hospitals) are split BY DIVISION so no Overpass query times out.
set -uo pipefail
OUT=${1:?out dir}
mkdir -p "$OUT"
MIRRORS=(https://overpass-api.de/api/interpreter https://overpass.kumi.systems/api/interpreter)
UA="AssistoPlaceList/1.1 (+https://lifeassisto.com)"
FAILED=0
# q <file> <set> <body>: <set> is the area clause: bd (whole country) or an
# Overpass area id (one division)
q() {
  local f="$OUT/$1.json" area body
  [ -s "$f" ] && return 0
  if [ "$2" = bd ]; then
    area='area["ISO3166-1"="BD"][admin_level=2]->.a;'
  else
    area="area($2)->.a;"
  fi
  body="[out:json][timeout:600];${area}($3);out center tags;"
  for try in 1 2 3; do
    for api in "${MIRRORS[@]}"; do
      if curl -sS --fail -A "$UA" --max-time 700 --data-urlencode "data=$body" "$api" -o "$f.tmp" \
         && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "elements" in d and "remark" not in d, d.get("remark")' "$f.tmp"; then
        mv "$f.tmp" "$f"
        echo "ok $1 ($(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["elements"]))' "$f") elements)"
        sleep 5
        return 0
      fi
      echo "retry $1 via $api (try $try)" >&2
      sleep $((20 * try))
    done
  done
  rm -f "$f.tmp"
  echo "FAILED layer $1" >&2
  FAILED=$((FAILED + 1))
}
q admin4 bd 'rel(area.a)["boundary"="administrative"]["admin_level"="4"];'
q admin5 bd 'rel(area.a)["boundary"="administrative"]["admin_level"="5"];'
q admin6 bd 'rel(area.a)["boundary"="administrative"]["admin_level"="6"];'
q places bd 'node(area.a)["place"~"^(city|town|suburb|quarter|neighbourhood)$"]["name"];'
q rail bd 'nwr(area.a)["railway"~"^(station|halt)$"]["name"];'
q bus bd 'nwr(area.a)["amenity"="bus_station"]["name"];'
q air bd 'nwr(area.a)["aeroway"="aerodrome"]["name"];'
q ferry bd 'nwr(area.a)["amenity"="ferry_terminal"]["name"];'
q uni bd 'nwr(area.a)["amenity"~"^(university|college)$"]["name"];'
q metro bd 'nwr(area.a)["station"="subway"]["name"];'
# per division: Overpass area id = 3600000000 + relation id
DIVS=$(python3 -I -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(str(3600000000+e["id"]) for e in d.get("elements",[]) if e.get("type")=="relation"))' "$OUT/admin4.json" 2>/dev/null || true)
echo "divisions: $DIVS"
for a in $DIVS; do
  q "unions_$a" "$a" 'rel(area.a)["boundary"="administrative"]["admin_level"~"^(7|8|9|10)$"];'
  q "villages_$a" "$a" 'node(area.a)["place"~"^(village|hamlet|locality)$"]["name"];'
  q "hosp_$a" "$a" 'nwr(area.a)["amenity"="hospital"]["name"];nwr(area.a)["healthcare"="hospital"]["name"];'
done
ls -la "$OUT"
echo "failed layers: $FAILED"
