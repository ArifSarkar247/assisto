#!/usr/bin/env bash
# sjstart2: the official BBS / a2i administrative list (divisions, districts,
# upazilas, 4,540 unions; Bangla + English names) as published (MIT) at
# github.com/nuhil/bangladesh-geocode — pinned to one commit so the build is
# reproducible. Names only (no coordinates): build_bd_places.py places each
# union on OpenStreetMap inside ITS upazila, or leaves it out.
set -euo pipefail
OUT=${1:?out dir}
REF=${BBS_REF:-5622f68bd07a98e076edcf8100bf0db6a75b9854}
mkdir -p "$OUT"
for f in divisions/divisions.json districts/districts.json upazilas/upazilas.json unions/unions.json; do
  curl -fsSL --max-time 120 -o "$OUT/bbs_$(basename "$f")" \
    "https://raw.githubusercontent.com/nuhil/bangladesh-geocode/$REF/$f"
done
ls -la "$OUT"
