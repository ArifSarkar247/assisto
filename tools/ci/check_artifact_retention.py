#!/usr/bin/env python3
"""ghstore (owner 17 Nov 00:15, GitHub artifact storage): every
actions/upload-artifact step in .github/workflows must set retention-days
between 1 and 30.  Classes: test outputs (logs, junit, coverage, e2e results,
proof files) = 2 days; screenshots and reports = 5 days; release AAB / signed
APK / mapping / installers = 30 days.  Pure text parsing (no PyYAML needed).
Exit 1 with a GitHub ::error:: line per offending step."""
import glob, os, re, sys

MAX_DAYS = 30
STEP_RE = re.compile(r"^(\s*)-\s")
USES_RE = re.compile(r"^\s*(?:-\s+)?uses:\s*['\"]?actions/upload-artifact@")
RET_RE = re.compile(r"retention-days:\s*['\"]?([^\s,'\"}]+)")


def indent(s):
    return len(s) - len(s.lstrip())


def check_file(path):
    errors = []
    lines = open(path, encoding="utf-8").read().split("\n")
    for i, line in enumerate(lines):
        if not USES_RE.match(line):
            continue
        s = i  # find the step's "- " line
        while s > 0 and not STEP_RE.match(lines[s]):
            s -= 1
        dash = indent(lines[s])
        e = s + 1  # step ends at the next line indented <= the dash
        while e < len(lines) and (not lines[e].strip() or lines[e].lstrip().startswith("#")
                                  or indent(lines[e]) > dash):
            e += 1
        vals = [m.group(1) for ln in lines[s:e] for m in [RET_RE.search(ln)] if m]
        where = f"{path}:{i + 1}"
        if not vals:
            errors.append(f"{where}: upload-artifact step has no retention-days")
            continue
        v = vals[0]
        if not v.isdigit():
            errors.append(f"{where}: retention-days must be a plain number 1-{MAX_DAYS}, got {v!r}")
        elif not 1 <= int(v) <= MAX_DAYS:
            errors.append(f"{where}: retention-days {v} is outside 1-{MAX_DAYS}")
    return errors


def main(root="."):
    files = sorted(glob.glob(os.path.join(root, ".github/workflows/*.y*ml")))
    files += sorted(glob.glob(os.path.join(root, ".github/actions/**/*.y*ml"), recursive=True))
    errors = [e for f in files for e in check_file(f)]
    for e in errors:
        print(f"::error::{e}")
    n = sum(1 for f in files for ln in open(f, encoding="utf-8") if USES_RE.match(ln))
    print(f"artifact retention guard: {n} upload-artifact steps in {len(files)} files, {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
