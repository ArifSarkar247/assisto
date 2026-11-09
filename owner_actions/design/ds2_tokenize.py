# designv2: mechanical colour pass for one screen file (style only).
# Maps ColorScheme roles that read as text / ink / surfaces to the V2 tokens
# (DsTokens.of(context).<token>) and adds the ds import. Prints every raw
# TextStyle( / Color( left so they can be moved to the theme scale by hand.
# usage: python3 owner_actions/design/ds2_tokenize.py app/lib/<file>.dart
import re, sys, os

MAP = {
    'onSurfaceVariant': 'muted',
    'onSurface': 'text',
    'surfaceContainerHighest': 'cardHighest',
    'surfaceContainerHigh': 'cardHigh',
    'surfaceContainer': 'cardAlt',
    'surfaceContainerLow': 'card',
    'surfaceContainerLowest': 'card',
    'outlineVariant': 'border',
    'outline': 'border',
    'error': 'dangerInk',
    'onError': 'onDangerFill',
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
vars_ = set(re.findall(r'final (\w+) = Theme\.of\(context\)\.colorScheme;', s))
vars_ |= set(re.findall(r'ColorScheme (\w+)[,)]', s))
n = 0
for v in sorted(vars_) + ['Theme.of(context).colorScheme']:
    for role in sorted(MAP, key=len, reverse=True):
        pat = re.escape(v) + r'\.' + role + r'\b'
        s, k = re.subn(pat, 'DsTokens.of(context).' + MAP[role], s)
        n += k
if s != orig and 'ds/ds.dart' not in s:
    rel = os.path.relpath(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), '../../app/lib/ds/ds.dart'),
                          os.path.dirname(os.path.abspath(path)))
    m = re.search(r"^import '[^']*theme\.dart';\n", s, re.M) or re.search(r"^import 'package:flutter/material\.dart';\n", s, re.M)
    s = s[:m.end()] + f"import '{rel}';\n" + s[m.end():]
open(path, 'w').write(s)
print(f'{n} colour roles -> tokens')
for i, l in enumerate(s.split('\n'), 1):
    if re.search(r'\bTextStyle\(|\bColor\(', l.split('//')[0]):
        print(f'  {i}: {l.strip()[:110]}')
