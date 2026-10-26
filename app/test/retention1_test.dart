// retention1: Retention automation — the app side of the real journey (fake
// server): first run guide → wizard creates an automation → list toggles /
// results / delete → limits lowered + a customer's stop recorded; the
// customer's inbox replies and stops; honest plan / hidden / error / offline
// states; bn + en, dark mode and 200% text with NO overflow on every screen.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/retention/retention_inbox.dart';
import 'package:assisto/screens/retention/retention_screen.dart';
import 'package:assisto/screens/retention/retention_wizard.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';

import 'fake_api.dart';
import 'retention1_fakes.dart';
import 'retention1_shots.dart';

AppState _state() {
  final s = AppState();
  s.api = FakeApi();
  s.user = AppUser(id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: 'en');
  s.locale = const Locale('en');
  s.loading = false;
  return s;
}

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) =>
    ChangeNotifierProvider<AppState>.value(
      value: _state(),
      child: MaterialApp(
        key: UniqueKey(),
        locale: Locale(lang),
        theme: dark ? AssistoTheme.dark : AssistoTheme.light,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: home,
      ),
    );

Future<void> _settle(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

late AppLocalizations en;

void _phone(WidgetTester tester, {double height = 800}) {
  tester.view.physicalSize = Size(360 * 3, height * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Future<void> _tapText(WidgetTester tester, String text) async {
  final f = find.text(text).first;
  await tester.ensureVisible(f);
  await tester.tap(f);
  await _settle(tester);
}

void main() {
  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first run: guide + welcome, then the wizard creates an automation', (tester) async {
    _phone(tester, height: 2200);
    final src = FakeRetention('empty');
    await tester.pumpWidget(_app(RetentionScreen(source: src)));
    await _settle(tester);
    expect(find.text(en.rtGuideTitle), findsOneWidget);
    expect(find.text(en.rtWelcomeTitle), findsOneWidget);
    await _tapText(tester, en.rtCreateFirst);

    // step 1: pick "We miss you"
    expect(find.text(en.rtWhatTitle), findsOneWidget);
    await _tapText(tester, en.rtKindWinback);
    await _tapText(tester, en.rtNext);
    // step 2: honest counts from the server preview
    expect(src.calls, contains('preview'));
    expect(find.text(en.rtAudienceEmpty), findsOneWidget); // 'empty' fake -> 0 customers
    await _tapText(tester, en.rtNext);
    // step 3: message with live preview + the Stop line
    expect(find.text(en.rtPreviewLabel), findsOneWidget);
    expect(find.textContaining(en.rtFooterInApp), findsOneWidget);
    await _tapText(tester, en.rtVarName);
    await _tapText(tester, en.rtNext);
    // step 4: channel + time, save
    expect(find.text(en.rtChannel), findsOneWidget);
    await _tapText(tester, en.rtSave);
    expect(src.calls, contains('create'));
    expect(src.lastCreate!['kind'], 'winback');
    expect(src.lastCreate!['enabled'], true);
    expect(src.lastCreate!['channel'], 'in_app');
    expect((src.lastCreate!['params'] as Map)['days_without'], 45);
  });

  testWidgets('list: toggle, results, edit, delete', (tester) async {
    _phone(tester, height: 1800);
    final src = FakeRetention('data');
    await tester.pumpWidget(_app(RetentionScreen(source: src, guide: false)));
    await _settle(tester);
    expect(find.text(en.rtKindThanks), findsOneWidget);
    expect(find.text(en.rtKindWinback), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await _settle(tester);
    expect(src.calls, contains('update:1'));
    expect(src.lastUpdate, {'enabled': false});

    await tester.tap(find.text(en.rtKindThanks));
    await _settle(tester);
    expect(find.text(en.rtResultsTitle), findsOneWidget);
    expect(find.text(en.rtRsNotOnAssisto), findsWidgets);
    expect(find.textContaining('Very good!'), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);

    await tester.tap(find.byTooltip(en.rtMenu).first);
    await _settle(tester);
    await tester.tap(find.text(en.rtEdit).last);
    await _settle(tester);
    // editing starts on "Who" — the kind cannot change
    expect(find.text(en.rtWizardTitleEdit), findsOneWidget);
    expect(find.text(en.rtAudienceTitle), findsOneWidget);
    await tester.pageBack();
    await _settle(tester);

    await tester.tap(find.byTooltip(en.rtMenu).last);
    await _settle(tester);
    await tester.tap(find.text(en.rtDelete).last);
    await _settle(tester);
    expect(find.text(en.rtDeleteTitle), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, en.rtDelete));
    await _settle(tester);
    expect(src.calls, contains('delete:2'));
  });

  testWidgets('edit saves a PATCH without the kind', (tester) async {
    _phone(tester, height: 2200);
    final src = FakeRetention();
    final ov = await src.overview();
    await tester.pumpWidget(_app(RetentionWizardScreen(
        source: src, overview: ov, initial: FakeRetention.automation(), initialStep: 3)));
    await _settle(tester);
    await _tapText(tester, en.rtChWhatsApp);
    expect(find.text(en.rtWaTemplateTitle), findsOneWidget);
    await _tapText(tester, en.rtSave);
    expect(src.calls, contains('update:1'));
    expect(src.lastUpdate!.containsKey('kind'), false);
    expect(src.lastUpdate!['channel'], 'whatsapp');
  });

  testWidgets('preview failure shows retry', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeRetention()..previewFails = true;
    final ov = await src.overview();
    await tester.pumpWidget(_app(RetentionWizardScreen(source: src, overview: ov, initialStep: 1)));
    await _settle(tester);
    expect(find.text(en.rtPreviewError), findsOneWidget);
    src.previewFails = false;
    await _tapText(tester, en.rtRetry);
    expect(find.text(en.rtAudienceCount('38')), findsOneWidget);
    expect(find.text(en.rtNoPhone('4')), findsOneWidget);
  });

  testWidgets('limits: lower only, record a stop request', (tester) async {
    _phone(tester, height: 1600);
    final src = FakeRetention();
    await tester.pumpWidget(_app(RetentionScreen(source: src, guide: false)));
    await _settle(tester);
    await tester.tap(find.byTooltip(en.rtLimitsEdit));
    await _settle(tester);
    expect(find.text(en.rtCapsTitle), findsOneWidget);
    // at the server max the + is disabled
    final plus = find.byTooltip(en.rtMore);
    expect(
        tester
            .widget<IconButton>(find.ancestor(of: plus.at(1), matching: find.byType(IconButton)).first)
            .onPressed,
        isNull);
    await tester.tap(find.byTooltip(en.rtLess).at(1));
    await _settle(tester);
    await _tapText(tester, en.rtSave);
    expect(src.lastCaps!['per_customer_week'], 1);
    await tester.enterText(find.byType(TextField), '01710000002');
    await _settle(tester, 3);
    await _tapText(tester, en.rtOptOutAdd);
    expect(src.calls, contains('optout:01710000002'));
  });

  testWidgets('plan needed, hidden, error + retry', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(RetentionScreen(source: FakeRetention('plan'), guide: false)));
    await _settle(tester);
    expect(find.text(en.rtPlanTitle), findsOneWidget);
    expect(find.text(en.rtSeePlans), findsOneWidget);

    await tester.pumpWidget(_app(RetentionScreen(source: FakeRetention('off'), guide: false)));
    await _settle(tester);
    expect(find.text(en.rtFeatureOffTitle), findsOneWidget);

    final fail = FakeRetention('fail');
    await tester.pumpWidget(_app(RetentionScreen(source: fail, guide: false)));
    await _settle(tester);
    expect(find.text(en.rtLoadErrorTitle), findsOneWidget);
    await tester.tap(find.text(en.rtRetry));
    await _settle(tester);
    expect(fail.calls.where((c) => c == 'overview').length, 2);
  });

  testWidgets('customer inbox: reply and stop', (tester) async {
    _phone(tester, height: 1400);
    final src = FakeRetention();
    await tester.pumpWidget(_app(RetentionInboxScreen(source: src)));
    await _settle(tester);
    expect(find.text('Rina Store'), findsOneWidget);
    expect(find.text(en.rtStoppedLabel), findsOneWidget); // second shop already stopped
    await tester.tap(find.text(en.rtReply).first);
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Loved it');
    await tester.tap(find.text(en.rtSend));
    await _settle(tester);
    expect(src.lastReply, 'Loved it');

    await tester.tap(find.text(en.rtStop).first);
    await _settle(tester);
    expect(find.text(en.rtStopTitle('Rina Store')), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, en.rtStop));
    await _settle(tester);
    expect(src.stopped, 7);
    expect(find.text(en.rtStoppedLabel), findsNWidgets(2));
  });

  testWidgets('inbox empty + hidden', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(RetentionInboxScreen(source: FakeRetention('inbox_empty'))));
    await _settle(tester);
    expect(find.text(en.rtInboxEmpty), findsOneWidget);
    await tester.pumpWidget(_app(RetentionInboxScreen(source: FakeRetention('off'))));
    await _settle(tester);
    expect(find.text(en.rtFeatureOffTitle), findsOneWidget);
  });

  for (final variant in [
    (lang: 'bn', dark: true, scale: 2.0),
    (lang: 'en', dark: false, scale: 2.0),
  ]) {
    testWidgets('every retention screen: ${variant.lang} dark=${variant.dark} 200% — no overflow',
        (tester) async {
      _phone(tester);
      for (final e in retention1Shots.entries) {
        await tester.pumpWidget(
            _app(e.value(variant.lang), lang: variant.lang, scale: variant.scale, dark: variant.dark));
        await _settle(tester, 10);
        final err = tester.takeException();
        expect(err, isNull, reason: '${e.key}: $err');
      }
    });
  }
}
