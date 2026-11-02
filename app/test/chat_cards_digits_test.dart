import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/widgets/chat_cards.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(String lang, Map<String, dynamic> card) => MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ChatCard(card)),
    );

void main() {
  const cards = <Map<String, dynamic>>[
    {'type': 'expense', 'title': '৳500 Food', 'subtitle': 'Cash 12'},
    {'type': 'income', 'title': '৳1,500 Salary', 'subtitle': 'Cash'},
    {'type': 'reminder', 'title': 'Call mom', 'subtitle': 'Tomorrow 8:00'},
    {'type': 'approval', 'title': 'bKash: Rahim — ৳2,000', 'subtitle': 'Ask first'},
    {'type': 'bill', 'title': 'Bill ৳750', 'subtitle': 'Due 5'},
  ];
  final bn = RegExp(r'[০-৯]');
  for (final c in cards) {
    testWidgets('${c['type']} card bn digits', (tester) async {
      await tester.pumpWidget(_wrap('bn', c));
      await tester.pumpAndSettle();
      final texts = tester.widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '').where((s) => RegExp(r'[0-9০-৯]').hasMatch(s));
      expect(texts, isNotEmpty);
      for (final s in texts) {
        expect(RegExp(r'[0-9]').hasMatch(s), isFalse, reason: s);
        expect(bn.hasMatch(s), isTrue, reason: s);
      }
    });
    testWidgets('${c['type']} card en digits', (tester) async {
      await tester.pumpWidget(_wrap('en', c));
      await tester.pumpAndSettle();
      expect(find.text(c['title'] as String), findsOneWidget);
    });
  }
  testWidgets('approval bn exact', (tester) async {
    await tester.pumpWidget(_wrap('bn', cards[3]));
    await tester.pumpAndSettle();
    expect(find.text('bKash: Rahim — ৳২,০০০'), findsOneWidget);
  });
}
