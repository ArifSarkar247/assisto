#!/usr/bin/env bash
# Server side (run by the lead/owner-approved deploy ONLY; light: downloads + sha256, no builds).
# Fetch the newest map-tiles release into ~/assisto/maptiles/releases/<version>/, verify every
# sha256, refuse if the disk would pass 75 %, then switch the `current` symlink atomically.
# nginx serves ~/assisto/maptiles/current/ at /maps/v1/ (deploy/maptiles/nginx_maps.conf).
# Rollback: ln -sfn releases/<old> ~/assisto/maptiles/current.next && mv -T ... (see bottom).
set -euo pipefail
REPO="${MAPTILES_REPO:-ArifSarkar247/assisto}"
BASE="https://github.com/$REPO/releases/download/map-tiles"
ROOT="${MAPTILES_ROOT:-$HOME/assisto/maptiles}"
MAX_PCT="${MAPTILES_MAX_DISK_PCT:-75}"
mkdir -p "$ROOT/releases"
tmp="$(mktemp -d "$ROOT/.dl.XXXX")"; trap 'rm -rf "$tmp"' EXIT
# MAPTILES_TAG=map-tiles-staging-<run id> fetches a non-public DRAFT staging release with gh (lead's deploy);
# default = the public release "map-tiles" (published from main only).
GH="${GH:-$HOME/assisto/bin/gh}"
fetch() {  # fetch NAME OUTFILE
  if [ -n "${MAPTILES_TAG:-}" ]; then "$GH" release download "$MAPTILES_TAG" -R "$REPO" -p "$1" -O "$2" --clobber
  else curl -fsSL "$BASE/$1" -o "$2"; fi
}
fetch manifest.json "$tmp/manifest.json"
ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$tmp/manifest.json")"
dest="$ROOT/releases/$ver"
if [ -e "$ROOT/current" ] && [ "$(readlink -f "$ROOT/current")" = "$(readlink -f "$dest")" ]; then echo "already on $ver"; exit 0; fi
need=$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(sum(f["bytes"] for f in m["files"])+m.get("assets",{}).get("bytes",0))' "$tmp/manifest.json")
read -r size used <<<"$(df -B1 --output=size,used "$ROOT" | tail -1)"
pct=$(( (used + need) * 100 / size ))
echo "map-tiles $ver: needs $((need/1048576)) MB; disk after = ${pct}% (limit ${MAX_PCT}%)"
if [ "$pct" -ge "$MAX_PCT" ]; then echo "STOP: disk would reach ${pct}% — delete an old release or ask the owner"; exit 2; fi
mkdir -p "$tmp/v/offline"
python3 - "$tmp/manifest.json" <<'PY' > "$tmp/list.txt"
import json, sys
m = json.load(open(sys.argv[1]))
for f in m["files"] + [m["assets"]]:
    print(f["name"], f["sha256"], " ".join(f.get("parts", [])))
PY
while read -r name sum parts; do
  if [ -n "$parts" ]; then : > "$tmp/$name"; for p in $parts; do fetch "$p" "$tmp/part"; cat "$tmp/part" >> "$tmp/$name"; rm -f "$tmp/part"; done
  else fetch "$name" "$tmp/$name"; fi
  echo "$sum  $tmp/$name" | sha256sum -c --quiet || { echo "sha256 mismatch: $name"; exit 3; }
done < "$tmp/list.txt"
tar -xzf "$tmp/map_assets.tar.gz" -C "$tmp/v"
for f in "$tmp"/*.pmtiles; do
  case "$(basename "$f")" in dhaka_*) mv "$f" "$tmp/v/offline/";; *) mv "$f" "$tmp/v/";; esac
done
cp "$tmp/manifest.json" "$tmp/v/manifest.json"
chmod -R o+rX "$tmp/v"
mv "$tmp/v" "$dest"
ln -sfn "$dest" "$ROOT/current.next" && mv -T "$ROOT/current.next" "$ROOT/current"
echo "map-tiles now $ver"
# keep the newest 2 releases only (disk rule)
ls -1dt "$ROOT"/releases/*/ | tail -n +3 | xargs -r rm -rf
# Rollback: ln -sfn "$ROOT/releases/<old>" "$ROOT/current.next" && mv -T "$ROOT/current.next" "$ROOT/current"
