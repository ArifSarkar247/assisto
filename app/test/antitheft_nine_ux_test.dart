// antitheft-nine — honest UX on the always-on protection screen (row 11):
//   * "Instant lock" ON while Assisto is NOT device admin used to look fine
//     but could never lock (and the family's remote lock failed with
//     "no_admin"): now an honest line + a "Turn on device admin" button that
//     first explains why (Play disclosure);
//   * bn + en, 200% text: the line and the button wrap (no overflow).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/always_on_protection_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';

const _at = MethodChannel('com.assisto/antitheft');
const _admin = MethodChannel('com.assisto/device_admin');

void _mock({required bool admin}) {
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(_at, (call) async {
    switch (call.method) {
      case 'capabilities':
        return {'sdk': 33, 'brand': 'realme', 'canCamera': true,
                'cameraPermission': true, 'canReadSimNumber': false};
      case 'isRunning':
        return true;
      default:
        return null;
    }
  });
  m.setMockMethodCallHandler(_admin, (call) async {
    if (call.method == 'isAdminActive') return admin;
    return null;
  });
}

Future<AppLocalizations> _pump(WidgetTester tester, String lang,
    {double scale = 1}) async {
  await tester.binding.setSurfaceSize(const Size(400, 900));
  final s = AppState()
    ..api = FakeApi(mode: FakeMode.data, lang: lang)
    ..user = AppUser(id: 1, name: 'Me', phone: '+8801700000000', email: '',
        autonomyLevel: 2, language: lang)
    ..locale = Locale(lang)
    ..loading = false;
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: s,
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AssistoTheme.light,
      builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: const AlwaysOnProtectionScreen(),
    ),
  ));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return AppLocalizations.of(tester.element(find.byType(AlwaysOnProtectionScreen)));
}

Future<void> _scrollTo(WidgetTester tester, Finder f) => tester.dragUntilVisible(
    f, find.byType(Scrollable).first, const Offset(0, -250));

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_at, null);
    m.setMockMethodCallHandler(_admin, null);
  });

  for (final lang in ['en', 'bn']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('instant lock ON + admin OFF -> honest line + fix ($lang, ${scale}x)',
          (tester) async {
        _mock(admin: false);
        final t = await _pump(tester, lang, scale: scale);
        final line = find.byKey(const Key('at9-admin-off'));
        await _scrollTo(tester, line);
        expect(find.text(t.atnineLockNeedsAdmin), findsOneWidget);
        expect(find.text(t.atnineTurnOnAdmin), findsOneWidget);
        final btn = tester.getSize(find.byKey(const Key('at9-admin-on')));
        expect(btn.height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull); // no overflow at 200%
        // the button explains WHY first (Play disclosure), never a dead end
        await tester.tap(find.byKey(const Key('at9-admin-on')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('at100-disc-admin')), findsOneWidget);
      });
    }
  }

  testWidgets('admin ON -> no warning', (tester) async {
    _mock(admin: true);
    await _pump(tester, 'en');
    expect(find.byKey(const Key('at9-admin-off')), findsNothing);
  });
}
