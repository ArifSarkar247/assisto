#!/usr/bin/env python3
"""bnreview — apply a Bangla REVIEW proposal (changes to EXISTING bn values).

bin/arb_apply.py only adds new keys and refuses to overwrite. A Bangla review
changes existing bn text, so its proposal has its own shape:
  {"format": "bn_overwrite_v1",
   "groups": {"<feature>": {"<key>": {"bn": "new", "old": "current", "why": "..."}}}}
Rules: only app_bn.arb is written (English, keys and @metadata never change);
the key must already exist; the {placeholders} and ICU brace count must be
identical; a key whose current bn is no longer "old" is SKIPPED (someone else
changed it — re-review instead of clobbering). Usage (from the repo root):
  python3 app/tool/bn_review_apply.py [--check] .phaseB/up_bnreview_arb.json
"""
import json
import os
import re
import sys

args = sys.argv[1:]
check = "--check" in args
args = [a for a in args if a != "--check"]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
path = os.path.join(root, "lib", "l10n", "app_bn.arb")
arb = json.load(open(path, encoding="utf-8"))


def skel(s):
    return (sorted(re.findall(r"\{([A-Za-z_]\w*)", s)), s.count("{"), s.count("}"))


applied = skipped = bad = 0
for prop in args:
    d = json.load(open(prop, encoding="utf-8"))
    if d.get("format") != "bn_overwrite_v1" or not isinstance(d.get("groups"), dict):
        print("BAD FORMAT %s: need format=bn_overwrite_v1 + groups" % prop)
        sys.exit(1)
    for group, items in d["groups"].items():
        for k, ch in items.items():
            cur = arb.get(k)
            if cur is None or k.startswith("@"):
                print("BAD %s: no such bn key" % k)
                bad += 1
                continue
            if cur != ch["old"]:
                print("SKIP %s (%s): bn changed since review" % (k, group))
                skipped += 1
                continue
            if skel(ch["bn"]) != skel(cur):
                print("BAD %s: placeholders/ICU differ" % k)
                bad += 1
                continue
            arb[k] = ch["bn"]
            applied += 1
if bad:
    sys.exit(1)
if not check:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(arb, f, ensure_ascii=False, indent=2)
        f.write("\n")
print("bn review: %d applied, %d skipped%s" % (applied, skipped, " (check only)" if check else ""))
