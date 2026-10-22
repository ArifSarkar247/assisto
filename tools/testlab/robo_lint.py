#!/usr/bin/env python3
"""tl1: lint a Firebase Test Lab Robo script before spending quota on it.

Checks: valid JSON; a list of script objects each with an "actions" list;
every action uses a known eventType and known element-descriptor keys; text
actions carry replacementText; WAIT / WAIT_FOR_ELEMENT carry delayTime; regex
descriptors compile; and every Flutter resource id we target ("tl_*") really
exists as a `RoboId(id: 'tl_…')` / Semantics identifier in app/lib (so a renamed widget
breaks CI here, not on a paid device). With --filled it also refuses any
__TL_*__ placeholder left unfilled.

usage: robo_lint.py SCRIPT.json [--lib app/lib] [--filled]
"""
import argparse
import glob
import json
import os
import re
import sys

EVENTS = {
    "VIEW_CLICKED", "VIEW_LONG_CLICKED", "VIEW_TEXT_CHANGED", "VIEW_SWIPED",
    "VIEW_SCROLLED", "PRESSED_BACK", "PRESSED_HOME", "PRESSED_EDITOR_ACTION",
    "DISABLE_KEYBOARD", "WAIT", "WAIT_FOR_ELEMENT", "DELAYED_MESSAGE_POSTED",
    "ONE_POINT_GESTURE", "ADB_SHELL_COMMAND", "ALL_ELEMENTS_CLICKED",
    "DOUBLE_CLICKED", "TOUCH",
}
DESC_KEYS = {
    "className", "groupViewChildPosition", "recyclerViewChildPosition",
    "adapterViewChildPosition", "resourceId", "resourceIdRegex",
    "contentDescription", "contentDescriptionRegex", "text", "textRegex",
}
ACTION_KEYS = {
    "eventType", "elementDescriptors", "optional", "replacementText",
    "delayTime", "swipeDirection", "pointTapXPercent", "pointTapYPercent",
    "command", "description", "maxNumberOfRuns",
}
SCRIPT_KEYS = {"id", "description", "crawlStage", "priority", "maxNumberOfRuns",
               "contextDescriptor", "actions"}


def flutter_ids(lib):
    ids = set()
    rx = re.compile(r"(?:identifier|RoboId\(id):\s*'(tl_[A-Za-z0-9_$]+)'")
    for f in glob.glob(os.path.join(lib, "**", "*.dart"), recursive=True):
        for m in rx.finditer(open(f, encoding="utf-8").read()):
            v = m.group(1)
            if "$code" in v:  # language picker: one id per language
                ids.update(v.replace("$code", c) for c in ("bn", "en"))
            else:
                ids.add(v)
    return ids


def lint(doc, ids=None, filled=False):
    errs = []
    if isinstance(doc, dict):
        doc = [doc]
    if not isinstance(doc, list) or not doc:
        return ["top level must be a non-empty list of scripts"]
    for si, sc in enumerate(doc):
        where = "script[%d]" % si
        if not isinstance(sc, dict) or not isinstance(sc.get("actions"), list):
            errs.append("%s: needs an 'actions' list" % where)
            continue
        for k in sc:
            if k not in SCRIPT_KEYS:
                errs.append("%s: unknown key %r" % (where, k))
        if sc.get("crawlStage", "crawl") not in ("pre_crawl", "crawl", "post_crawl"):
            errs.append("%s: bad crawlStage" % where)
        for ai, a in enumerate(sc["actions"]):
            w = "%s.action[%d]" % (where, ai)
            if not isinstance(a, dict):
                errs.append("%s: not an object" % w)
                continue
            ev = a.get("eventType")
            if ev not in EVENTS:
                errs.append("%s: unknown eventType %r" % (w, ev))
            for k in a:
                if k not in ACTION_KEYS:
                    errs.append("%s: unknown key %r" % (w, k))
            if ev == "VIEW_TEXT_CHANGED" and not isinstance(a.get("replacementText"), str):
                errs.append("%s: VIEW_TEXT_CHANGED needs replacementText" % w)
            if ev in ("WAIT", "WAIT_FOR_ELEMENT") and not isinstance(a.get("delayTime"), int):
                errs.append("%s: %s needs an integer delayTime (ms)" % (w, ev))
            needs_el = ev in ("VIEW_CLICKED", "VIEW_LONG_CLICKED", "VIEW_TEXT_CHANGED",
                              "WAIT_FOR_ELEMENT", "VIEW_SWIPED")
            descs = a.get("elementDescriptors")
            if needs_el and not (isinstance(descs, list) and descs):
                errs.append("%s: %s needs elementDescriptors" % (w, ev))
            for d in descs or []:
                if not isinstance(d, dict) or not d:
                    errs.append("%s: empty descriptor" % w)
                    continue
                for k, v in d.items():
                    if k not in DESC_KEYS:
                        errs.append("%s: unknown descriptor key %r" % (w, k))
                    if k.endswith("Regex"):
                        try:
                            re.compile(v)
                        except re.error as e:
                            errs.append("%s: bad regex %r: %s" % (w, v, e))
                rid = d.get("resourceId", "")
                if ids is not None and rid.startswith("tl_") and rid not in ids:
                    errs.append("%s: resourceId %r not found as a Semantics identifier in app/lib" % (w, rid))
            if filled and "__TL_" in json.dumps(a):
                errs.append("%s: unfilled __TL_*__ placeholder" % w)
    return errs


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("--lib", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "app", "lib"))
    ap.add_argument("--filled", action="store_true")
    a = ap.parse_args(argv)
    try:
        doc = json.load(open(a.script, encoding="utf-8"))
    except Exception as e:
        print("robo_lint: %s is not valid JSON: %s" % (a.script, e))
        return 1
    ids = flutter_ids(a.lib) if os.path.isdir(a.lib) else None
    errs = lint(doc, ids, a.filled)
    for e in errs:
        print("robo_lint: " + e)
    n = sum(len(s.get("actions", [])) for s in (doc if isinstance(doc, list) else [doc]))
    print("robo_lint: %s — %d action(s), %d problem(s)%s" % (
        os.path.basename(a.script), n, len(errs),
        "" if ids is not None else " (app/lib not found: ids not checked)"))
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
