#!/usr/bin/env python3
"""
STRICT LANGUAGE gate. Fails (exit 1) if:
  (a) Bangla characters (U+0980–U+09FF) appear in any Dart file outside lib/l10n/,
  (b) any ARB key is present in one of app_bn.arb / app_en.arb but missing in the other,
  (c) any Dart string literal joins both scripts (Bangla + Latin) with '/'.
Run from the app/ dir (or pass it). Prints every violation with file:line.
"""
import glob
import json
import os
import re
import sys

APP = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..")
LIB = os.path.join(APP, "lib")
L10N = os.path.join(LIB, "l10n")
BN = re.compile(r"[\u0980-\u09F2\u09F4-\u09FF]")  # ৳ (U+09F3) currency sign allowed in both langs
# a literal that has Bangla, then '/', then a Latin letter (combined label)
MIXED = re.compile(r"[\u0980-\u09F2\u09F4-\u09FF][^\"']*?/[^\"']*?[A-Za-z]|[A-Za-z][^\"']*?/[^\"']*?[\u0980-\u09F2\u09F4-\u09FF]")  # ৳ exempt

viol = []

# (a) + (c): scan Dart files outside l10n/
for f in glob.glob(os.path.join(LIB, "**", "*.dart"), recursive=True):
    if os.path.abspath(f).startswith(os.path.abspath(L10N)):
        continue
    for i, line in enumerate(open(f, encoding="utf-8"), 1):
        if BN.search(line):
            viol.append((f, i, "BANGLA-IN-DART", line.strip()[:90]))
        if MIXED.search(line):
            viol.append((f, i, "MIXED-/", line.strip()[:90]))

# (b): ARB key parity
try:
    en = {k for k in json.load(open(os.path.join(L10N, "app_en.arb"))) if not k.startswith("@")}
    bn = {k for k in json.load(open(os.path.join(L10N, "app_bn.arb"))) if not k.startswith("@")}
    for k in sorted(en - bn):
        viol.append(("app_bn.arb", 0, "KEY-MISSING-BN", k))
    for k in sorted(bn - en):
        viol.append(("app_en.arb", 0, "KEY-MISSING-EN", k))
except FileNotFoundError as e:
    viol.append((str(e), 0, "ARB-MISSING", ""))

by_kind = {}
for f, i, kind, txt in viol:
    by_kind.setdefault(kind, 0)
    by_kind[kind] += 1

if viol:
    for f, i, kind, txt in viol[:400]:
        rel = f.replace(APP + "/", "").replace(os.path.abspath(APP) + "/", "")
        print(f"{rel}:{i}: {kind}: {txt}")
    print(f"\nLANG GATE: {len(viol)} violations {dict(by_kind)}")
    sys.exit(1)
print("LANG GATE: clean ✓")
