"""Overture Maps -> Bangladesh extracts (CI only, never on the server).

  python overture_extract.py boundary OUT_DIR       -> bd.geojson (country + ~3 km buffer, simplified ~1 km)
  python overture_extract.py buildings OUT_DIR      -> buildings.fgb (h, mh, hs)
  python overture_extract.py places OUT_DIR FONT ENC -> places.geojson (name, pgf_name, cat, conf)

Release = newest under s3://overturemaps-us-west-2/release/ (or $OVERTURE_RELEASE).
Licences per theme (checked 10 Nov 2026, docs.overturemaps.org/attribution):
divisions / buildings = ODbL 1.0; places = CDLA-Permissive-2.0.
"""
import json
import os
import re
import sys
import urllib.request

import duckdb

BBOX = (88.0, 20.55, 92.75, 26.65)  # lon/lat box around Bangladesh
S3 = "s3://overturemaps-us-west-2/release"


def latest_release():
    rel = os.environ.get("OVERTURE_RELEASE", "").strip()
    if rel:
        return rel
    url = "https://overturemaps-us-west-2.s3.amazonaws.com/?list-type=2&prefix=release/&delimiter=/"
    xml = urllib.request.urlopen(url, timeout=60).read().decode()
    rels = sorted(re.findall(r"<Prefix>release/(\d{4}-\d{2}-\d{2}\.\d+)/</Prefix>", xml))
    if not rels:
        sys.exit("no Overture release found")
    return rels[-1]


def connect():
    con = duckdb.connect()
    for ext in ("spatial", "httpfs"):
        con.execute(f"INSTALL {ext}; LOAD {ext};")
    con.execute("SET s3_region='us-west-2'; SET preserve_insertion_order=false;")
    return con


def bbox_where():
    x0, y0, x1, y1 = BBOX
    return (f"bbox.xmin < {x1} AND bbox.xmax > {x0} "
            f"AND bbox.ymin < {y1} AND bbox.ymax > {y0}")


def boundary(out):
    rel = latest_release()
    con = connect()
    row = con.execute(f"""
        SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(ST_Buffer(ST_Union_Agg(geometry), 0.03), 0.01))
        FROM read_parquet('{S3}/{rel}/theme=divisions/type=division_area/*', hive_partitioning=1)
        WHERE country = 'BD' AND subtype = 'country' AND {bbox_where()}
    """).fetchone()
    if not row or not row[0]:
        sys.exit("Bangladesh boundary not found in Overture divisions")
    geom = json.loads(row[0])
    with open(os.path.join(out, "bd.geojson"), "w") as f:
        json.dump({"type": "Feature", "properties": {"source": "Overture divisions " + rel},
                   "geometry": geom}, f)
    with open(os.path.join(out, "overture_release.txt"), "w") as f:
        f.write(rel)
    print("boundary ok", rel)


def _bd_cte(out):
    return f"bd AS (SELECT ST_GeomFromGeoJSON(json_extract(content, '$.geometry')) AS g FROM read_text('{out}/bd.geojson'))"


def buildings(out):
    rel = open(os.path.join(out, "overture_release.txt")).read().strip()
    con = connect()
    dst = os.path.join(out, "buildings.fgb")
    con.execute(f"""
        COPY (
          WITH {_bd_cte(out)}
          SELECT
            ROUND(COALESCE(b.height, b.num_floors * 3.0), 1) AS h,
            ROUND(COALESCE(b.min_height, 0), 1) AS mh,
            CASE WHEN b.height IS NOT NULL THEN 'data'
                 WHEN b.num_floors IS NOT NULL THEN 'floors' ELSE 'none' END AS hs,
            b.geometry AS geometry
          FROM read_parquet('{S3}/{rel}/theme=buildings/type=building/*', hive_partitioning=1) b, bd
          WHERE {bbox_where().replace('bbox.', 'b.bbox.')}
            AND ST_Intersects(ST_Centroid(b.geometry), bd.g)
        ) TO '{dst}' WITH (FORMAT GDAL, DRIVER 'FlatGeobuf', SRS 'EPSG:4326')
    """)
    n = con.execute(f"SELECT count(*), count(h), sum(CASE WHEN hs='data' THEN 1 ELSE 0 END) FROM ST_Read('{dst}')").fetchone()
    stats = {"buildings": n[0], "with_height": n[1], "with_measured_height": n[2], "release": rel}
    json.dump(stats, open(os.path.join(out, "buildings_stats.json"), "w"))
    print("buildings", stats)


def places(out, font, enc):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from pgf_encode import PgfEncoder, is_bengali
    pgf = PgfEncoder(font, enc)
    rel = open(os.path.join(out, "overture_release.txt")).read().strip()
    con = connect()
    src = f"read_parquet('{S3}/{rel}/theme=places/type=place/*', hive_partitioning=1)"
    cols = {r[0] for r in con.execute(f"DESCRIBE SELECT * FROM {src} LIMIT 0").fetchall()}
    cat = "categories.primary" if "categories" in cols else ("basic_category" if "basic_category" in cols else "NULL")
    cur = con.execute(f"""
        WITH {_bd_cte(out)}
        SELECT p.names.primary, p.names.common['bn'], {cat}, p.confidence, ST_X(p.geometry), ST_Y(p.geometry)
        FROM {src} p, bd
        WHERE {bbox_where().replace('bbox.', 'p.bbox.')} AND p.confidence >= 0.7
          AND ST_Intersects(p.geometry, bd.g)
    """)
    n = shaped = 0
    with open(os.path.join(out, "places.geojson"), "w", encoding="utf-8") as f:
        while True:
            rows = cur.fetchmany(20000)
            if not rows:
                break
            for name, name_bn, category, conf, x, y in rows:
                if not name:
                    continue
                props = {"name": name, "cat": category or "", "conf": round(conf or 0, 2)}
                bn = name_bn if isinstance(name_bn, str) and name_bn else (name if is_bengali(name) else None)
                if bn:
                    enc_s = pgf.encode(bn)
                    if enc_s:
                        props["pgf_name"] = enc_s
                        shaped += 1
                if is_bengali(name):
                    props["name"] = ""  # raw Bengali never drawn unshaped
                f.write(json.dumps({"type": "Feature", "properties": props,
                                    "geometry": {"type": "Point", "coordinates": [round(x, 6), round(y, 6)]}},
                                   ensure_ascii=False) + "\n")
                n += 1
    json.dump({"places": n, "bangla_shaped": shaped, "release": rel},
              open(os.path.join(out, "places_stats.json"), "w"))
    print("places", n, "shaped", shaped)


if __name__ == "__main__":
    cmd, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    if cmd == "boundary":
        boundary(out)
    elif cmd == "buildings":
        buildings(out)
    elif cmd == "places":
        places(out, sys.argv[3], sys.argv[4])
    else:
        sys.exit("unknown command")
