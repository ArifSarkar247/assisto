# Bangla font decision (f1-design)

**Decision: Noto Sans Bengali** (Latin text uses **Inter**; Bangla glyphs fall
back to Noto Sans Bengali through `fontFamilyFallback`).

## How we compared

The same 6 real gallery screens (home, My Circle, a circle chat, the Assisto
chat, settings, money) were rendered with the new theme in bn, light + dark,
with each candidate in the Bangla slot. Only the font changed; the layout and
line heights were the same (`ASSISTO_BN_FONT=<family>` +
`ASSISTO_BN_FONT_DIR`, see `app/test/app_fonts.dart`). Every candidate was
built the same way: official OFL files from `google/fonts/ofl/…`, static
400/500/600/700, subset to the Bengali block plus ZWJ/ZWNJ, U+25CC and the
dandas.

Side-by-side sheets: `bangla_font_compare/<screen>_bn_<light|dark>.jpg`
(left to right: Noto Sans Bengali, Hind Siliguri, Anek Bangla).

The no-clip test (`app/test/f1_design_test.dart`) renders the tallest
conjuncts and below-base signs (ক্ষ্ম স্ত্র ঙ্ক্ষ কু কূ কৃ রু রূ হৃ শ্রু দ্রু ক্রূ, plus a
mixed Bangla/Latin/৳ line) at all 15 text styles, at 100% and 200% text size,
and checks with pixels that the ink stays inside the line box.

| | Noto Sans Bengali | Hind Siliguri | Anek Bangla |
|---|---|---|---|
| No-clip test (60 cases) | **pass** | pass | **fail, 11 cases** (display/headline/title sizes: descenders 2–7 px below the line box) |
| Natural line box (ascent + descent) | 1.33 em (compact) | 1.62 em | 1.87 em (very tall) |
| Size at the same font size | Matches Inter's x-height, so Bangla and English look the same size | Smaller-looking glyphs: Bangla looks a size below the English next to it | Large, display-like |
| Bangla digits | Clear | Clear | **৫০০ looks like "500" / "৳00"**, which is risky for money amounts |
| Conjunct coverage | Most complete (Google's reference Bengali) | Good | Good |
| Bundle (4 weights, subset) | 390 KB | 396 KB | 659 KB |
| Weights | variable font, we ship 4 static instances | static 300–700 | variable font |

## Why Noto Sans Bengali

1. **It never clips** at any style or at 200% text size. Anek Bangla failed
   11 cases. Hind Siliguri passes, but its 1.62 em natural box would push us
   toward taller line heights everywhere, which wastes space on small phones.
2. **It reads as one family next to Inter.** The x-height and stroke weight
   match, so mixed lines like "৳500 খাবার" or "bKash: রহিম — ৳2,000" sit evenly.
   Hind's Bangla reads a size smaller than the Inter beside it.
3. **Digits are unambiguous.** This matters in a money and khata app. Anek's
   ৫ and ০ look like Latin 5 and 0.
4. **It has the widest conjunct coverage and the most testing behind it.** It
   is Google's reference Bengali design and what Android itself uses for
   Bangla, so it looks native on every phone in Bangladesh (Android 8–16).
5. **It is small.** We ship 4 static weights subset to Bangla only, about 97 KB
   each. Real static weights also mean bold Bangla is drawn from true bold
   outlines, so it doesn't depend on how the engine maps `FontWeight` onto a
   variable font's `wght` axis.

## What ships

`app/assets/fonts/`: `Inter-{Regular,Medium,SemiBold,Bold}.ttf` (Inter v4.0
from rsms/inter `extras/ttf`, Latin + Latin-1 + punctuation subset; ZWJ/ZWNJ
deliberately excluded so a Bangla run never splits between fonts) and
`NotoSansBengali-{Regular,Medium,SemiBold,Bold}.ttf`, each next to its
`*-OFL.txt`. `assets/fonts/NotoSansBengali.ttf` (the old variable file) stays
in the repo only because the backend's card renderer reads it. It is no
longer bundled in the app.

Bundled font size: old 464 KB → new 703 KB (+239 KB uncompressed, roughly
+150 KB inside the APK after zip). Nothing is downloaded at runtime, and no
`google_fonts`.
