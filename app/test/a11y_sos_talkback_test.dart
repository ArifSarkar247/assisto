// a11ysweep — SOS with TalkBack: safe for blind and low-vision users.
//
// With TalkBack on (accessibleNavigation), every SOS countdown must
//   * last at least 10 s (a TalkBack user swipes to find Cancel),
//   * speak the seconds left (live region, Bangla digits in Bangla),
//   * put Cancel FIRST in reading order,
//   * never send while the user is still deciding,
// and the receiver's alarm puts "Silence" first (the siren drowns TalkBack).
// Without TalkBack nothing changes (5 s, Send now above Cancel).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/api.dart';
import 'package:assisto/family_sos/sos_alarm_screen.dart';
import 'package:assisto/family_sos/sos_sender_screen.dart';
import 'package:assisto/family_sos/sos_sms.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/a11y_prefs.dart';
import 'package:assisto/widgets/sos_a11y.dart';

import 'fcsos_fakes.dart';

Widget _app(Widget child, {String lang = 'en'}) {
  final app = AppState()
    ..api = ApiClient()
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '', autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      theme: AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    ),
  );
}

SosSenderScreen _sender(FakeFcSosApi api) => SosSenderScreen(
      api: api,
      recorder: FakeSosRecorder(),
      locate: () async => (23.7461, 90.3742),
      smsContacts: const [SosSmsContact('Ammu', '01711200002')],
      country: 'BD',
      openUri: (u) async {},
    );

void _talkBack(WidgetTester tester, bool on) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(accessibleNavigation: on);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Labels of the tappable nodes in TalkBack reading order.
List<String> _readingOrder(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    if (d.hasAction(SemanticsAction.tap) && !n.isMergedIntoParent) {
      out.add(d.label.isNotEmpty ? d.label : d.tooltip);
    }
    for (final c in n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)) {
      visit(c);
    }
  }

  for (final v in tester.binding.renderViews) {
    visit(v.owner!.semanticsOwner!.rootSemanticsNode!);
  }
  return out;
}

Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('countdown length: 10 s with a screen reader, unchanged otherwise', () {
    expect(sosCountdownSeconds(5, screenReader: true), kSosTalkBackSeconds);
    expect(sosCountdownSeconds(5, screenReader: false), 5);
    expect(sosCountdownSeconds(15, screenReader: true), 15);
    expect(sosCountdownSeconds(0, screenReader: true), 0, reason: 'already confirmed: send at once');
  });

  test('phone font size is honoured (up to 200%); the in-app slider only adds', () {
    expect(effectiveTextScaler(const TextScaler.linear(2.0), 1.0).scale(10), 20);
    expect(effectiveTextScaler(const TextScaler.linear(3.0), 1.0).scale(10), 20,
        reason: 'capped at 200%');
    expect(effectiveTextScaler(TextScaler.noScaling, 1.3).scale(10), 13);
    expect(effectiveTextScaler(const TextScaler.linear(1.6), 1.3).scale(10), 16);
  });

  for (final lang in ['bn', 'en']) {
    testWidgets('TalkBack SOS sender ($lang): 10 s, seconds spoken, Cancel first, nothing sent early',
        (tester) async {
      _talkBack(tester, true);
      final h = tester.ensureSemantics();
      final api = FakeFcSosApi(lang: lang);
      await tester.pumpWidget(_app(_sender(api), lang: lang));
      await tester.pump();
      final t = await AppLocalizations.delegate.load(Locale(lang));
      final ten = lang == 'bn' ? '১০' : '10';
      expect(find.text(ten), findsOneWidget, reason: 'TalkBack users get 10 s');
      expect(find.bySemanticsLabel(t.a11ySosSecondsLeft(ten)), findsOneWidget);
      final number = tester.getSemantics(find.bySemanticsLabel(t.a11ySosSecondsLeft(ten)));
      expect(number.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      final order = _readingOrder(tester);
      final cancel = order.indexWhere((l) => l.contains(t.fcsCancelMistake));
      final send = order.indexWhere((l) => l.contains(t.fcsSendNow));
      expect(cancel, isNonNegative, reason: '$order');
      expect(send, greaterThan(cancel), reason: 'Cancel must be read before Send now: $order');
      // 6 s later (a sighted user's countdown would have fired): still nothing
      await tester.pump(const Duration(seconds: 6));
      expect(api.calls.where((c) => c.startsWith('send')), isEmpty);
      expect(find.bySemanticsLabel(t.a11ySosSecondsLeft(lang == 'bn' ? '৪' : '4')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fcs-cancel')));
      await tester.pump(const Duration(seconds: 11));
      expect(api.calls.where((c) => c.startsWith('send')), isEmpty);
      h.dispose();
      await _dispose(tester);
    });
  }

  testWidgets('TalkBack SOS sender: the countdown still sends when the user does nothing',
      (tester) async {
    _talkBack(tester, true);
    final api = FakeFcSosApi();
    await tester.pumpWidget(_app(_sender(api)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(api.calls.where((c) => c.startsWith('send')), isEmpty);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(api.calls.where((c) => c.startsWith('send')).length, 1);
    await _dispose(tester);
  });

  testWidgets('no TalkBack: 5 s and Send now above Cancel (unchanged)', (tester) async {
    _talkBack(tester, false);
    final api = FakeFcSosApi();
    await tester.pumpWidget(_app(_sender(api)));
    await tester.pump();
    expect(find.text('5'), findsOneWidget);
    final sendY = tester.getTopLeft(find.byKey(const ValueKey('fcs-send-now'))).dy;
    final cancelY = tester.getTopLeft(find.byKey(const ValueKey('fcs-cancel'))).dy;
    expect(sendY, lessThan(cancelY));
    await tester.tap(find.byKey(const ValueKey('fcs-cancel')));
    await _dispose(tester);
  });

  testWidgets('TalkBack alarm receiver: Silence is the first control after Close', (tester) async {
    _talkBack(tester, true);
    final h = tester.ensureSemantics();
    final sound = FakeAlarmSound();
    await tester.pumpWidget(_app(SosAlarmScreen(
        data: fcsPush('en'), api: FakeFcSosApi(), sound: sound, openUri: (u) async {})));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final t = await AppLocalizations.delegate.load(const Locale('en'));
    final order = _readingOrder(tester);
    final silence = order.indexWhere((l) => l.contains(t.fcsSilence));
    final going = order.indexWhere((l) => l.contains(t.fcsIamGoing));
    expect(silence, isNonNegative, reason: '$order');
    expect(silence, lessThan(going), reason: 'Silence before I am going: $order');
    expect(silence, lessThanOrEqualTo(1), reason: 'only Close may come first: $order');
    // every call button names who/what it calls
    expect(order.where((l) => l.trim() == t.fcsCall), isEmpty, reason: '$order');
    h.dispose();
    await _dispose(tester);
  });
}
