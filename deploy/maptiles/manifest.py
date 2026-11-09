"""Write manifest.json (+ offline/manifest.json inside the assets dir) for a map-tiles build.

    python manifest.py DIST_DIR ASSETS_DIR VERSION SOURCES_JSON
DIST_DIR holds the release files (pmtiles + map_assets.tar.gz are added after this runs, so
the tarball is listed by the caller); ASSETS_DIR is the tree that becomes map_assets.tar.gz.
"""
import datetime
import hashlib
import json
import os
import sys

DHAKA_BBOX = [90.30, 23.68, 90.53, 23.92]


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entry(path, name=None):
    return {"name": name or os.path.basename(path), "bytes": os.path.getsize(path), "sha256": sha(path)}


def main(dist, assets, version, sources_json):
    sources = json.load(open(sources_json))
    off = os.path.join(assets, "offline")
    os.makedirs(off, exist_ok=True)
    fonts = []
    fdir = os.path.join(assets, "fonts")
    for stack in sorted(os.listdir(fdir)):
        for rng in sorted(os.listdir(os.path.join(fdir, stack))):
            if stack.startswith("Noto Sans Bengali") or rng in ("0-255.pbf", "256-511.pbf", "8192-8447.pbf"):
                fonts.append(f"fonts/{stack}/{rng}")
    offline = {
        "version": version, "bbox": DHAKA_BBOX, "maxzoom": 15,
        "files": [entry(os.path.join(dist, n)) for n in ("dhaka_base.pmtiles", "dhaka_buildings.pmtiles")],
        "fonts": fonts,
        "sprites": [f"sprites/v1/{t}{r}.{e}" for t in ("light", "night") for r in ("", "@2x") for e in ("json", "png")],
        "credits": "© OpenStreetMap contributors · Overture Maps · Copernicus",
    }
    json.dump(offline, open(os.path.join(off, "manifest.json"), "w"), indent=1)
    files = [entry(os.path.join(dist, n)) for n in sorted(os.listdir(dist)) if n.endswith(".pmtiles")]
    manifest = {
        "version": version,
        "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "sources": sources,
        "files": files,
        "credits": offline["credits"],
    }
    json.dump(manifest, open(os.path.join(dist, "manifest.partial.json"), "w"), indent=1)
    total = sum(f["bytes"] for f in files)
    print(json.dumps({"total_pmtiles_bytes": total, "files": {f["name"]: f["bytes"] for f in files}}, indent=1))


if __name__ == "__main__":
    main(*sys.argv[1:5])
