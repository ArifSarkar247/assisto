#!/usr/bin/env python3
"""Replay android.yml's build-apk preparation steps VERBATIM (m2-reality).

reality.yml must build the exact same Android project the shipped APK is built
from (flutter create + native overlay + manifest patch + gradle patches). To
never diverge, this script reads .github/workflows/android.yml, picks the named
steps of job `build-apk` in their original order, and runs each step's `run:`
script with bash in its `working-directory`. A missing step = hard failure
(the two workflows drifted apart — fix this list, don't fork the logic).

usage: replay_android_steps.py [--list]
"""
import os
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WANT = [  # name prefixes, in android.yml order
    "Generate Android platform files",
    "Apply native overlay",
    "Pub get",
    "Generate launcher icons",
    "Generate splash screen",
    "Patch manifest",
    "Enable core library desugaring",
    "Apply google-services Gradle plugin",
    "Crash reporting (sc1)",          # manifest meta (Gradle plugin only with Firebase config)
    "Photo Studio native deps",       # onnxruntime + ML Kit face detection (PhotoFaces.kt)
]


def main():
    wf = yaml.safe_load((ROOT / ".github/workflows/android.yml").read_text())
    steps = wf["jobs"]["build-apk"]["steps"]
    picked = []
    for prefix in WANT:
        hit = [s for s in steps if str(s.get("name", "")).startswith(prefix)]
        if len(hit) != 1:
            sys.exit(f"replay: android.yml step '{prefix}' not found exactly once "
                     f"(found {len(hit)}) — workflows drifted")
        picked.append(hit[0])
    if "--list" in sys.argv:
        for s in picked:
            print(s["name"])
        return
    for s in picked:
        if "${{" in s["run"]:
            sys.exit(f"replay: step '{s['name']}' uses a GitHub expression; cannot replay")
        cwd = ROOT / s.get("working-directory", ".")
        print(f"::group::replay: {s['name']}", flush=True)
        r = subprocess.run(["bash", "-eo", "pipefail", "-c", s["run"]], cwd=cwd,
                           env={**os.environ, **{k: str(v) for k, v in (s.get("env") or {}).items()
                                                 if "${{" not in str(v)}})
        print("::endgroup::", flush=True)
        if r.returncode != 0:
            sys.exit(f"replay: step '{s['name']}' failed ({r.returncode})")


if __name__ == "__main__":
    main()
