#!/usr/bin/env bash
# Patch a pinned protomaps/basemaps checkout for Bangladesh (CI only).
#  1. keep name:bn in the tiles (not in upstream ALLOWED_LANGS);
#  2. register the pre-shaped Bengali font (PGF) so names get pgf:name / pgf:name:bn;
#  3. show metro / light rail from z11 (Dhaka MRT), like main rail.
# Each patch is verified; the build fails loudly if upstream code moved.
set -euo pipefail
SRC="$1/tiles/src/main/java/com/protomaps/basemap"

sed -i 's#^\(\s*\)"bg", // Bulgarian#\1"bg", // Bulgarian\n\1"bn", // Bengali (Assisto)#' "$SRC/names/OsmNames.java"
grep -q '"bn", // Bengali (Assisto)' "$SRC/names/OsmNames.java" || { echo "patch 1 failed"; exit 1; }

sed -i 's#^\(\s*\)fontRegistry.loadFontBundle("NotoSansDevanagari-Regular", "1", "Devanagari");#&\n\1fontRegistry.loadFontBundle("NotoSansBengali-Regular", "1", "Bengali");#' "$SRC/Basemap.java"
grep -q 'loadFontBundle("NotoSansBengali-Regular", "1", "Bengali")' "$SRC/Basemap.java" || { echo "patch 2 failed"; exit 1; }

python3 - "$SRC/layers/Roads.java" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# Split subway/light_rail out of the z14 group into their own z11 rule.
old = "          light_rail\n"
if old not in s:
    sys.exit("patch 3 failed: light_rail not found")
s = s.replace(old, "", 1)
s = s.replace("          subway\n", "", 1)
anchor = '    rule(\n      with("railway", "disused"),'
if anchor not in s:
    sys.exit("patch 3 failed: anchor")
s = s.replace(anchor, '    rule(\n      with("railway", "subway", "light_rail"),\n      use("minZoom", 11)\n    ),\n' + anchor, 1)
open(p, "w", encoding="utf-8").write(s)
print("patch 3 ok")
PY
echo "protomaps patched"
