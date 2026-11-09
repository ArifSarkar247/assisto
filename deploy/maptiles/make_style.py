"""Assisto Map styles (MapLibre style spec v8): light/night x bn/en.

    python make_style.py BASE_URL OUT_DIR   (BASE_URL ends with '/', e.g. https://api.lifeassisto.com/maps/v1/)

Data schema: Protomaps basemap v4 (OSM) + our Overture buildings/places + Copernicus terrain.
Bangla labels use pre-shaped PGF strings (pgf:name:bn / pgf:name / pgf_name) drawn with the
font stack "Noto Sans Bengali Regular v1"; a raw Bengali string is never drawn (it would break).
"""
import json
import os
import sys

BN_FONT = ["literal", ["Noto Sans Bengali Regular v1"]]
LATIN = ["literal", ["Noto Sans Regular"]]
LATIN_MED = ["literal", ["Noto Sans Medium"]]
LATIN_IT = ["literal", ["Noto Sans Italic"]]
CREDIT = "© OpenStreetMap contributors · Overture Maps · Copernicus"

PALETTES = {
    "light": {
        "background": "#EFEBE3", "earth": "#F4F1EA", "urban": "#EEEAE2", "farmland": "#EAF0DA",
        "forest": "#C9E2BA", "park": "#CFE8C6", "grass": "#DCEDCF", "hospital": "#F8E1E1",
        "school": "#F1E7D2", "industrial": "#E9E4EE", "aerodrome": "#E4E6EA", "cemetery": "#DCE6D3",
        "water": "#A9D3F0", "water_line": "#8CC2E8",
        "hill_shadow": "#5B4E3C", "hill_high": "#FFFFFF", "hill_accent": "#7A6B55", "hill_ex": 0.35,
        "highway": "#F6C26B", "highway_case": "#D49A3E", "major": "#FFFFFF", "major_case": "#CEC6B8",
        "minor": "#FFFFFF", "minor_case": "#DED8CD", "service": "#FBFAF7", "path": "#BDB4A5",
        "rail": "#9AA1AB", "rail_dash": "#FFFFFF", "metro": "#D6336C", "ferry": "#4A90C8",
        "boundary": "#9B7FB0", "bld": "#E2DCD2", "bld_line": "#D3CBBE", "bld_low": "#E4DED4", "bld_high": "#C7BFB2",
        "label": "#2B2F36", "label_dim": "#5A616B", "halo": "#FFFFFF", "water_label": "#2F6EA3",
        "road_label": "#3B4048", "poi_label": "#3B4048",
    },
    "night": {
        "background": "#0B1220", "earth": "#111827", "urban": "#131B2A", "farmland": "#121C22",
        "forest": "#10241D", "park": "#12281F", "grass": "#132420", "hospital": "#2A1820",
        "school": "#221E18", "industrial": "#1A1A28", "aerodrome": "#1A1F2A", "cemetery": "#14231C",
        "water": "#0C2E4A", "water_line": "#12406A",
        "hill_shadow": "#000000", "hill_high": "#2B3445", "hill_accent": "#000000", "hill_ex": 0.4,
        "highway": "#B7863A", "highway_case": "#5A4320", "major": "#3A4558", "major_case": "#1F2733",
        "minor": "#2A3343", "minor_case": "#1A212C", "service": "#232B38", "path": "#465063",
        "rail": "#6B7280", "rail_dash": "#1F2937", "metro": "#F06595", "ferry": "#3B82F6",
        "boundary": "#8B73A6", "bld": "#1E2633", "bld_line": "#2A3344", "bld_low": "#222B3A", "bld_high": "#3A475C",
        "label": "#E5E7EB", "label_dim": "#AAB2BF", "halo": "#0B1220", "water_label": "#7CB7E6",
        "road_label": "#CBD2DC", "poi_label": "#D5DAE2",
    },
}


def label_field(lang):
    """(text-field, text-font) for OSM features (Protomaps v4 props)."""
    is_bn_name = ["==", ["get", "script"], "Bengali"]
    if lang == "bn":
        field = ["case",
                 ["has", "pgf:name:bn"], ["get", "pgf:name:bn"],
                 ["all", ["has", "pgf:name"], is_bn_name], ["get", "pgf:name"],
                 is_bn_name, ["coalesce", ["get", "name:en"], ""],
                 ["coalesce", ["get", "name:en"], ["get", "name"], ""]]
        font = ["case",
                ["has", "pgf:name:bn"], BN_FONT,
                ["all", ["has", "pgf:name"], is_bn_name], BN_FONT,
                LATIN]
    else:
        field = ["case",
                 ["has", "name:en"], ["get", "name:en"],
                 ["all", ["has", "pgf:name"], is_bn_name], ["get", "pgf:name"],
                 is_bn_name, "",
                 ["coalesce", ["get", "name"], ""]]
        font = ["case",
                ["has", "name:en"], LATIN,
                ["all", ["has", "pgf:name"], is_bn_name], BN_FONT,
                LATIN]
    return field, font


def overture_label(lang):
    has_pgf = ["has", "pgf_name"]
    has_latin = ["!=", ["coalesce", ["get", "name"], ""], ""]
    if lang == "bn":
        return (["case", has_pgf, ["get", "pgf_name"], ["coalesce", ["get", "name"], ""]],
                ["case", has_pgf, BN_FONT, LATIN])
    return (["case", has_latin, ["get", "name"], has_pgf, ["get", "pgf_name"], ""],
            ["case", has_latin, LATIN, has_pgf, BN_FONT, LATIN])


def z(*stops):
    return ["interpolate", ["exponential", 1.6], ["zoom"], *stops]


def roads(p):
    L = []
    kinds = [
        # (id, filter, minzoom, casing width stops, fill width stops, fill, casing)
        ("path", ["==", ["get", "kind"], "path"], 14, None, z(14, 0.6, 18, 3), p["path"], None),
        ("service", ["all", ["==", ["get", "kind"], "minor_road"], ["==", ["get", "kind_detail"], "service"]], 14,
         z(14, 1.2, 18, 9), z(14, 0.6, 18, 7), p["service"], p["minor_case"]),
        ("minor", ["all", ["==", ["get", "kind"], "minor_road"], ["!=", ["get", "kind_detail"], "service"]], 12,
         z(12, 0.6, 14, 3, 18, 16), z(12, 0.3, 14, 2, 18, 13), p["minor"], p["minor_case"]),
        ("major", ["==", ["get", "kind"], "major_road"], 7,
         z(7, 0.6, 10, 1.8, 14, 6, 18, 26), z(7, 0.4, 10, 1.2, 14, 4.5, 18, 22), p["major"], p["major_case"]),
        ("highway", ["==", ["get", "kind"], "highway"], 5,
         z(5, 0.8, 10, 2.6, 14, 8, 18, 30), z(5, 0.5, 10, 1.8, 14, 6, 18, 26), p["highway"], p["highway_case"]),
    ]
    for rid, flt, mz, cw, fw, fill, case in kinds:
        if case:
            L.append({"id": f"road-{rid}-casing", "type": "line", "source": "assisto_base", "source-layer": "roads",
                      "minzoom": mz, "filter": flt,
                      "layout": {"line-cap": "round", "line-join": "round", "line-sort-key": ["get", "sort_rank"]},
                      "paint": {"line-color": case, "line-width": cw,
                                "line-opacity": ["case", ["boolean", ["get", "is_tunnel"], False], 0.5, 1]}})
    for rid, flt, mz, cw, fw, fill, case in kinds:
        paint = {"line-color": fill, "line-width": fw}
        if rid == "path":
            paint["line-dasharray"] = [2, 1.5]
        L.append({"id": f"road-{rid}", "type": "line", "source": "assisto_base", "source-layer": "roads",
                  "minzoom": mz, "filter": flt,
                  "layout": {"line-cap": "butt" if rid == "path" else "round", "line-join": "round",
                             "line-sort-key": ["get", "sort_rank"]},
                  "paint": paint})
    return L


def build(theme, lang, base):
    p = PALETTES[theme]
    lf, lfont = label_field(lang)
    bump = 1 if lang == "bn" else 0  # Bengali glyphs read smaller at the same size
    metro_kinds = ["literal", ["subway", "light_rail", "monorail"]]
    poi_icons = ["match", ["get", "kind"],
                 ["station", "train_station"], "rail", ["subway_entrance"], "metro",
                 ["bus_stop", "bus_station"], "bus", ["ferry_terminal"], "ferry",
                 ["aerodrome", "airport"], "airport", ["hospital", "clinic", "doctors"], "hospital",
                 ["pharmacy"], "pharmacy", ["police"], "police", ["fire_station"], "fire_station",
                 ["place_of_worship", "mosque"], "mosque", ["school", "kindergarten"], "school",
                 ["university", "college"], "university", ["park", "garden", "playground"], "park",
                 ["fuel"], "fuel", ["bank"], "bank", ["atm"], "atm", ["marketplace", "supermarket"], "market",
                 "dot"]
    major_pois = ["literal", ["station", "train_station", "subway_entrance", "aerodrome", "airport", "hospital",
                              "police", "fire_station", "university", "ferry_terminal", "bus_station"]]
    text_common = {"text-font": lfont, "text-field": lf, "text-max-width": 8}
    paint_label = {"text-color": p["label"], "text-halo-color": p["halo"], "text-halo-width": 1.4}

    layers = [
        {"id": "background", "type": "background", "paint": {"background-color": p["background"]}},
        {"id": "earth", "type": "fill", "source": "assisto_base", "source-layer": "earth",
         "paint": {"fill-color": p["earth"]}},
        {"id": "landcover", "type": "fill", "source": "assisto_base", "source-layer": "landcover", "maxzoom": 12,
         "paint": {"fill-color": ["match", ["get", "kind"], "forest", p["forest"], "farmland", p["farmland"],
                                  ["grassland", "scrub"], p["grass"], "urban_area", p["urban"], p["earth"]],
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 6, 0.9, 12, 0.3]}},
        {"id": "landuse", "type": "fill", "source": "assisto_base", "source-layer": "landuse",
         "filter": ["match", ["get", "kind"],
                    ["park", "national_park", "nature_reserve", "garden", "golf_course", "playground", "zoo",
                     "forest", "wood", "grass", "farmland", "cemetery", "hospital", "school", "university",
                     "college", "industrial", "aerodrome", "pedestrian"], True, False],
         "paint": {"fill-color": ["match", ["get", "kind"],
                                  ["park", "national_park", "nature_reserve", "garden", "golf_course", "playground",
                                   "zoo"], p["park"],
                                  ["forest", "wood"], p["forest"], "grass", p["grass"], "farmland", p["farmland"],
                                  "cemetery", p["cemetery"], "hospital", p["hospital"],
                                  ["school", "university", "college"], p["school"], "industrial", p["industrial"],
                                  "aerodrome", p["aerodrome"], p["urban"]]}},
        {"id": "hillshade", "type": "hillshade", "source": "assisto_terrain", "maxzoom": 16,
         "paint": {"hillshade-shadow-color": p["hill_shadow"], "hillshade-highlight-color": p["hill_high"],
                   "hillshade-accent-color": p["hill_accent"], "hillshade-exaggeration": p["hill_ex"],
                   "hillshade-illumination-direction": 315}},
        {"id": "water", "type": "fill", "source": "assisto_base", "source-layer": "water",
         "filter": ["==", ["geometry-type"], "Polygon"], "paint": {"fill-color": p["water"]}},
        {"id": "water-lines", "type": "line", "source": "assisto_base", "source-layer": "water",
         "filter": ["all", ["==", ["geometry-type"], "LineString"],
                    ["match", ["get", "kind"], ["river", "canal", "stream", "drain", "ditch"], True, False]],
         "layout": {"line-cap": "round", "line-join": "round"},
         "paint": {"line-color": p["water_line"],
                   "line-width": ["match", ["get", "kind"], ["river", "canal"], z(8, 0.6, 14, 3, 18, 12),
                                  z(12, 0.3, 18, 4)]}},
        {"id": "boundaries", "type": "line", "source": "assisto_base", "source-layer": "boundaries",
         "filter": ["<=", ["coalesce", ["get", "kind_detail"], 4], 4],
         "paint": {"line-color": p["boundary"], "line-dasharray": [3, 2],
                   "line-width": ["interpolate", ["linear"], ["zoom"], 4, 0.6, 12, 1.6]}},
        {"id": "buildings-2d", "type": "fill", "source": "assisto_buildings", "source-layer": "buildings",
         "minzoom": 14, "maxzoom": 15.5,
         "paint": {"fill-color": p["bld"], "fill-outline-color": p["bld_line"],
                   "fill-opacity": ["interpolate", ["linear"], ["zoom"], 14, 0.6, 15, 1]}},
    ]
    layers += roads(p)
    layers += [
        {"id": "ferry", "type": "line", "source": "assisto_base", "source-layer": "roads", "minzoom": 9,
         "filter": ["==", ["get", "kind"], "ferry"],
         "paint": {"line-color": p["ferry"], "line-dasharray": [2, 2], "line-width": z(9, 0.6, 16, 2)}},
        {"id": "rail", "type": "line", "source": "assisto_base", "source-layer": "roads", "minzoom": 6,
         "filter": ["all", ["==", ["get", "kind"], "rail"],
                    ["!", ["in", ["coalesce", ["get", "kind_detail"], ""], metro_kinds]]],
         "paint": {"line-color": p["rail"], "line-width": z(6, 0.6, 12, 2, 18, 5)}},
        {"id": "rail-dash", "type": "line", "source": "assisto_base", "source-layer": "roads", "minzoom": 12,
         "filter": ["all", ["==", ["get", "kind"], "rail"],
                    ["!", ["in", ["coalesce", ["get", "kind_detail"], ""], metro_kinds]]],
         "paint": {"line-color": p["rail_dash"], "line-dasharray": [3, 3], "line-width": z(12, 0.8, 18, 2.5)}},
        {"id": "metro", "type": "line", "source": "assisto_base", "source-layer": "roads", "minzoom": 9,
         "filter": ["all", ["==", ["get", "kind"], "rail"],
                    ["in", ["coalesce", ["get", "kind_detail"], ""], metro_kinds]],
         "layout": {"line-cap": "round", "line-join": "round"},
         "paint": {"line-color": p["metro"], "line-width": z(9, 1.2, 12, 3, 18, 7)}},
        {"id": "buildings-3d", "type": "fill-extrusion", "source": "assisto_buildings", "source-layer": "buildings",
         "minzoom": 15,
         "paint": {
             # h: Overture height in m (or num_floors x 3); 6 m is a STYLE default for footprints with no height.
             "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 15, 0, 15.6,
                                       ["case", [">", ["coalesce", ["get", "h"], 0], 0], ["get", "h"], 6]],
             "fill-extrusion-base": ["coalesce", ["get", "mh"], 0],
             "fill-extrusion-color": ["interpolate", ["linear"], ["coalesce", ["get", "h"], 6],
                                      0, p["bld_low"], 30, p["bld_high"]],
             "fill-extrusion-opacity": 0.88, "fill-extrusion-vertical-gradient": True}},
        {"id": "water-labels-line", "type": "symbol", "source": "assisto_base", "source-layer": "water", "minzoom": 11,
         "filter": ["all", ["==", ["geometry-type"], "LineString"],
                    ["match", ["get", "kind"], ["river", "canal", "stream"], True, False]],
         "layout": dict(text_common, **{"symbol-placement": "line", "text-size": 12 + bump, "symbol-spacing": 400}),
         "paint": {"text-color": p["water_label"], "text-halo-color": p["halo"], "text-halo-width": 1.2}},
        {"id": "water-labels", "type": "symbol", "source": "assisto_base", "source-layer": "water", "minzoom": 8,
         "filter": ["all", ["==", ["geometry-type"], "Point"],
                    ["match", ["get", "kind"], ["river", "lake", "water", "riverbank", "sea", "ocean", "bay"], True, False]],
         "layout": dict(text_common, **{"text-size": 12 + bump, "text-letter-spacing": 0.05}),
         "paint": {"text-color": p["water_label"], "text-halo-color": p["halo"], "text-halo-width": 1.2}},
        {"id": "road-labels", "type": "symbol", "source": "assisto_base", "source-layer": "roads", "minzoom": 13,
         "filter": ["match", ["get", "kind"], ["highway", "major_road", "minor_road"], True, False],
         "layout": dict(text_common, **{"symbol-placement": "line", "text-size": z(13, 10 + bump, 18, 14 + bump),
                                        "text-max-angle": 30, "symbol-spacing": 350}),
         "paint": {"text-color": p["road_label"], "text-halo-color": p["halo"], "text-halo-width": 1.5}},
        {"id": "pois-major", "type": "symbol", "source": "assisto_base", "source-layer": "pois", "minzoom": 13,
         "filter": ["in", ["get", "kind"], major_pois],
         "layout": dict(text_common, **{"icon-image": poi_icons, "icon-size": 1, "text-size": 11 + bump,
                                        "text-offset": [0, 1.1], "text-anchor": "top", "text-optional": True}),
         "paint": dict(paint_label, **{"text-color": p["poi_label"]})},
        {"id": "pois", "type": "symbol", "source": "assisto_base", "source-layer": "pois", "minzoom": 16,
         "filter": ["!", ["in", ["get", "kind"], major_pois]],
         "layout": dict(text_common, **{"icon-image": poi_icons, "icon-size": 0.85, "text-size": 10 + bump,
                                        "text-offset": [0, 1.0], "text-anchor": "top", "text-optional": True}),
         "paint": dict(paint_label, **{"text-color": p["label_dim"]})},
    ]
    ofield, ofont = overture_label(lang)
    layers.append({"id": "places-overture", "type": "symbol", "source": "assisto_places", "source-layer": "places",
                   "minzoom": 17,
                   "layout": {"text-field": ofield, "text-font": ofont, "text-size": 10 + bump, "text-max-width": 8,
                              "icon-image": "dot", "icon-size": 0.6, "text-offset": [0, 0.9], "text-anchor": "top",
                              "text-optional": True},
                   "paint": dict(paint_label, **{"text-color": p["label_dim"]})})
    layers += [
        {"id": "places-neighbourhood", "type": "symbol", "source": "assisto_base", "source-layer": "places",
         "minzoom": 12, "filter": ["==", ["get", "kind"], "neighbourhood"],
         "layout": dict(text_common, **{"text-size": z(12, 10 + bump, 16, 13 + bump), "text-transform": "none"}),
         "paint": dict(paint_label, **{"text-color": p["label_dim"]})},
        {"id": "places-locality", "type": "symbol", "source": "assisto_base", "source-layer": "places",
         "filter": ["==", ["get", "kind"], "locality"],
         "layout": dict(text_common, **{"text-size": ["interpolate", ["linear"], ["zoom"], 6, 10 + bump, 12, 15 + bump],
                                        "symbol-sort-key": ["get", "min_zoom"]}),
         "paint": paint_label},
        {"id": "places-region", "type": "symbol", "source": "assisto_base", "source-layer": "places",
         "minzoom": 5, "maxzoom": 9, "filter": ["==", ["get", "kind"], "region"],
         "layout": dict(text_common, **{"text-size": 12 + bump}),
         "paint": dict(paint_label, **{"text-color": p["label_dim"]})},
        {"id": "places-country", "type": "symbol", "source": "assisto_base", "source-layer": "places",
         "maxzoom": 7, "filter": ["==", ["get", "kind"], "country"],
         "layout": dict(text_common, **{"text-size": 14 + bump}),
         "paint": paint_label},
    ]
    return {
        "version": 8,
        "name": f"Assisto {theme} ({lang})",
        "metadata": {"assisto:credits": CREDIT, "assisto:schema": "protomaps-v4+assisto-1",
                     "assisto:bangla": "pgf (Noto Sans Bengali Regular v1)"},
        "center": [90.4125, 23.8103], "zoom": 11,
        "sources": {
            "assisto_base": {"type": "vector", "url": f"pmtiles://{base}bd_base.pmtiles",
                             "attribution": "© OpenStreetMap contributors"},
            "assisto_buildings": {"type": "vector", "url": f"pmtiles://{base}bd_buildings.pmtiles",
                                  "attribution": "Overture Maps · © OpenStreetMap contributors"},
            "assisto_places": {"type": "vector", "url": f"pmtiles://{base}bd_places.pmtiles",
                               "attribution": "Overture Maps"},
            "assisto_terrain": {"type": "raster-dem", "url": f"pmtiles://{base}bd_terrain.pmtiles",
                                "encoding": "terrarium", "tileSize": 256, "attribution": "Copernicus"},
        },
        "sprite": f"{base}sprites/v1/{theme}",
        "glyphs": base + "fonts/{fontstack}/{range}.pbf",
        "layers": layers,
    }


def main(base, out):
    os.makedirs(out, exist_ok=True)
    for theme in ("light", "night"):
        for lang in ("bn", "en"):
            st = build(theme, lang, base)
            with open(os.path.join(out, f"assisto-{theme}-{lang}.json"), "w", encoding="utf-8") as f:
                json.dump(st, f, ensure_ascii=False, separators=(",", ":"))
    print("styles written to", out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
