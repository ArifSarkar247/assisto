// A1 regression guard — the owner-reported "keyboard hides the input" bug.
//
// Simulates a SMALL screen with the on-screen keyboard open (viewInsets.bottom)
// and asserts two things on the chat-first home:
//   1. the text input stays fully visible — its bottom edge sits ABOVE the
//      keyboard region (it is never covered), and
//   2. the home Discover/spotlight cards COLLAPSE as soon as the input gains
//      focus, so on a small screen the chat + input fill the space.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/state.dart';
import 'package:assisto/models.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/updater.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/home_screen.dart';

import 'fake_api.dart';

AppState _loggedInStub() {
  final s = AppState();
  s.api = FakeApi(mode: FakeMode.data, lang: 'en');
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01700000000', email: '',
      autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

/// Small phone screen with the keyboard OPEN: 300 of the 640 logical px at the
/// bottom are covered by the keyboard (viewInsets.bottom).
const _screen = Size(360, 640);
const _keyboardInset = 300.0;

Future<void> _pumpHome(WidgetTester tester, AppState app) async {
  await tester.binding.setSurfaceSize(_screen);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<Updater>(create: (_) => Updater()),
      ],
      child: MediaQuery(
        data: const MediaQueryData(
          size: _screen,
          viewInsets: EdgeInsets.only(bottom: _keyboardInset),
        ),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: AssistoTheme.light,
          home: const HomeScreen(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'input stays above the keyboard and Discover collapses on focus',
      (tester) async {
    final app = _loggedInStub();
    await _pumpHome(tester, app);

    // The chat input must exist and be visible.
    final field = find.byType(TextField);
    expect(field, findsOneWidget);

    // Focus the input (as tapping it would), which must trigger the home to
    // hide the Discover cards AND keep the field above the keyboard.
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // (1) Input bottom edge is above the keyboard region — not covered.
    final box = tester.renderObject<RenderBox>(field);
    final topLeft = box.localToGlobal(Offset.zero);
    final fieldBottom = topLeft.dy + box.size.height;
    final visibleBottom = _screen.height - _keyboardInset;
    expect(fieldBottom, lessThanOrEqualTo(visibleBottom + 0.5),
        reason:
            'the input ($fieldBottom) must sit above the keyboard ($visibleBottom)');

    // (2) The Discover spotlight collapsed once the input gained focus: its
    // header label is gone.
    final t = AppLocalizations.of(tester.element(field));
    expect(find.text(t.discoverTitle), findsNothing,
        reason: 'Discover cards must hide when the input is focused');

    // Reset surface size inside the test (setSurfaceSize is illegal in tearDown).
    await tester.binding.setSurfaceSize(null);
  });
}
