import pymupdf
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
