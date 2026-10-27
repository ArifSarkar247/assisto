#!/usr/bin/env python3
"""perf2gb: pull perf2gb.json out of a run log (`gh run view <id> --log`) when
the artifact cannot be downloaded (account egress cap).

usage: from_log.py <run.log> <out_dir>   -> <out_dir>/<profile>.json
"""
import base64
import gzip
import re
import sys
from pathlib import Path


def main():
    log, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    cur, buf = None, []
    for line in log.read_text(errors="replace").splitlines():
        body = re.sub(r"^.*?\d{4}-\d\d-\d\dT[\d:.]+Z ?", "", line)
        m = re.match(r"PERF2GB_JSON_(BEGIN|END) (\S+)", body)
        if m and m.group(1) == "BEGIN":
            cur, buf = m.group(2), []
        elif m and cur:
            (out / f"{cur}.json").write_bytes(gzip.decompress(base64.b64decode("".join(buf))))
            print("wrote", out / f"{cur}.json")
            cur = None
        elif cur:
            buf.append(body.strip())


if __name__ == "__main__":
    main()
