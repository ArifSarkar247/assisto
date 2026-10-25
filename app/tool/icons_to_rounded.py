#!/usr/bin/env python3
"""F5 icon migration: rewrite Icons.* in lib/ and test/ to Material Icons Rounded.

Rule (REMAINING.md item 5):
  Icons.X           -> Icons.X_rounded
  Icons.X_outlined  -> Icons.X_outline_rounded if it exists, else Icons.X_rounded
  Icons.X_sharp     -> Icons.X_rounded
Only names that exist in the Flutter SDK Icons class are used (read from
icons.dart). Toggle safety: in a state pair (ternary `c ? Icons.X :
Icons.X_outlined`, or icon:/selectedIcon:) where both would land on the same
rounded glyph, the outlined occurrence is kept so the states stay distinct.
lib/ and test/ are rewritten together so find.byIcon finders stay in step.
Usage: python3 tool/icons_to_rounded.py [--dry]
"""
import json
import os
import re
import sys

SDK = os.path.expanduser(
    '~/assisto/tools/flutter/packages/flutter/lib/src/material/icons.dart')
VALID = set(re.findall(r'static const IconData (\w+)\s*=', open(SDK).read()))
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Home is frozen for structure; skipped to be safe (owner rule, build 103).
SKIP = {'lib/screens/home_screen.dart', 'lib/widgets/home_quick_buttons.dart',
        # finds the home bell / My Circle HomeBadgeIcon by its (unchanged) icon
        'test/b2_badges_test.dart'}
PAT = re.compile(r'\bIcons\.([a-z0-9_]+)\b')


def target(n):
    if n.endswith('_rounded') or n not in VALID:
        return None
    if n.endswith('_outlined'):
        b = n[:-len('_outlined')]
        for c in (b + '_outline_rounded', b + '_rounded'):
            if c in VALID:
                return c
        return None
    if n.endswith('_sharp'):
        c = n[:-len('_sharp')] + '_rounded'
        return c if c in VALID else None
    c = n + '_rounded'
    return c if c in VALID else None


TERN = re.compile(r'\?\s*Icons\.([a-z0-9_]+)\s*:\s*Icons\.([a-z0-9_]+)')
NAV = re.compile(r'icon:[^;]{0,80}?Icons\.([a-z0-9_]+)[^;]{0,120}?selectedIcon:[^;]{0,80}?Icons\.([a-z0-9_]+)', re.S)


def toggle_offsets(src):
    """Offsets of Icons.X_outlined occurrences that form a state pair with a
    filled icon mapping to the same rounded glyph (ternary or icon/selectedIcon).
    Those keep their outlined glyph so the two states stay distinct."""
    out = set()
    for rx in (TERN, NAV):
        for m in rx.finditer(src):
            a, b = (n if n.endswith('_rounded') else target(n)
                    for n in (m.group(1), m.group(2)))
            if a is None or a != b:
                continue
            for g in (1, 2):
                if m.group(g).endswith('_outlined'):
                    out.add(m.start(g) - len('Icons.'))
    return out


def files(d):
    for r, _, fs in os.walk(os.path.join(ROOT, d)):
        for f in fs:
            if f.endswith('.dart'):
                yield os.path.relpath(os.path.join(r, f), ROOT)


def main():
    dry = '--dry' in sys.argv
    lib = sorted(f for f in files('lib') if f not in SKIP)
    tst = sorted(f for f in files('test') if f not in SKIP)
    kept = {}
    mapped, unmapped, uses, changed = {}, {}, 0, 0
    for f in lib + tst:
        p = os.path.join(ROOT, f)
        src = open(p).read()
        keep = toggle_offsets(src)
        if keep:
            kept[f] = sorted({PAT.match(src, o).group(1) for o in keep})

        def rep(m):
            nonlocal uses
            n = m.group(1)
            t = target(n)
            if m.start() in keep or t is None:
                if t is None and not n.endswith('_rounded'):
                    unmapped[n] = unmapped.get(n, 0) + 1
                return m.group(0)
            mapped[n] = t
            uses += 1
            return 'Icons.' + t

        out = PAT.sub(rep, src)
        if out != src:
            changed += 1
            if not dry:
                open(p, 'w').write(out)
    print(json.dumps({
        'distinct_mapped': len(mapped), 'uses_mapped': uses, 'files_changed': changed,
        'unmapped': unmapped,
        'toggle_kept': kept,
        'skipped_files': sorted(SKIP)}, indent=1))


if __name__ == '__main__':
    main()
