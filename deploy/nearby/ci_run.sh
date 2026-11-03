#!/usr/bin/env bash
# nearby (owner 3 Nov 18:50): GitHub Actions only — never on the server.
# Usage: ci_run.sh <set> <workdir>
#   set = rollout | world | comma list of rollout codes (BD,SA,...)
# One Geofabrik download at a time with a pause between (their guidance: no
# parallel downloads, do not re-download unchanged files; we run monthly).
set -euo pipefail
SET="${1:-rollout}"
WORK="${2:-$PWD/nearby_work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/regions.json"
BASE="$(jq -r .geofabrik "$CFG")"
OUT="$WORK/out"
mkdir -p "$WORK" "$OUT"
UA="AssistoNearbyData/1.0 (+https://lifeassisto.com; monthly, sequential)"

case "$SET" in
  rollout) jq -c '.rollout[]' "$CFG" > "$WORK/plan.jsonl" ;;
  world)   jq -c '.world[]' "$CFG" > "$WORK/plan.jsonl" ;;
  *)       codes="$(echo "$SET" | tr 'a-z' 'A-Z' | jq -R 'split(",")')"
           jq -c --argjson want "$codes" \
             '.rollout[] | .countries as $c | ($c - ($c - $want)) as $hit
              | select($hit | length > 0) | .countries = $hit' \
             "$CFG" > "$WORK/plan.jsonl" ;;
esac
echo "plan:"; cat "$WORK/plan.jsonl"

first=1
while read -r item; do
  region="$(echo "$item" | jq -r .region)"
  countries="$(echo "$item" | jq -r '.countries | join(",")')"
  url="${BASE}${region}-latest.osm.pbf"
  [ "$first" = 1 ] || sleep 30
  first=0
  size="$(curl -fsSIL -A "$UA" "$url" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1)"
  size="${size:-0}"
  free="$(df --output=avail -B1 "$WORK" | tail -1)"
  need=$(( size + size / 3 + 2000000000 ))
  echo "== $region ($countries): $(( size / 1000000 )) MB, free $(( free / 1000000 )) MB"
  if [ "$size" -gt 0 ] && [ "$free" -lt "$need" ]; then
    echo "SKIP $region: too big for this runner's disk (needs ~$(( need / 1000000 )) MB)"
    continue
  fi
  curl -fL --retry 3 --retry-delay 30 -A "$UA" -o "$WORK/in.osm.pbf" "$url"
  ts="$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$WORK/in.osm.pbf" 2>/dev/null || true)"
  osmium tags-filter --overwrite -o "$WORK/f.osm.pbf" "$WORK/in.osm.pbf" \
    nwr/amenity=hospital,clinic,pharmacy,police,fire_station \
    nwr/emergency=ambulance_station nwr/healthcare=hospital,clinic,pharmacy
  rm -f "$WORK/in.osm.pbf"
  osmium export --overwrite -f geojsonseq -a type,id -o "$WORK/f.geojsonseq" "$WORK/f.osm.pbf"
  rm -f "$WORK/f.osm.pbf"
  python3 -I "$HERE/build_extract.py" rows --geojsonseq "$WORK/f.geojsonseq" \
    --countries "$countries" --ne "$WORK/ne_admin0.geojson" --region "$region" \
    --osm-timestamp "$ts" --out "$OUT"
  rm -f "$WORK/f.geojsonseq"
done < "$WORK/plan.jsonl"

python3 -I "$HERE/build_extract.py" finalize --out "$OUT" \
  --manifest-in "$WORK/manifest_prev.json" --manifest-out "$OUT/manifest.json"
du -ch "$OUT"/nearby_*.json.gz | tail -1
