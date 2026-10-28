// insets (owner 28 Oct): every bottom sheet must open through showAppSheet
// (lib/widgets/app_sheet.dart), which keeps the content above the phone's
// navigation bar and the keyboard. A raw showModalBottomSheet / showBottomSheet
// anywhere else in lib/ fails this test.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// path -> reason. Keep EMPTY unless a sheet truly cannot use the helper.
const Map<String, String> _allow = {
  'lib/widgets/app_sheet.dart': 'the shared helper itself',
};

final _raw = RegExp(r'\b(showModalBottomSheet|showBottomSheet)\s*(<[^()]*>)?\s*\(');

String _stripComments(String s) => s
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  test('no raw showModalBottomSheet outside the shared helper', () {
    final bad = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final rel = f.path.replaceAll('\\', '/');
      if (_allow.containsKey(rel)) continue;
      final lines = _stripComments(f.readAsStringSync()).split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (_raw.hasMatch(lines[i])) bad.add('$rel:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(bad, isEmpty,
        reason: 'Open bottom sheets with showAppSheet '
            '(lib/widgets/app_sheet.dart) so they stay above the navigation '
            'bar and the keyboard:\n${bad.join('\n')}');
  });

  test('the helper pads for the nav bar AND the keyboard', () {
    final s = File('lib/widgets/app_sheet.dart').readAsStringSync();
    expect(s, contains('viewPadding.bottom'));
    expect(s, contains('viewInsets.bottom'));
  });
}
