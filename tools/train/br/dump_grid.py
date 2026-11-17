import sys, re, json, collections
# Needs PyMuPDF (pip install pymupdf) — run by hand only, never in CI or on the server.
sys.path.insert(0, sys.argv[1])
from bijoy_fix import fix
import pymupdf
from gridlib import grid, idx
d = pymupdf.open(sys.argv[2])
KU = ('̲', '̳')
out = {}
for pi in [int(x) for x in sys.argv[3].split(',')]:
    p = d[pi]; xs, ys = grid(p)
    cells = collections.defaultdict(list)
    for w in p.get_text('words'):
        c = idx(xs, (w[0]+w[2])/2); r = idx(ys, (w[1]+w[3])/2)
        if c is None or r is None: continue
        cells[(r, c)].append(w)
    rows = []
    for r in range(len(ys)-1):
        row = []; carry = ''
        for c in range(len(xs)-1):
            ws = sorted(cells.get((r, c), []), key=lambda w: (round(w[1]/3), w[0]))
            parts = []
            for w in ws:
                t = carry + w[4]; carry = ''
                while t.endswith(KU): carry += t[-1]; t = t[:-1]
                if t: parts.append(fix(t))
            row.append(' '.join(parts))
        if any(row): rows.append(row)
    out[pi] = rows
    print('== page', pi)
    for row in rows: print(' | '.join(row))
json.dump(out, open(sys.argv[4], 'w'), ensure_ascii=False)
