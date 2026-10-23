#!/usr/bin/env python3
"""d1-photo: download the 20 licence-clean evaluation originals listed in
.phaseB/photo_studio_eval/sources.json (Wikimedia Commons thumbnails: 10 US
Congress official portraits = public domain, 10 CC0 photos). Polite: one
request per second, retries on HTTP 429. The photos are NOT committed.

  python3 tools/photo_eval/fetch_sources.py .phaseB/photo_studio_eval/sources.json <out dir>
"""
import json
import os
import sys
import time
import urllib.request

UA = "AssistoPhotoEval/1.0 (licence-clean test set; https://lifeassisto.com)"


def main():
    src = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    os.makedirs(out, exist_ok=True)
    for s in src:
        p = os.path.join(out, s["file"])
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            continue
        req = urllib.request.Request(s["thumb"], headers={"User-Agent": UA})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                with open(p, "wb") as fh:
                    fh.write(data)
                print(s["file"], s["licence"], len(data))
                break
            except Exception as e:  # noqa: BLE001
                print("retry", s["file"], e)
                time.sleep(5 * (attempt + 1))
        time.sleep(1)


if __name__ == "__main__":
    main()
