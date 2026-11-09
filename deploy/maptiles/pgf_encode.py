"""Pre-shape Bangla text for MapLibre ("Positioned Glyph Font", wipfli/pgf-encoding, CC0).

MapLibre cannot shape Bengali script, so labels are shaped here with HarfBuzz and each
positioned glyph is replaced by the Private-Use codepoint that the PGF glyph PBFs
(font stack "Noto Sans Bengali Regular v1") draw. Same algorithm as protomaps
TextEngine.java (+-4 unit tolerance search), so tiles and app overlays match.

    enc = PgfEncoder("NotoSansBengali-Regular.ttf", "NotoSansBengali-Regular-v1.csv")
    enc.encode("মতিঝিল")   -> PUA string, or None if any glyph is not in the encoding

Usage from the shell (one label per line on stdin -> JSON lines on stdout):
    python pgf_encode.py FONT.ttf ENC.csv < labels.txt
"""
import csv
import json
import sys

import uharfbuzz as hb

# Same search order as protomaps TextEngine.deltas: (x_offset delta, x_advance delta).
_DELTAS = [(0, 0), (-1, 0), (0, 1), (0, -1), (1, 0), (-2, 0), (-1, 1), (-1, -1), (0, 2), (0, -2),
           (1, 1), (1, -1), (2, 0), (-3, 0), (-2, 1), (-2, -1), (-1, 2), (-1, -2), (0, 3), (0, -3),
           (1, 2), (1, -2), (2, 1), (2, -1), (3, 0), (-4, 0), (-3, 1), (-3, -1), (-2, 2), (-2, -2),
           (-1, 3), (-1, -3), (0, 4), (0, -4), (1, 3), (1, -3), (2, 2), (2, -2), (3, 1), (3, -1), (4, 0)]


def is_bengali(text):
    return any("ঀ" <= ch <= "৿" for ch in text or "")


class PgfEncoder:
    def __init__(self, font_path, encoding_csv):
        blob = hb.Blob.from_file_path(font_path)
        self.font = hb.Font(hb.Face(blob))
        self.upem = self.font.face.upem
        self.enc = {}
        with open(encoding_csv, newline="") as f:
            for r in csv.DictReader(f):
                key = (int(r["index"]), int(r["x_offset"]), int(r["y_offset"]),
                       int(r["x_advance"]), int(r["y_advance"]))
                self.enc[key] = int(r["codepoint"])

    def _lookup(self, idx, xo, yo, xa, ya):
        for dxo, dxa in _DELTAS:
            for y in (yo, 0):
                cp = self.enc.get((idx, xo + dxo, y, xa + dxa, ya))
                if cp is not None:
                    return cp
        return None

    def encode(self, text):
        """PUA string for a Bengali-script label; None if it cannot be encoded exactly."""
        if not text:
            return None
        buf = hb.Buffer()
        buf.add_str(text)
        buf.guess_segment_properties()
        hb.shape(self.font, buf, {})
        scale = 1000.0 / self.upem
        out = []
        for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
            cp = self._lookup(info.codepoint, int(pos.x_offset * scale // 1), int(pos.y_offset * scale // 1),
                              int(pos.x_advance * scale // 1), int(pos.y_advance * scale // 1))
            if cp is None:
                return None  # never draw a half-encoded (broken) label
            out.append(chr(cp))
        return "".join(out)


if __name__ == "__main__":
    enc = PgfEncoder(sys.argv[1], sys.argv[2])
    for line in sys.stdin:
        label = line.rstrip("\n")
        print(json.dumps({"label": label, "pgf": enc.encode(label)}, ensure_ascii=False))
