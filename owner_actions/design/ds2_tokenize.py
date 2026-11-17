# designv2: mechanical colour pass for one screen file (style only).
# Maps ColorScheme roles that read as text / ink / surfaces to the V2 tokens
# (<scheme>.ds.<token>, extension DsSchemeTokens — no BuildContext needed) and adds the ds import. Prints every raw
# TextStyle( / Color( left so they can be moved to the theme scale by hand.
# usage: python3 owner_actions/design/ds2_tokenize.py app/lib/<file>.dart
import re, sys, os

# error / onError stay theme roles (fill or text — the theme picks AA-safe values)
MAP = {
    'onSurfaceVariant': 'muted',
    'onSurface': 'text',
    'surfaceContainerHighest': 'cardHighest',
    'surfaceContainerHigh': 'cardHigh',
    'surfaceContainer': 'cardAlt',
    'surfaceContainerLow': 'card',
    'surfaceContainerLowest': 'card',
    'outlineVariant': 'border',
    'outline': 'muted',  # often used for hint text / icons — muted passes AA
    'errorContainer': 'dangerBg',
    'onErrorContainer': 'dangerInk',
    'primaryContainer': 'primarySoft',
    'onPrimaryContainer': 'primaryInk',
    'tertiaryContainer': 'successBg',
    'onTertiaryContainer': 'successInk',
    'secondaryContainer': 'primarySoft',
    'onSecondaryContainer': 'primaryInk',
}

path = sys.argv[1]
s = open(path).read()
orig = s
vars_ = set(re.findall(r'final (\w+) = Theme\.of\(\w+\)\.colorScheme;', s))
vars_ |= set(re.findall(r'ColorScheme (\w+)[,)]', s))
n = 0
for v in sorted(vars_) + ['Theme.of(context).colorScheme', 'Theme.of(ctx).colorScheme']:
    for role in sorted(MAP, key=len, reverse=True):
        pat = r'(?<![\w.])' + re.escape(v) + r'\.' + role + r'\b'
        # context-free: works in any scope where the ColorScheme is
        s, k = re.subn(pat, v + '.ds.' + MAP[role], s)
        n += k
theme_plain = re.search(r"^import '[^']*/theme\.dart';$|^import 'package:assisto/theme\.dart';$|^import 'theme\.dart';$", s, re.M)
if s != orig and 'ds/ds.dart' not in s and not theme_plain:
    rel = os.path.relpath(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), '../../app/lib/ds/ds.dart'),
                          os.path.dirname(os.path.abspath(path)))
    m = re.search(r"^import '[^']*theme\.dart';\n", s, re.M) or re.search(r"^import 'package:flutter/material\.dart';\n", s, re.M)
    s = s[:m.end()] + f"import '{rel}';\n" + s[m.end():]
open(path, 'w').write(s)
print(f'{n} colour roles -> tokens')
for i, l in enumerate(s.split('\n'), 1):
    if re.search(r'\bTextStyle\(|\bColor\(', l.split('//')[0]):
        print(f'  {i}: {l.strip()[:110]}')
