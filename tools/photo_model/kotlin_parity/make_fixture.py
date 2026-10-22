#!/usr/bin/env python3
"""Fixture for ParityMain.kt: photo.rgba (odd size, so edge tiles are partial),
ai.rgba / base.rgba (random), faces.txt, merged_py.rgba (Python merge)."""
import os
import struct
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from eval_photos import merge_keep_faces, to_rgba_file  # noqa: E402

d = sys.argv[1]
os.makedirs(d, exist_ok=True)
rng = np.random.default_rng(3)
to_rgba_file(Image.fromarray(rng.integers(0, 256, (157, 203, 3), dtype=np.uint8)),
             os.path.join(d, "photo.rgba"))
ai = Image.fromarray(rng.integers(0, 256, (120, 90, 3), dtype=np.uint8))
base = Image.fromarray(rng.integers(0, 256, (120, 90, 3), dtype=np.uint8))
faces = [(0.2, 0.15, 0.4, 0.35), (0.6, 0.55, 0.3, 0.3)]
to_rgba_file(ai, os.path.join(d, "ai.rgba"))
to_rgba_file(base, os.path.join(d, "base.rgba"))
to_rgba_file(merge_keep_faces(ai, base, faces), os.path.join(d, "merged_py.rgba"))
with open(os.path.join(d, "faces.txt"), "w") as f:
    for x in faces:
        f.write(",".join(str(v) for v in x) + "\n")
print("fixture in", d)
