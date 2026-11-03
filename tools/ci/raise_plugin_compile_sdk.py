#!/usr/bin/env python3
"""Raise every pub-cache Flutter plugin's hard-coded compileSdk below TARGET.

Some plugins pin an old compileSdk (in_app_review 33, geocoding_android 33)
while their androidx dependencies need >= 34, so checkReleaseAarMetadata fails
(builds 281 and 305). Only compileSdk changes; minSdk/targetSdk and plugin
behaviour stay the same. Values that read flutter.compileSdkVersion or are
already >= TARGET are left alone. Idempotent.
"""
import glob
import os
import re
import sys

TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 36
root = os.path.expanduser("~/.pub-cache/hosted")
pat = re.compile(r"(\bcompileSdk(?:Version)?\b)(\s*=?\s*)(\d+)")
changed = 0
for f in sorted(glob.glob(os.path.join(root, "*", "*", "android", "build.gradle"))
                + glob.glob(os.path.join(root, "*", "*", "android", "build.gradle.kts"))):
    with open(f, encoding="utf-8") as fh:
        s = fh.read()
    kts = f.endswith(".kts")

    def repl(m):
        if int(m.group(3)) >= TARGET:
            return m.group(0)
        if kts:
            return "compileSdk = %d" % TARGET
        return "compileSdkVersion %d" % TARGET

    n = pat.sub(repl, s)
    if n != s:
        with open(f, "w", encoding="utf-8") as fh:
            fh.write(n)
        changed += 1
        print("raised compileSdk -> %d: %s" % (TARGET, f))
print("plugins patched: %d" % changed)
