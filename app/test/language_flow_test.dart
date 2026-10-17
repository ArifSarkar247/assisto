// First-run flow: language picker → Continue → past the gate.
//
// Regression guard for the owner-reported freeze where tapping "Continue" on the
// first-launch language screen did nothing, so the app could never be entered.
// Root cause: AppState.setLocale() called notifyListeners() only AFTER awaiting a
// SharedPreferences write; if that write hung or threw on the device, the gate
// (locale == null) never re-evaluated and the screen stayed frozen. The fix
// applies the language in memory and notifies IMMEDIATELY, persisting best-effort.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/state.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/language_picker_screen.dart';

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  // The decisive guard: the UI must advance the instant Continue is tapped — the
  // chosen language is live in memory and listeners are notified BEFORE the
  // (best-effort) persistence future completes. Before the fix, `notified` was
  // still false at this point because notifyListeners() sat behind the await.
  test('setLocale applies + notifies synchronously, before persistence resolves',
      () {
    final app = AppState();
    var notified = false;
    app.addListener(() => notified = true);

    final pending = app.setLocale(const Locale('en')); // intentionally NOT awaited

    expect(app.locale, const Locale('en'),
        reason: 'locale must be set in memory immediately');
    expect(notified, isTrue,
        reason: 'listeners must be notified before awaiting storage');
    return pending; // let the best-effort write settle so the test is clean
  });

  testWidgets('language picker → Continue → leaves the gate', (tester) async {
    final app = AppState()
      ..locale = null
      ..loading = false;

    // A minimal replica of main.dart's first-run gate: show the picker while
    // locale is null, otherwise we've "entered the app".
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          localeResolutionCallback: (_, __) => app.locale ?? const Locale('bn'),
          home: Consumer<AppState>(
            builder: (_, a, __) => a.locale == null
                ? const LanguagePickerScreen()
                : const Scaffold(body: Center(child: Text('ENTERED_APP'))),
          ),
        ),
      ),
    );

    expect(find.byType(LanguagePickerScreen), findsOneWidget);
    expect(find.text('ENTERED_APP'), findsNothing);

    await tester.tap(find.byType(FilledButton)); // "Continue"
    await tester.pumpAndSettle();

    expect(app.locale, isNotNull, reason: 'Continue must choose a language');
    expect(find.byType(LanguagePickerScreen), findsNothing,
        reason: 'Continue must leave the first-run language screen');
    expect(find.text('ENTERED_APP'), findsOneWidget);
  });
}
