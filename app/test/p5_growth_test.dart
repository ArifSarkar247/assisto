import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/growth/branded_share.dart';
import 'package:assisto/growth/invite_screen.dart';
import 'package:assisto/l10n/app_localizations.dart';

import 'p5_shots.dart';

Widget _wrap(Widget child, String lang) => MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

void main() {
  test('localDigits converts only in Bangla', () {
    expect(localDigits(1234, true), '১২৩৪');
    expect(localDigits(1234, false), '1234');
    expect(localDigits(null, true), '০');
  });

  test('card text is clipped, never unbounded', () {
    final long = 'a' * 2000;
    expect(clipForCard(long).length, lessThan(720));
    expect(clipForCard(' short '), 'short');
  });

  testWidgets('invite screen shows server rules with Bangla digits',
      (tester) async {
    await tester.pumpWidget(_wrap(InviteScreen(loader: () async => p5Me()), 'bn'));
    await tester.pumpAndSettle();
    expect(find.text('K7QF2M9P'), findsOneWidget);
    expect(find.textContaining('২০ AI ক্রেডিট'), findsOneWidget);
    expect(find.textContaining('১৪ দিনের'), findsOneWidget);
    expect(find.byKey(const ValueKey('p5_code_field')), findsOneWidget);
    expect(find.textContaining('টাকা নয়'), findsOneWidget);
  });

  testWidgets('pending claim shows progress, no code field (en)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    await tester.pumpWidget(_wrap(
        InviteScreen(loader: () async => p5Me(claimed: true, seat: true)), 'en'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('p5_code_field')), findsNothing);
    expect(find.textContaining('1 of 2 done'), findsOneWidget);
    expect(find.text('You are Founding Member #42'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('share sheet previews only the given text + invite link',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    await tester.pumpWidget(_wrap(
        Scaffold(
            body: BrandedShareSheet(
                body: 'Only this answer', inviteLoader: () async => p5Me())),
        'en'));
    await tester.pumpAndSettle();
    expect(find.text('Only this answer'), findsOneWidget);
    expect(find.textContaining('lifeassisto.com/i/K7QF2M9P'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('/i/K7QF2M9P'), findsNothing);
    expect(find.textContaining('Bangladesh'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });
}
