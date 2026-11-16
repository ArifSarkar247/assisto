# Assisto Map — tiles + style contract (maptiles lane → mapapp lane)

Owner order 10 Nov 00:35, PART A items 1–2. Built by `.github/workflows/map_tiles.yml`
(GitHub Actions only, never on our server). Licences: `owner_actions/CITY_MAP_LICENSE_BN.md`.

## 1. Base URL

| Stage | Base | Use |
|---|---|---|
| Production (after deploy) | `https://api.lifeassisto.com/maps/v1/` | the app, always |
| Build output (release `map-tiles`, published ONLY from main) | `https://github.com/ArifSarkar247/assisto/releases/download/map-tiles/` | deploy step only — never the app (GitHub is not a CDN). Branch runs: workflow artifacts `map-base`, `map-overture`, `map-terrain`, `map-assets`, `map-shots` |

The app keeps the base in ONE constant / remote-config value (`map_tiles_base`) so we can move to
a CDN later (see section 7) without a new build.

## 2. Styles (MapLibre style spec v8)

`{base}style/assisto-{theme}-{lang}.json` with theme `light|night`, lang `bn|en` (4 files).
The app picks the file from the app language (strict bn/en) and the dark-mode setting.
Every source URL inside the style is already absolute, so the app passes the style URL unchanged.
For offline Dhaka, the app rewrites only the `assisto_base` and `assisto_buildings` source URLs (section 5).

Sources inside each style:

| Source id | Type | URL | Content | Zooms |
|---|---|---|---|---|
| `assisto_base` | vector | `pmtiles://{base}bd_base.pmtiles` | OSM (Protomaps v4 schema): earth, water, landuse, landcover, roads (incl. rail / metro), pois, places, boundaries | 0–15 (overzoom to 20) |
| `assisto_buildings` | vector | `pmtiles://{base}bd_buildings.pmtiles` | Overture buildings, layer `buildings`, props `h` (m), `mh` (min height m), `hs` (`data` = real height, `floors` = num_floors × 3 m, `none` = style default) | 14 (overzoom to 20) |
| `assisto_places` | vector | `pmtiles://{base}bd_places.pmtiles` | Overture places (CDLA-P-2.0), layer `places`, props `name`, `pgf_name` (pre-shaped Bangla), `cat`, `conf` | 15 (overzoom) |
| `assisto_terrain` | raster-dem | `pmtiles://{base}bd_terrain.pmtiles` | Copernicus DEM GLO-30, terrarium PNG 256 px | 5–11 (overzoom) |

Glyphs: `{base}fonts/{fontstack}/{range}.pbf` — stacks `Noto Sans Regular`, `Noto Sans Medium`,
`Noto Sans Italic`, `Noto Sans Bengali Regular v1` (pre-shaped "PGF" Bangla, see 4).
Sprites: `{base}sprites/v1/{light|night}` (+ `@2x`). Our own icons (CC0).

Layer ids the app may toggle (visibility only; never remove): `buildings-3d`, `hillshade`,
`rail`, `metro`, `pois`, `places-overture`. App overlay layers (our own data: bus routes,
stops, fares, waterlogging, women bus) are GeoJSON sources the APP adds above `road-labels`
(`beforeId: "road-labels"`), never mixed into these tile files.

Required credit (style `attribution` + shown small on the map, never hidden):
`© OpenStreetMap contributors · Overture Maps · Copernicus`.

## 3. Renderer requirement

PMTiles needs MapLibre Native ≥ 11.8 (Android) / MapLibre GL JS + `pmtiles` protocol (web).
If the Flutter plugin in use is older: tell the maptiles lane — fallback is `go-pmtiles serve`
behind nginx giving `{base}xyz/{name}/{z}/{x}/{y}.mvt` (≈20 MB RAM), same files, no new cost.

## 4. Bangla labels (important)

MapLibre does NOT shape Bengali script (conjuncts/vowel signs break). We use pre-shaped
"Positioned Glyph Font" (PGF, wipfli/pgf-encoding, CC0 + Noto OFL): the base tiles carry
`pgf:name:bn` / `pgf:name` (already shaped, Private-Use codepoints) and the style draws them
with font `Noto Sans Bengali Regular v1`. Rules for the APP's own overlay labels in Bangla:
send them pre-encoded too — `deploy/maptiles/pgf_encode.py` (HarfBuzz) gives the same encoding;
use the backend/CI to store `label_pgf` next to `label_bn`, and draw with
`text-font: ["Noto Sans Bengali Regular v1"]`. A raw Bangla string in a symbol layer will look broken.
English labels use `Noto Sans Regular`.

## 5. Dhaka offline pack

`{base}offline/manifest.json`:
```json
{"version": "2026MMDD.N", "bbox": [90.30, 23.68, 90.53, 23.92], "maxzoom": 15,
 "files": [{"name": "dhaka_base.pmtiles", "bytes": 0, "sha256": "…"},
           {"name": "dhaka_buildings.pmtiles", "bytes": 0, "sha256": "…"}]}
```
App flow: Wi-Fi recommended, show size first, download each file to app storage (resume with
HTTP Range), verify sha256, then set `assisto_base` → `pmtiles://file://<path>/dhaka_base.pmtiles`
and `assisto_buildings` likewise while inside the bbox. Fonts + sprites: download the ranges
listed in `offline/manifest.json` → `"fonts"` and keep them with the pack.

## 6. Build manifest

`{base}manifest.json`: `{version, built_at, sources: {osm: {extract, date}, overture: {release},
copernicus: {tiles}}, files: [{name, bytes, sha256}]}`. The deploy step fetches it LAST-written,
verifies every sha256, swaps a `current` symlink atomically (rollback = previous dir).

## 7. Hosting + cost (summary; numbers in STATUS after the first CI build)

Served from our server disk by nginx (range requests, `Cache-Control: public, max-age=86400`,
immutable versioned dir). AWS Mumbai egress: first 100 GB/month free (shared with all our
traffic), then USD 0.1093/GB. Estimate ≈15 MB/month per active map user → ≈ ৳0.2 per user per
month; Dhaka pack ≈ one download. Options if egress grows: Cloudflare R2 (10 GB free storage,
USD 0 egress) — owner approval needed before any account/spending.
