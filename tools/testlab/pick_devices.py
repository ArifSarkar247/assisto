#!/usr/bin/env python3
"""tl1: choose a Firebase Test Lab device matrix from the LIVE catalog.

Input: the JSON from `gcloud firebase test android models list --format=json`
(each model has id, brand, manufacturer, name, form PHYSICAL|VIRTUAL|EMULATOR,
supportedVersionIds ["26", ...], supportedAbis, tags ["default",
"deprecated=30", ...]).

Output (stdout, one per line):  model=<id>,version=<api>,locale=en,orientation=portrait
and a human report on stderr (catalog brands present, what was picked, gaps).

Rules (owner: every Android phone common in Bangladesh, Android 8-16):
  * brands in BD priority order: Samsung, Xiaomi/Redmi/POCO, OPPO, vivo/iQOO,
    realme, OnePlus, Infinix/Tecno/itel, then motorola / Google as fallbacks;
  * PHYSICAL devices whose ABI list can run the APK (arm64-v8a for the shipped
    APK) and not deprecated; per brand pick the models that add the most NEW
    API levels inside [min_api, max_api] (Android 8 = 26 ... Android 16 = 36);
  * then one VIRTUAL device per API level still uncovered (ARM virtual
    devices preferred for an arm64 APK; x86 ones for the x86_64 smoke APK);
  * --set smoke = 3 devices (2 physical brands + 1 low-API virtual);
    --set full = everything above, capped by --max-physical/--max-virtual so
    a Spark (free) project stays inside its daily quota.

Pure stdlib; tested by tools/testlab/test_testlab.py.
"""
import argparse
import json
import re
import sys

BRANDS = [  # (label, regex on brand+manufacturer, lower-cased)
    ("Samsung", r"samsung"),
    ("Xiaomi/Redmi/POCO", r"xiaomi|redmi|poco"),
    ("OPPO", r"\boppo\b"),
    ("vivo/iQOO", r"\bvivo\b|iqoo"),
    ("realme", r"realme"),
    ("OnePlus", r"oneplus"),
    ("Infinix/Tecno/itel", r"infinix|tecno|itel|transsion"),
    ("motorola", r"motorola|\bmoto\b"),
    ("Google", r"google|pixel"),
]


def brand_of(m):
    s = ("%s %s" % (m.get("brand", ""), m.get("manufacturer", ""))).lower()
    for label, rx in BRANDS:
        if re.search(rx, s):
            return label
    return None


def versions(m, lo, hi):
    out = []
    for v in m.get("supportedVersionIds") or []:
        try:
            n = int(v)
        except (TypeError, ValueError):
            continue
        if lo <= n <= hi:
            out.append(n)
    return sorted(set(out))


def deprecated(m):
    return any(str(t).startswith("deprecated") for t in (m.get("tags") or []))


def runs_abi(m, abi):
    abis = m.get("supportedAbis") or []
    if not abis:
        return True  # catalog didn't say: let Test Lab decide
    if abi == "arm64-v8a":
        return "arm64-v8a" in abis
    if abi == "x86_64":
        return "x86_64" in abis
    return True


def device(mid, api):
    return "model=%s,version=%d,locale=en,orientation=portrait" % (mid, api)


def pick(catalog, dset="full", abi="arm64-v8a", lo=26, hi=36,
         max_physical=5, max_virtual=10, per_brand=2):
    report = []
    phys = [m for m in catalog
            if m.get("form") == "PHYSICAL" and not deprecated(m) and runs_abi(m, abi)]
    virt = [m for m in catalog
            if m.get("form") in ("VIRTUAL", "EMULATOR") and not deprecated(m)
            and runs_abi(m, abi)]
    present = sorted({(m.get("brand") or m.get("manufacturer") or "?") for m in catalog})
    report.append("catalog brands: " + ", ".join(present))

    by_brand = {}
    for m in phys:
        b = brand_of(m)
        if b:
            by_brand.setdefault(b, []).append(m)
    for label, _ in BRANDS:
        n = len(by_brand.get(label, []))
        report.append("  %-20s %d physical model(s)%s" % (
            label, n, "" if n else "  <- NOT in Test Lab"))

    # Round-robin over brands (one model per brand per round) so a quota cap
    # keeps brand variety; each pick runs at the API level it adds that is
    # still uncovered (lowest first), else its newest supported level.
    covered, picked = set(), []
    left = {label: list(by_brand.get(label, [])) for label, _ in BRANDS}
    for rnd in range(per_brand):
        for label, _ in BRANDS:
            best, best_api, best_gain = None, None, -1
            for m in left[label]:
                vs = versions(m, lo, hi)
                if not vs:
                    continue
                new = [v for v in vs if v not in covered]
                api = min(new) if new else max(vs)
                if len(new) > best_gain:
                    best, best_api, best_gain = m, api, len(new)
            if best is None or (rnd > 0 and best_gain == 0):
                continue
            left[label] = [m for m in left[label] if m is not best]
            picked.append((label, best, best_api, "PHYSICAL"))
            covered.add(best_api)

    if dset == "smoke":
        # Samsung + the first Chinese-OEM brand present, one low-API virtual.
        chinese = ("Xiaomi/Redmi/POCO", "OPPO", "vivo/iQOO", "realme", "OnePlus",
                   "Infinix/Tecno/itel")
        first = [p for p in picked if p[0] == "Samsung"][:1]
        second = ([p for p in picked if p[0] in chinese][:1]
                  or [p for p in picked if p not in first][:1])
        picked = first + second
    else:
        picked = picked[:max_physical]

    vpicked = []
    if virt:
        def vrank(m):
            mid = str(m.get("id", ""))
            arm = ".arm" in mid.lower()
            pref = 0 if (arm and abi == "arm64-v8a") or (not arm and abi != "arm64-v8a") else 1
            return (pref, 0 if "mediumphone" in mid.lower() else 1, mid)
        virt.sort(key=vrank)
        need = [a for a in range(lo, hi + 1) if a not in {p[2] for p in picked}]
        if dset == "smoke":
            need = need[:1]
        for api in need:
            for m in virt:
                if api in versions(m, lo, hi):
                    vpicked.append(("virtual", m, api, "VIRTUAL"))
                    break
            if len(vpicked) >= (1 if dset == "smoke" else max_virtual):
                break
    allp = picked + vpicked
    uncovered = [a for a in range(lo, hi + 1) if a not in {p[2] for p in allp}]
    for label, m, api, form in allp:
        report.append("pick %-8s %-20s %-24s API %d  (%s)" % (
            form, label, "%s %s" % (m.get("id"), m.get("name", "")), api, m.get("brand", "")))
    if uncovered:
        report.append("API levels not covered by any device: %s" % uncovered)
    return [device(m["id"], api) for _, m, api, _ in allp], report


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("--set", default="full", choices=["smoke", "full"])
    ap.add_argument("--abi", default="arm64-v8a")
    ap.add_argument("--min-api", type=int, default=26)
    ap.add_argument("--max-api", type=int, default=36)
    ap.add_argument("--max-physical", type=int, default=5)
    ap.add_argument("--max-virtual", type=int, default=10)
    ap.add_argument("--form", default="all", choices=["all", "physical", "virtual"])
    a = ap.parse_args(argv)
    cat = json.load(open(a.catalog))
    devs, report = pick(cat, a.set, a.abi, a.min_api, a.max_api,
                        a.max_physical, a.max_virtual)
    print("\n".join(report), file=sys.stderr)
    if a.form != "all":
        phys_ids = {m["id"] for m in cat if m.get("form") == "PHYSICAL"}
        devs = [d for d in devs if (d.split(",")[0][6:] in phys_ids) == (a.form == "physical")]
    print("\n".join(devs))


if __name__ == "__main__":
    main()
