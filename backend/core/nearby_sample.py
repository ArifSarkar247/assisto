"""gap-nearby: a tiny MADE-UP emergency list around the sample Farmgate point
for the CI emulator only (seed_reality -> the `nearbycity` reality group).
Never imported on the live server. Names say "Sample"; the only number is
the national emergency number 999 (official, emergency_numbers.dart BD)."""
import gzip
import json

from . import nearby_list as NL

ROWS = [
    ["s-h1", "hospital", "নমুনা হাসপাতাল এক", "Sample Hospital One", 23.7590, 90.3905, ""],
    ["s-h2", "hospital", "নমুনা হাসপাতাল দুই", "Sample Hospital Two", 23.7650, 90.3950, ""],
    ["s-h3", "hospital", "", "", 23.7700, 90.3990, ""],          # unnamed (as in OSM)
    ["s-p1", "police", "নমুনা থানা", "Sample Police Station", 23.7580, 90.3880, "999"],
    ["s-f1", "fire", "নমুনা ফায়ার স্টেশন", "Sample Fire Station", 23.7520, 90.3920, ""],
]


def import_sample():
    doc = {"country": "BD", "fields": ["id", "cat", "name", "name_en", "lat", "lon", "phone"],
           "osm_timestamp": "2026-11-01T00:00:00Z", "rows": ROWS}
    return NL.import_blob("BD", gzip.compress(json.dumps(doc).encode()), force=True)
