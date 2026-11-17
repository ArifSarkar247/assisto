"""Finish manifest.json: add the assets tarball, split files > 1.9 GB into release parts.

    python finalize.py DIST_DIR
Reads DIST_DIR/manifest.partial.json, writes DIST_DIR/manifest.json and prints the upload list.
GitHub release assets are limited to 2 GB each; the deploy step re-joins parts and checks sha256.
"""
import json
import os
import sys

from manifest import entry

LIMIT = 1900 * 1024 * 1024


def main(dist):
    m = json.load(open(os.path.join(dist, "manifest.partial.json")))
    m["assets"] = entry(os.path.join(dist, "map_assets.tar.gz"))
    uploads = ["map_assets.tar.gz"]
    for f in m["files"]:
        p = os.path.join(dist, f["name"])
        if f["bytes"] <= LIMIT:
            uploads.append(f["name"])
            continue
        parts = []
        with open(p, "rb") as src:
            i = 0
            while True:
                chunk = src.read(LIMIT)
                if not chunk:
                    break
                name = f"{f['name']}.part{i}"
                with open(os.path.join(dist, name), "wb") as out:
                    out.write(chunk)
                parts.append(name)
                i += 1
        f["parts"] = parts
        uploads += parts
        os.remove(p)
    json.dump(m, open(os.path.join(dist, "manifest.json"), "w"), indent=1)
    os.remove(os.path.join(dist, "manifest.partial.json"))
    print("\n".join(uploads))


if __name__ == "__main__":
    main(sys.argv[1])
