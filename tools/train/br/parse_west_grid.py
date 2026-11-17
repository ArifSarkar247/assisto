"""Grid-based parse of the BR west-zone 'abbreviated intercity schedule' pages."""
# Needs PyMuPDF (pip install pymupdf) — run by hand only, never in CI or on the server.
import sys, re, json, collections
sys.path.insert(0, sys.argv[1])
from bijoy_fix import fix, num
import pymupdf
d = pymupdf.open(sys.argv[2])
pages = [int(x) for x in sys.argv[3].split(',')]
KU = ('̲', '̳')
def grid(p):
    xs = set(); ys = set()
    for dr in p.get_drawings():
        for it in dr['items']:
            if it[0] == 're':
                r = it[1]
                if r.width < 2 and r.height > 5: xs.add(round(r.x0))
                if r.height < 2 and r.width > 5: ys.add(round(r.y0))
            elif it[0] == 'l':
                a, b = it[1], it[2]
                if abs(a.x - b.x) < 1 and abs(a.y - b.y) > 5: xs.add(round(a.x))
                if abs(a.y - b.y) < 1 and abs(a.x - b.x) > 5: ys.add(round(a.y))
    def dedup(v):
        v = sorted(v); o = []
        for x in v:
            if not o or x - o[-1] > 3: o.append(x)
        return o
    return dedup(xs), dedup(ys)
def idx(edges, v):
    for i in range(len(edges) - 1):
        if edges[i] <= v < edges[i + 1]: return i
    return None
TIME = re.compile(r'^[0-9০-৯]{3,4}$')
blocks = []
for pi in pages:
    p = d[pi]; xs, ys = grid(p)
    cells = collections.defaultdict(list)
    for w in p.get_text('words'):
        cx = (w[0] + w[2]) / 2; cy = (w[1] + w[3]) / 2
        c = idx(xs, cx); r = idx(ys, cy)
        if c is None or r is None: continue
        cells[(r, c)].append(w)
    nrow = len(ys) - 1; ncol = len(xs) - 1
    def text(r, c):
        ws = sorted(cells.get((r, c), []), key=lambda w: (round(w[1]), w[0]))
        raw = ''; carry = ''
        parts = []
        for w in ws:
            t = carry + w[4]; carry = ''
            while t.endswith(KU): carry += t[-1]; t = t[:-1]
            if t: parts.append(fix(t))
        return ' '.join(parts)
    header = None
    for r in range(nrow):
        c0 = [w for w in cells.get((r, 0), [])] + [w for w in cells.get((r, 1), [])]
        tno = [w for w in cells.get((r, 0), []) if num(w[4])]
        names = [text(r, c) for c in range(2, ncol)]
        if not tno and any(re.search(r'[ক-হড়-য়]', n) for n in names):
            # carry KU across header cells too
            hdr = []; carry = ''
            for c in range(2, ncol):
                ws = sorted(cells.get((r, c), []), key=lambda w: w[0])
                rawparts = []
                for w in ws:
                    t = carry + w[4]; carry = ''
                    while t.endswith(KU): carry += t[-1]; t = t[:-1]
                    if t: rawparts.append(fix(t))
                hdr.append(' '.join(rawparts))
            header = hdr
            continue
        if tno and header:
            no = num(tno[0][4])
            top = ys[r]; bot = ys[r + 1]; mid = (top + bot) / 2
            stops = []
            for c in range(2, ncol):
                name = header[c - 2]
                ws = cells.get((r, c), [])
                if re.fullmatch(r'[0-9০-৯ ]+', name or ''):
                    continue
                arr = dep = None; seen = False
                for w in ws:
                    cy = (w[1] + w[3]) / 2
                    t = w[4].strip()
                    seen = True
                    if TIME.match(t):
                        if cy < mid: arr = num(t)
                        else: dep = num(t)
                if seen: stops.append([name, arr, dep])
            label = ' '.join(fix(w[4]) for w in sorted(cells.get((r, 1), []), key=lambda w: (round(w[1]), w[0])))
            blocks.append({'no': no, 'page': pi, 'label': label, 'stops': stops})
json.dump(blocks, open(sys.argv[4], 'w'), ensure_ascii=False, indent=0)
for o in blocks: print(o['no'], o['page'], o['label'], '::', ' | '.join(f"{s[0]} {s[1]}/{s[2]}" for s in o['stops']))
