import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/widgets/plans_compare_table.dart';

/// The AI allowance cell comes from the live config pool — never a hardcoded
/// "15 / mo" (owner: free pool is 0).
Future<void> _pump(WidgetTester t, String lang, List<Map<String, dynamic>> plans) =>
    t.pumpWidget(MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: SingleChildScrollView(child: PlansCompareTable(plans: plans, current: 'free'))),
    ));

Map<String, dynamic> _p(String id, {int credits = 0, int family = 0}) =>
    {'id': id, 'name': id, 'unlimited_ai': false, 'ads': id == 'free', 'family': family, 'credits': credits};

void main() {
  testWidgets('zero pool -> packs or ads; never 15', (t) async {
    await _pump(t, 'en', [_p('free'), _p('premium', credits: 90, family: 5)]);
    expect(find.text('Packs or ads'), findsOneWidget);
    expect(find.text('15 / mo'), findsNothing);
    expect(find.text('Up to 5'), findsOneWidget);
  });

  testWidgets('positive pool shows the configured number (bn digits in bn)', (t) async {
    await _pump(t, 'en', [_p('free', credits: 20)]);
    expect(find.text('20 / mo'), findsOneWidget);
    await _pump(t, 'bn', [_p('free', credits: 20), _p('premium', credits: 90, family: 5)]);
    expect(find.text('মাসে ২০'), findsOneWidget);
    expect(find.text('৫ জন পর্যন্ত'), findsOneWidget);
  });

  testWidgets('nothing is unlimited: Premium shows its 90 credits / month', (t) async {
    // Even a stale server row claiming unlimited_ai must not render "Unlimited".
    final prem = _p('premium', credits: 90, family: 5)..['unlimited_ai'] = true;
    await _pump(t, 'en', [_p('free'), prem, _p('business', credits: 240)]);
    expect(find.text('90 / mo'), findsOneWidget);
    expect(find.text('240 / mo'), findsOneWidget);
    expect(find.textContaining('Unlimited'), findsNothing);
    await _pump(t, 'bn', [_p('free'), prem]);
    expect(find.text('মাসে ৯০'), findsOneWidget);
    expect(find.textContaining('আনলিমিটেড'), findsNothing);
  });
}
