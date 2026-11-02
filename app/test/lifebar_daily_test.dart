// lifebar: pure logic behind the daily-life fixes (no network, no device).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/ramadan_screen.dart' show ramadanShiftHhmm;
import 'package:assisto/widgets/local_digits.dart';

void main() {
  group('toLocalDigits', () {
    test('bn turns every ASCII digit into a Bangla digit', () {
      expect(toLocalDigits('05:30', true), '০৫:৩০');
      expect(toLocalDigits('৳1,234.50', true),
          '৳১,২৩৪.৫০');
    });
    test('en is unchanged; letters are never touched', () {
      expect(toLocalDigits('UTC+4:00', false), 'UTC+4:00');
      expect(toLocalDigits('UTC+4', true), 'UTC+৪');
    });
  });

  group('ramadanShiftHhmm (was int.parse -> red screen)', () {
    test('shifts and wraps midnight', () {
      expect(ramadanShiftHhmm('04:10', -30), '03:40');
      expect(ramadanShiftHhmm('00:10', -30), '23:40');
      expect(ramadanShiftHhmm('23:50', 20), '00:10');
    });
    test('a missing time from the server never throws', () {
      expect(ramadanShiftHhmm('--:--', -30), '--:--');
      expect(ramadanShiftHhmm('', -30), '');
      expect(ramadanShiftHhmm('4 AM', 10), '4 AM');
      expect(ramadanShiftHhmm('ab:cd', 10), 'ab:cd');
    });
  });

  testWidgets('ld() follows the app language', (tester) async {
    String? bn, en;
    Widget host(Locale l, void Function(String) out) => MaterialApp(
          locale: l,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(builder: (c) {
            out(ld(c, 42));
            return const SizedBox();
          }),
        );
    await tester.pumpWidget(host(const Locale('bn'), (v) => bn = v));
    await tester.pumpAndSettle();
    await tester.pumpWidget(host(const Locale('en'), (v) => en = v));
    await tester.pumpAndSettle();
    expect(bn, '৪২');
    expect(en, '42');
  });
}
