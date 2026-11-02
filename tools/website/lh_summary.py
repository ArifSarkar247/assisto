"""Print the median Lighthouse category scores per URL (lhci filesystem manifest)."""
import json
import statistics
import sys
from collections import defaultdict

rows = json.load(open(sys.argv[1]))
by = defaultdict(lambda: defaultdict(list))
for r in rows:
    for k, v in r["summary"].items():
        by[r["url"]][k].append(v)
cats = ["performance", "accessibility", "best-practices", "seo"]
print("| URL | " + " | ".join(cats) + " |")
print("|---|" + "---|" * len(cats))
for url, s in by.items():
    print("| %s | %s |" % (url, " | ".join("%d" % round(100 * statistics.median(s[c])) for c in cats)))
