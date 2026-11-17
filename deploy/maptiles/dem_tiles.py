"""Copernicus DEM GLO-30 -> terrarium raster-dem MBTiles for Bangladesh (CI only).

    python dem_tiles.py WORK_DIR OUT.mbtiles [MINZOOM MAXZOOM]

Downloads the 1x1 degree COG tiles from the public AWS Open Data bucket
(copernicus-dem-30m, no login, free), mosaics + warps them to Web Mercator with GDAL,
then cuts 256 px PNG tiles in Mapzen "terrarium" encoding (MapLibre raster-dem
encoding "terrarium"). Sea / no-data = 0 m.
Attribution: "© DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018
provided under COPERNICUS by the European Union and ESA; all rights reserved"
(GLO-30 public licence; see owner_actions/CITY_MAP_LICENSE_BN.md).
"""
import io
import math
import os
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request

import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling
from rasterio.windows import from_bounds

BBOX = (88.0, 20.55, 92.75, 26.65)
BASE = "https://copernicus-dem-30m.s3.amazonaws.com"
R = 6378137.0


def tile_name(lat, lon):
    return f"Copernicus_DSM_COG_10_N{lat:02d}_00_E{lon:03d}_00_DEM"


def download(work):
    paths = []
    for lat in range(math.floor(BBOX[1]), math.ceil(BBOX[3])):
        for lon in range(math.floor(BBOX[0]), math.ceil(BBOX[2])):
            name = tile_name(lat, lon)
            dst = os.path.join(work, name + ".tif")
            if not os.path.exists(dst):
                try:
                    urllib.request.urlretrieve(f"{BASE}/{name}/{name}.tif", dst)
                except urllib.error.HTTPError as e:
                    if e.code in (403, 404):  # open sea: no tile published
                        continue
                    raise
            paths.append(dst)
    print("DEM tiles", len(paths))
    return paths


def merc_bounds(z, x, y):
    n = 2 ** z
    size = 2 * math.pi * R / n
    minx = -math.pi * R + x * size
    maxy = math.pi * R - y * size
    return minx, maxy - size, minx + size, maxy


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    lat_r = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n)
    return x, y


def terrarium(h):
    h = np.nan_to_num(h, nan=0.0)
    h = np.clip(h, -500, 9000) + 32768.0
    r = np.floor(h / 256.0)
    g = np.floor(h - r * 256.0)
    b = np.floor((h - np.floor(h)) * 256.0)
    return np.dstack([r, g, b]).astype(np.uint8)


def main(work, out, minz=5, maxz=12):
    os.makedirs(work, exist_ok=True)
    tifs = download(work)
    vrt = os.path.join(work, "dem.vrt")
    merc = os.path.join(work, "dem_3857.tif")
    subprocess.run(["gdalbuildvrt", "-q", "-vrtnodata", "0", vrt] + tifs, check=True)
    res = 2 * math.pi * R / (256 * 2 ** maxz)
    subprocess.run(["gdalwarp", "-q", "-overwrite", "-t_srs", "EPSG:3857", "-tr", str(res), str(res),
                    "-r", "bilinear", "-dstnodata", "0", "-co", "TILED=YES", "-co", "COMPRESS=DEFLATE",
                    "-co", "BIGTIFF=YES", "-multi", "-wo", "NUM_THREADS=ALL_CPUS", vrt, merc], check=True)
    subprocess.run(["gdaladdo", "-q", "-r", "average", merc, "2", "4", "8", "16", "32", "64", "128"], check=True)

    if os.path.exists(out):
        os.remove(out)
    db = sqlite3.connect(out)
    db.executescript("""
        CREATE TABLE metadata (name text, value text);
        CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob);
        CREATE UNIQUE INDEX tile_index on tiles (zoom_level, tile_column, tile_row);
    """)
    meta = {"name": "Assisto terrain (Copernicus DEM GLO-30)", "format": "png", "type": "baselayer",
            "minzoom": str(minz), "maxzoom": str(maxz), "encoding": "terrarium",
            "bounds": ",".join(map(str, BBOX)),
            "attribution": "Copernicus DEM GLO-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH "
                           "2014-2018 provided under COPERNICUS by the European Union and ESA"}
    db.executemany("INSERT INTO metadata VALUES (?, ?)", meta.items())
    count = 0
    with rasterio.open(merc) as src:
        for z in range(minz, maxz + 1):
            x0, y0 = lonlat_to_tile(BBOX[0], BBOX[3], z)
            x1, y1 = lonlat_to_tile(BBOX[2], BBOX[1], z)
            for x in range(x0, x1 + 1):
                for y in range(y0, y1 + 1):
                    b = merc_bounds(z, x, y)
                    win = from_bounds(*b, transform=src.transform)
                    h = src.read(1, window=win, out_shape=(256, 256), boundless=True, fill_value=0,
                                 resampling=Resampling.bilinear).astype(np.float64)
                    buf = io.BytesIO()
                    Image.fromarray(terrarium(h), "RGB").save(buf, "PNG", optimize=True)
                    db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, x, (2 ** z - 1) - y, buf.getvalue()))
                    count += 1
            db.commit()
            print("z", z, "tiles so far", count)
    db.close()
    print("terrain tiles", count)


if __name__ == "__main__":
    a = sys.argv[1:]
    main(a[0], a[1], *(int(v) for v in a[2:4]))
