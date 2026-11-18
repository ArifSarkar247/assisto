#!/usr/bin/env python3
"""CI guard (lead 17 Nov): every workflow step that installs Flutter
(subosito/flutter-action) must pin the ONE toolchain version in
tools/ci/flutter_version.txt. An unpinned `channel: stable` let the release
build drift 3.47.9 -> 3.50.0 silently. Stdlib only (runs before setup-python)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
WANT = (ROOT / "tools/ci/flutter_version.txt").read_text().strip()
PIN = re.compile(r"""^\s*flutter-version:\s*['"]?([^'"\s#]+)""")
bad = []
for wf in sorted((ROOT / ".github/workflows").glob("*.yml")):
    lines = wf.read_text().split("\n")
    for i, line in enumerate(lines):
        if "subosito/flutter-action@" not in line:
            continue
        step_ind = len(line) - len(line.lstrip(" -"))
        got = None
        for nxt in lines[i + 1:]:
            if nxt.strip() and (len(nxt) - len(nxt.lstrip(" "))) <= step_ind - 2 or nxt.lstrip().startswith("- "):
                break
            m = PIN.match(nxt)
            if m:
                got = m.group(1)
        if got != WANT:
            bad.append("%s:%d flutter-version %r (want %r)" % (wf.name, i + 1, got, WANT))
if bad:
    print("Flutter toolchain not pinned to tools/ci/flutter_version.txt:")
    print("\n".join("  " + b for b in bad))
    sys.exit(1)
print("Flutter pinned to %s in every workflow" % WANT)
