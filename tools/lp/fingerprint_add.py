#!/usr/bin/env python3
"""Add known published texts to the copyright fingerprint list — as HASHES only.

    python3 tools/lp/fingerprint_add.py --label "Book X, test 3 passage 1 opening" text1.txt [text2.txt ...]

Each text is normalised (lowercase, punctuation removed) and cut into overlapping 8-word shingles; only a
24-hex SHA-256 prefix of each shingle is stored in fingerprints/known_hashes.json, so no published text
ever enters git. Keep the source .txt files OUTSIDE the repo. lpcheck.py fails any bundle that contains
one of these shingles. Typing in the first 2-3 sentences of each known passage/script is enough.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lpcheck import FINGERPRINTS, shingle_hash, shingles  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True, help="what the texts are (stored, no text)")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args(argv)
    try:
        d = json.load(open(FINGERPRINTS, encoding="utf-8"))
    except FileNotFoundError:
        d = {"format": "assisto.lp.fingerprints/1", "shingle_words": 8, "sources": [], "hashes": []}
    have = set(d["hashes"])
    added = 0
    for f in a.files:
        for sh in shingles(open(f, encoding="utf-8").read()):
            h = shingle_hash(sh)
            if h not in have:
                have.add(h)
                added += 1
    d["sources"].append({"label": a.label, "files": len(a.files), "new_hashes": added})
    d["hashes"] = sorted(have)
    with open(FINGERPRINTS, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=0)
    print(f"added {added} hashes ({len(have)} total)")


if __name__ == "__main__":
    main()
