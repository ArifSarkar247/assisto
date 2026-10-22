#!/usr/bin/env python3
"""tl1: turn a Firebase Test Lab run into the testlab-summary.md table.

Inputs (all produced by .github/workflows/testlab.yml):
  --outcome FILE   stdout of `gcloud firebase test android run ... --format=json`
                   = a JSON list of {"axis_value": "a10-29-en-portrait",
                   "outcome": "Passed|Failed|Inconclusive|Skipped|Flaky",
                   "test_details": "..."} (one row per device)
  --log FILE       stderr of the same run (holds the Firebase console URL and
                   the GCS raw-results URL; optional)
  --catalog FILE   `gcloud firebase test android models list --format=json`
                   (model id -> brand + name; optional)
  --results DIR    local copy of the per-device result folders
                   (<DIR>/<axis_value>/logcat ...); used for crash detection
  --label TEXT     "physical" / "virtual" (a heading)
Output: markdown on stdout; exit 0 always (the workflow decides red/green from
the PASS/FAIL column via --fail-on-fail).

A device PASSES only when Test Lab says Passed/Flaky AND its logcat has no
crash of our app (Java FATAL EXCEPTION, native tombstone or ANR).
"""
import argparse
import json
import os
import re
import sys

PKG = "com.assisto.assisto"

ANDROID_NAMES = {
    26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11", 31: "12", 32: "12L",
    33: "13", 34: "14", 35: "15", 36: "16",
}


def split_axis(axis):
    """'MediumPhone.arm-30-en-portrait' -> ('MediumPhone.arm', 30, 'en', 'portrait')."""
    parts = axis.split("-")
    if len(parts) >= 4 and parts[-3].isdigit():
        return "-".join(parts[:-3]), int(parts[-3]), parts[-2], parts[-1]
    return axis, None, "", ""


def crash_from_logcat(text, pkg=PKG):
    """(crashed: bool, kind, top_frame) for OUR process only."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if "FATAL EXCEPTION" in ln and "AndroidRuntime" in ln:
            block = lines[i:i + 60]
            # "Process: com.x, PID: n" follows the FATAL line: ours only.
            if not any(("Process: " + pkg) in b for b in block[:6]):
                continue
            exc, top = "", ""
            for b in block[1:]:
                body = b.split("AndroidRuntime:", 1)[-1].strip()
                if not exc and re.match(r"^[\w.$]+(Exception|Error|Throwable)\b", body):
                    exc = body
                if body.startswith("at ") and not top:
                    top = body[3:]
                    break
            return True, "java", ("%s @ %s" % (exc, top)).strip(" @") or "FATAL EXCEPTION"
        if (">>> %s <<<" % pkg) in ln:  # native tombstone header (DEBUG tag)
            top = ""
            for b in lines[i:i + 120]:
                m = re.search(r"#00 pc [0-9a-f]+\s+(.*)$", b)
                if m:
                    top = m.group(1).strip()
                    break
            return True, "native", top or "native crash"
        if ("ANR in " + pkg) in ln:
            return True, "anr", "ANR (app not responding)"
    return False, "", ""


def console_urls(log):
    console = gcs = ""
    m = re.search(r"(https://console\.firebase\.google\.com/project/[^\s\]]+)", log or "")
    if m:
        console = m.group(1)
    m = re.search(r"(https://console\.developers\.google\.com/storage/browser/[^\s\]]+)", log or "")
    if not m:
        m = re.search(r"(https://console\.cloud\.google\.com/storage/browser/[^\s\]]+)", log or "")
    if m:
        gcs = m.group(1).rstrip("/") + "/"
    return console, gcs


def summarize(outcome, log="", catalog=None, results_dir=None, label=""):
    cat = {m.get("id"): m for m in (catalog or [])}
    console, gcs = console_urls(log)
    rows = []
    for r in outcome or []:
        axis = r.get("axis_value") or r.get("axisValue") or "?"
        res = (r.get("outcome") or "?").strip()
        details = (r.get("test_details") or r.get("testDetails") or "").strip()
        mid, api, _, _ = split_axis(axis)
        m = cat.get(mid, {})
        brand = m.get("brand") or m.get("manufacturer") or ""
        name = m.get("name") or mid
        form = m.get("form", "")
        crashed, kind, top = False, "", ""
        if results_dir:
            p = os.path.join(results_dir, axis, "logcat")
            if os.path.exists(p):
                crashed, kind, top = crash_from_logcat(open(p, errors="replace").read())
        if not crashed and re.search(r"crash", details, re.I):
            crashed, kind, top = True, "reported", details
        ok = res in ("Passed", "Flaky") and not crashed
        verdict = "PASS" if ok else ("FAIL" if res == "Failed" or crashed else res.upper() or "?")
        rows.append({
            "device": ("%s %s" % (brand, name)).strip(),
            "model": mid, "form": form,
            "android": ("%s (API %d)" % (ANDROID_NAMES.get(api, "?"), api)) if api else "?",
            "robo": res + ((" — " + details) if details and details != "--" else ""),
            "crash": ("yes (%s): %s" % (kind, top)) if crashed else "no",
            "shots": (gcs + axis + "/") if gcs else (console or ""),
            "verdict": verdict,
        })
    out = []
    out.append("### Firebase Test Lab — %s" % (label or "matrix"))
    if console:
        out.append("Console (screenshots, video, Robo crawl graph): %s" % console)
    out.append("")
    out.append("| Device | Android | Robo outcome | Crash (top frame) | Screenshots | Result |")
    out.append("|---|---|---|---|---|---|")
    for r in rows:
        dev = "%s (`%s`%s)" % (r["device"], r["model"], ", " + r["form"].lower() if r["form"] else "")
        shots = "[open](%s)" % r["shots"] if r["shots"] else "—"
        cell = lambda s: s.replace("|", "\\|").replace("\n", " ")
        out.append("| %s | %s | %s | %s | %s | **%s** |" % (
            cell(dev), r["android"], cell(r["robo"]), cell(r["crash"]), shots, r["verdict"]))
    if not rows:
        out.append("| (no device results — see the run log) | | | | | **FAIL** |")
    npass = sum(1 for r in rows if r["verdict"] == "PASS")
    out.append("")
    out.append("%d/%d devices passed." % (npass, len(rows)))
    return "\n".join(out) + "\n", rows


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--outcome", required=True)
    ap.add_argument("--log", default="")
    ap.add_argument("--catalog", default="")
    ap.add_argument("--results", default="")
    ap.add_argument("--label", default="")
    ap.add_argument("--fail-on-fail", action="store_true")
    a = ap.parse_args(argv)
    try:
        outcome = json.load(open(a.outcome))
    except Exception as e:  # empty / not JSON: gcloud failed before results
        print("could not read outcome JSON: %s" % e, file=sys.stderr)
        outcome = []
    log = open(a.log, errors="replace").read() if a.log and os.path.exists(a.log) else ""
    cat = []
    if a.catalog and os.path.exists(a.catalog):
        try:
            cat = json.load(open(a.catalog))
        except Exception:
            cat = []
    md, rows = summarize(outcome, log, cat, a.results or None, a.label)
    sys.stdout.write(md)
    if a.fail_on_fail and (not rows or any(r["verdict"] != "PASS" for r in rows)):
        sys.exit(1)


if __name__ == "__main__":
    main()
