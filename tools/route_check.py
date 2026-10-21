#!/usr/bin/env python3
"""route_check.py — does every API path the Flutter client calls exist in Django?

Static half of the Reality Audit (m2-reality). Extracts every literal API path
from app/lib/**/*.dart (AppConfig.api(...), getJson/postJson/patchJson/...,
the shop/business helpers, and the generic listItems/createItem/updateItem/
deleteItem collection helpers), normalises Dart interpolation ($id, ${...}) to
a concrete sample segment, and resolves '/api/v1' + path against Django's real
URL resolver (backend/, settings_ci — no DB, no network). Also checks that the
resolved view implements the HTTP method the client uses.

Statuses:
  OK              path resolves and the view handles the method
  METHOD          path resolves but the view has no handler for that method (405)
  SLASH           resolves only with/without a trailing slash: a client '/'
                  the route lacks always 404s; a missing '/' the route wants
                  survives APPEND_SLASH only for GET
  MISSING         no Django route -> the client call always 404s
  DYNAMIC         path built from a runtime variable prefix; not checkable
Rows whose source has a nearby `TODO(backend)` are tagged `m1` (messenger
routes being built by slot m1-messenger).

usage:  python3 tools/route_check.py [--json out.json] [--md out.md] [--report-only]
        exit 1 when any call is MISSING / METHOD / SLASH (the CI contract gate)
        (uses ~/assisto/.venv python automatically if Django isn't importable)
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_LIB = ROOT / "app" / "lib"
BACKEND = ROOT / "backend"

CALL_RE = re.compile(
    r"(?P<fn>AppConfig\.api|getJson|postJson|patchJson|putJson|deleteJson|getBytes|"
    r"_getJson|_postJson|_patchJson|_get|_post|_patch|_put|_delete|_postGuardMin)"
    r"\(\s*(?P<q>['\"])(?=/)", re.S)
COLL_RE = re.compile(
    r"(?P<fn>listItems|createItem|updateItem|deleteItem)\(\s*(?P<q>['\"])", re.S)


def read_dart_string(src, start, quote):
    """Read a Dart single-line string body starting AFTER the opening quote,
    honouring ${...} interpolation blocks (which may contain quotes)."""
    i, depth, out = start, 0, []
    while i < len(src):
        ch = src[i]
        if depth == 0:
            if ch == "\\":
                out.append(src[i:i + 2]); i += 2; continue
            if ch == quote or ch == "\n":
                return "".join(out)
            if src.startswith("${", i):
                depth = 1; out.append("${"); i += 2; continue
            out.append(ch); i += 1
        else:
            if ch in "'\"":  # skip a nested string literal inside ${...}
                j = src.find(ch, i + 1)
                if j < 0:
                    return "".join(out)
                out.append(src[i:j + 1]); i = j + 1; continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            out.append(ch); i += 1
    return "".join(out)
# static String constants used as path prefixes are not followed (DYNAMIC).

FN_METHOD = {
    "getJson": "GET", "_getJson": "GET", "getBytes": "GET", "_get": "GET",
    "postJson": "POST", "_postJson": "POST", "_post": "POST", "_postGuardMin": "POST",
    "patchJson": "PATCH", "_patchJson": "PATCH", "_patch": "PATCH",
    "putJson": "PUT", "_put": "PUT", "deleteJson": "DELETE", "_delete": "DELETE",
    "listItems": "GET", "createItem": "POST", "updateItem": "PATCH", "deleteItem": "DELETE",
}
VERB_BEFORE = re.compile(r"\.(get|post|patch|put|delete|head)\(\s*$", re.I)
MULTIPART = re.compile(r"MultipartRequest\(\s*'(\w+)'\s*,\s*$")
INTERP_SIMPLE = re.compile(r"\$[A-Za-z_]\w*")


def strip_interp(p):
    """Replace every ${...} (nesting-aware) and $name with \\x00."""
    out, i = [], 0
    while i < len(p):
        if p.startswith("${", i):
            depth, j = 1, i + 2
            while j < len(p) and depth:
                if p[j] == "{":
                    depth += 1
                elif p[j] == "}":
                    depth -= 1
                j += 1
            out.append("\x00"); i = j; continue
        out.append(p[i]); i += 1
    return INTERP_SIMPLE.sub("\x00", "".join(out))


def _ensure_django():
    from importlib.util import find_spec
    if find_spec("django") is not None:
        from django.conf import settings as _s
        if _s.configured and _s.ROOT_URLCONF:
            return  # already inside a configured Django (the test suite)
    try:
        import django  # noqa: F401
    except ImportError:
        venv = Path.home() / "assisto" / ".venv" / "bin" / "python"
        if venv.exists() and Path(sys.executable) != venv:
            os.execv(str(venv), [str(venv), *sys.argv])
        raise
    sys.path.insert(0, str(BACKEND))
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "assisto_backend.settings_ci")
    os.environ.setdefault("ASSISTO_CI_DB", "/nonexistent/route_check.sqlite3")
    import django
    django.setup()


def extract():
    rows = []
    for f in sorted(APP_LIB.rglob("*.dart")):
        rel = f.relative_to(ROOT).as_posix()
        if "/l10n/" in rel:
            continue
        src = f.read_text(encoding="utf-8", errors="replace")
        lines = src.splitlines()

        def lineno(pos):
            return src.count("\n", 0, pos) + 1

        def near_todo(ln):
            lo, hi = max(0, ln - 6), min(len(lines), ln + 3)
            return any("TODO(backend)" in x for x in lines[lo:hi])

        for m in CALL_RE.finditer(src):
            fn = m.group("fn")
            path = read_dart_string(src, m.end(), m.group("q"))
            method = FN_METHOD.get(fn)
            if fn == "AppConfig.api":
                before = src[max(0, m.start() - 80):m.start()]
                v = VERB_BEFORE.search(before)
                mp = MULTIPART.search(before)
                method = (v.group(1).upper() if v else (mp.group(1).upper() if mp else "ANY"))
            ln = lineno(m.start())
            rows.append({"file": rel, "line": ln, "fn": fn, "method": method,
                         "raw": path, "m1": near_todo(ln)})
        for m in COLL_RE.finditer(src):
            fn = m.group("fn")
            path = read_dart_string(src, m.end(), m.group("q"))
            if not path or path.startswith("$"):
                continue
            p = path.split("?", 1)[0].strip("/")
            p = "/" + p + "/"
            if fn in ("updateItem", "deleteItem"):
                p += "1/"
            ln = lineno(m.start())
            rows.append({"file": rel, "line": ln, "fn": fn, "method": FN_METHOD[fn],
                         "raw": p, "m1": near_todo(ln)})
    return rows


def segments(raw):
    """Client path -> list of ('lit', text) | ('wild', None) | ('part', regex).

    ${...}/$name become placeholders. A trailing interpolation glued onto a
    literal last segment ('/chat/sessions$q') is treated as an optional
    query-string suffix (it is in every case in the codebase)."""
    p = strip_interp(raw).split("?", 1)[0]
    segs = p.split("/")[1:]
    out = []
    for k, sg in enumerate(segs):
        if sg == "\x00":
            out.append(("wild", None))
        elif "\x00" in sg:
            if k == len(segs) - 1 and sg.endswith("\x00") and "\x00" not in sg[:-1]:
                out.append(("tail", sg[:-1]))
            else:
                out.append(("part", sg))
        else:
            out.append(("lit", sg))
    return out


def route_vocab():
    """Every literal path word in Django's URLconf (to try in a placeholder
    position, e.g. '/family/sharing/$op' -> 'consent')."""
    from django.urls import get_resolver
    words = set()

    def walk(patterns):
        for pt in patterns:
            text = str(pt.pattern)
            for w in re.findall(r"(?<![<:?P])\b[A-Za-z][A-Za-z0-9_.-]*", text):
                if w not in ("int", "str", "slug", "uuid", "path", "pk", "P"):
                    words.add(w.strip("."))
            if hasattr(pt, "url_patterns"):
                walk(pt.url_patterns)
    walk(get_resolver().url_patterns)
    return sorted(w for w in words if w)


SAMPLES = ["1", "abc", "00000000-0000-0000-0000-000000000001"]


def candidates(segs, vocab):
    """Concrete sample paths for a client path, most likely first. Placeholder
    segments get int/str/uuid samples (so <int:pk> vs <str:x> vs <uuid> shapes
    all get a fair try) and, one position at a time, every route literal."""
    tails = [s for s in segs if s[0] == "tail"]
    # a glued tail is a query suffix ('drop') or a format ('.pdf', '.xlsx'...)
    tail_opts = ["drop", "x1", "pdf", "xlsx", "csv", "json"] if tails else ["drop"]
    wild_ix = [k for k, s in enumerate(segs) if s[0] == "wild"]
    seen = []

    def build(fill, tail_mode):
        out = []
        for k, (kind, v) in enumerate(segs):
            if kind == "lit":
                out.append(v)
            elif kind == "wild":
                out.append(fill.get(k, "1"))
            elif kind == "tail":
                out.append(v if tail_mode == "drop" else v + tail_mode)
            else:
                out.append(v.replace("\x00", "x1"))
        return "/" + "/".join(out)

    for tm in tail_opts:
        for smp in SAMPLES:
            c = build({k: smp for k in wild_ix}, tm)
            if c not in seen:
                seen.append(c)
    for tm in tail_opts:
        for k in wild_ix:
            for w in vocab:
                c = build({k: w}, tm)
                if c not in seen:
                    seen.append(c)
    return seen


def check(rows):
    from django.urls import resolve, Resolver404

    def try_resolve(path):
        try:
            return resolve(path)
        except Resolver404:
            return None

    def handles(match, method):
        if method == "ANY":
            return True
        func = match.func
        actions = getattr(func, "actions", None)
        if actions:  # DRF router: method must map to a viewset action
            return method.lower() in actions
        cls = getattr(func, "view_class", None) or getattr(func, "cls", None)
        if cls is None:
            return True  # plain function view: method unknown
        if method.lower() == "head":
            return True
        return hasattr(cls, method.lower())

    vocab = route_vocab()
    for r in rows:
        segs = segments(r["raw"])
        if segs and segs[0][0] == "wild":
            r["status"], r["path"] = "DYNAMIC", r["raw"]
            continue
        cands = candidates(segs, vocab)
        r["path"] = cands[0]
        hit = None
        method_ok_hit = None
        for c in cands:
            m = try_resolve("/api/v1" + c)
            if m is None:
                continue
            if hit is None:
                hit = (c, m)
            if handles(m, r["method"]):
                method_ok_hit = (c, m)
                break
        if method_ok_hit:
            r["path"], m = method_ok_hit
            r["view"] = getattr(m.func, "__name__", "?")
            r["status"] = "OK"
            continue
        if hit:
            r["path"], m = hit
            r["view"] = getattr(m.func, "__name__", "?")
            r["status"] = "METHOD"
            r["note"] = f"{r['view']} has no {r['method']} handler -> 405"
            continue
        full = "/api/v1" + cands[0]
        alt = full[:-1] if full.endswith("/") else full + "/"
        m2 = try_resolve(alt)
        if m2 is not None:
            if full.endswith("/"):
                # client adds '/', route has none: APPEND_SLASH never removes
                # a slash -> 404 for every method.
                r["status"] = "SLASH"
                r["note"] = "client sends trailing '/', route is " + alt[7:] + " -> 404"
            else:
                # route wants '/': GET survives the 301, a POST/PATCH body doesn't
                r["status"] = "SLASH" if r["method"] != "GET" else "OK"
                r["note"] = "route is " + alt[7:] + " (301 drops non-GET)"
            continue
        r["status"] = "MISSING"
        r["note"] = "no Django route"
    return rows


PROBLEM = ("MISSING", "METHOD", "SLASH")


def run(app_lib=None):
    """In-process entry point (used by core/tests_api_contract.py)."""
    rows = check(extract())
    uniq = {}
    for r in rows:
        k = (r["method"], r["raw"])
        if k not in uniq or (uniq[k]["status"] == "OK" and r["status"] != "OK"):
            uniq[k] = r
    bad = sorted([r for r in uniq.values() if r["status"] in PROBLEM],
                 key=lambda x: (x["m1"], x["file"], x["line"]))
    counts = {}
    for r in uniq.values():
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    summary = {"calls": len(rows), "unique": len(uniq), "counts": counts,
               "problems": len(bad), "problems_m1_tagged": sum(1 for r in bad if r["m1"])}
    return summary, rows, bad


def format_problem(r):
    tag = "  [TODO(backend) - m1]" if r["m1"] else ""
    return (f"{r['status']:7} {r['method']:6} {r['raw']}  ->  {r['file']}:{r['line']}"
            f"  ({r.get('note', '')}){tag}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--report-only", action="store_true",
                    help="never exit non-zero (default: exit 1 on any miss)")
    a = ap.parse_args()
    _ensure_django()
    summary, rows, bad = run()
    print(json.dumps(summary))
    dyn = [r for r in rows if r["status"] == "DYNAMIC"]
    for r in bad:
        print(format_problem(r))
    for r in dyn:
        print(f"WARN    {r['method']:6} {r['raw']}  ->  {r['file']}:{r['line']}  "
              "(path prefix is a runtime variable; not checkable)")
    if a.json:
        Path(a.json).write_text(json.dumps({"summary": summary, "rows": rows}, indent=1))
    if a.md:
        out = ["| status | method | client path | where | note |", "|---|---|---|---|---|"]
        for r in bad:
            out.append(f"| {r['status']} | {r['method']} | `{r['raw']}` | {r['file']}:{r['line']} | "
                       f"{r.get('note', '')}{' (TODO(backend), m1)' if r['m1'] else ''} |")
        Path(a.md).write_text("\n".join(out) + "\n")
    if bad and not a.report_only:
        print(f"\nAPI CONTRACT FAILED: {len(bad)} client call(s) have no matching backend route.")
        sys.exit(1)


if __name__ == "__main__":
    main()
