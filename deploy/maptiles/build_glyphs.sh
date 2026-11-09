#!/usr/bin/env bash
# Build MapLibre glyph PBFs (CI only):
#  * "Noto Sans Bengali Regular v1" — pre-shaped Bangla (PGF) built HERE from the same
#    pgf-encoding zip the tile build uses (so codepoints match), with wipfli/pgf-glyph-ranges
#    (font-maker, BSD-3; Noto fonts SIL OFL 1.1);
#  * Noto Sans Regular / Medium / Italic (Latin) — protomaps/basemaps-assets (OFL), pinned.
#   build_glyphs.sh PGF_ZIP OUT_FONTS_DIR
set -euo pipefail
PGF_ZIP="$(readlink -f "$1")"; OUT="$(readlink -f "$2")"
GLYPH_SHA=96cbacf2e76adaf0f111d8d082379ee018d0010a
ASSETS_SHA=028c18f713baecad011301ff7a69acc39bcc2ae7
STACK="Noto Sans Bengali Regular v1"
W="$(mktemp -d)"; mkdir -p "$OUT"

git clone -q https://github.com/wipfli/pgf-glyph-ranges "$W/g"
git -C "$W/g" checkout -q "$GLYPH_SHA"
git -C "$W/g" submodule -q update --init vendor/sdf-glyph-foundry vendor/filesystem vendor/protozero
rm -rf "$W/g/vendor/pgf-encoding" && mkdir -p "$W/unz" && unzip -q "$PGF_ZIP" -d "$W/unz"
mv "$W"/unz/*/ "$W/g/vendor/pgf-encoding"
test -f "$W/g/vendor/pgf-encoding/encoding/NotoSansBengali-Regular-v1.csv"
python3 - "$W/g/main.cpp" "$STACK" <<'PY'
import re, sys
p, stack = sys.argv[1], sys.argv[2]
s = open(p).read()
s, n1 = re.subn(r"vector<InputFont> input_fonts = \{.*?\n\};", 'vector<InputFont> input_fonts = {\n    {"NotoSansBengali-Regular", "1"}\n};', s, count=1, flags=re.S)
s, n2 = re.subn(r'string output_name = "[^"]*";', f'string output_name = "{stack}";', s, count=1)
if n1 != 1 or n2 != 1:
    sys.exit("main.cpp layout changed")
open(p, "w").write(s)
PY
built=0
if (cd "$W/g" && cmake -DCMAKE_BUILD_TYPE=Release . >/dev/null && make -s && ./font-maker >/dev/null); then
  if ls "$W/g/font/$STACK"/*.pbf >/dev/null 2>&1; then
    rm -rf "$OUT/$STACK"; cp -r "$W/g/font/$STACK" "$OUT/$STACK"; built=1
  fi
fi
if [ "$built" != 1 ]; then
  echo "::warning::PGF glyph build failed — using the prebuilt v1 ranges from the same pinned repo"
  rm -rf "$OUT/$STACK"; cp -r "$W/g/font/NotoSansBengali-Regular-v1" "$OUT/$STACK"
fi
cp "$W/g/font/OFL.txt" "$OUT/OFL.txt"

git clone -q --filter=blob:none --sparse https://github.com/protomaps/basemaps-assets "$W/a"
git -C "$W/a" checkout -q "$ASSETS_SHA"
git -C "$W/a" sparse-checkout set fonts
for s in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do
  rm -rf "$OUT/$s"; cp -r "$W/a/fonts/$s" "$OUT/$s"
done
echo "bengali_built_in_ci=$built"
ls "$OUT/$STACK" | wc -l | xargs echo "bengali ranges:"
du -sh "$OUT"
