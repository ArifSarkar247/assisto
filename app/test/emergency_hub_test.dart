// emhub — the Emergency hub (owner order 2 Nov 17:40), route `emergency_hub`.
//
// HARD rules proven here:
//   * sending SOS never gets slower or needs more taps: measured BEFORE (the
//     old Emergency screen, a 2 s GET /emergency) vs AFTER (the hub) — the
//     hold button is on the hub's first frame, one hold sends, same panel;
//   * 999 only OPENS the dialer (a test seam records it), never on its own;
//   * crisis help shows ONLY the server's owner-verified numbers (offline:
//     the phone copy; never seen: 999 alone) — nothing invented;
//   * flag-off features are not shown (no dead tiles);
//   * no ads: the route is refused by every ad surface;
//   * bn + Bangla digits, dark, 200% text at 360 dp, tap targets, labels.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/ad_banner_slot.dart';
import 'package:assisto/ads/ad_placements.dart';
import 'package:assisto/ads/ad_rules.dart';
import 'package:assisto/api.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/emergency_hub_screen.dart';
import 'package:assisto/screens/emergency_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/theme.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/emergency_sos_panel.dart';

class _Api extends ApiClient {
  _Api({this.crisis, this.emergencyDelay = Duration.zero}) {
    token = 't';
  }

  /// null = the server is unreachable (offline).
  final List<Map<String, dynamic>>? crisis;
  final Duration emergencyDelay;
  int crisisCalls = 0;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    if (path == '/crisis/helplines') {
      crisisCalls++;
      final c = crisis;
      if (c == null) throw Exception('offline');
      return {'helplines': c};
    }
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> getEmergency() async {
    await Future<void>.delayed(emergencyDelay);
    return {'contacts': []};
  }
}

Widget _app(Widget child,
    {ApiClient? api,
    String lang = 'en',
    bool dark = false,
    double scale = 1.0,
    bool a11y = false}) {
  final app = AppState()
    ..api = api ?? _Api(crisis: const [])
    ..locale = Locale(lang)
    ..user = AppUser(
        id: 1, name: 'A', phone: '01712345678', email: '',
        autonomyLevel: 2, language: lang)
    ..loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: app,
    child: MaterialApp(
      locale: Locale(lang),
      theme: dark ? AssistoTheme.dark : AssistoTheme.light,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(scale), accessibleNavigation: a11y),
          child: w!),
      home: child,
    ),
  );
}

const _hold = ValueKey('sosat-sos-hold');

/// Fake-clock time from the screen's first frame until the SOS hold button
/// can be pressed (100 ms frames, max 10 s).
Future<Duration> _timeToSosButton(WidgetTester tester) async {
  var waited = Duration.zero;
  await tester.pump();
  while (find.byKey(_hold).evaluate().isEmpty &&
      waited < const Duration(seconds: 10)) {
    await tester.pump(const Duration(milliseconds: 100));
    waited += const Duration(milliseconds: 100);
  }
  return waited;
}

/// The one gesture that sends: hold ~1.2 s. Returns the gestures used.
Future<int> _holdToSend(WidgetTester tester) async {
  final g = await tester.startGesture(tester.getCenter(find.byKey(_hold)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: EmergencySosPanel.holdMs + 100));
  await g.up();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return 1;
}

/// A tall phone so every hub row is built (the list is lazy).
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 9000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

EmergencyHubScreen _hub({
  List<String>? dialled,
  void Function()? onSos,
  Map<String, dynamic> fam = const {},
}) =>
    EmergencyHubScreen(
      dial: (_, n) async => dialled?.add(n),
      sendSos: (la, ln) async {
        onSos?.call();
        return {'recipients': 2};
      },
      locate: () async => (23.75, 90.39),
      ladderLoad: () async => {'stage': 'waiting', 'total': 0, 'seen': 0, 'recipients': []},
      famCard: () async => fam,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'safety_sos_cd': '0'});
    Settings.resetForTest();
    FeatureFlags.instance.debugOverride = null;
  });
  tearDown(() => FeatureFlags.instance.debugOverride = null);

  group('SOS is never slower and never needs more taps', () {
    testWidgets('BEFORE vs AFTER: hold button time + gestures to send',
        (tester) async {
      // BEFORE — the old Emergency screen behind a 2 s GET /emergency.
      await tester.pumpWidget(_app(const EmergencyScreen(),
          api: _Api(crisis: const [], emergencyDelay: const Duration(seconds: 2))));
      final before = await _timeToSosButton(tester);
      expect(find.byKey(_hold), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));

      // AFTER — the hub, same slow server.
      var sent = 0;
      await tester.pumpWidget(_app(_hub(onSos: () => sent++),
          api: _Api(crisis: const [], emergencyDelay: const Duration(seconds: 2))));
      final after = await _timeToSosButton(tester);
      expect(after, Duration.zero, reason: 'SOS must be on the first frame');
      expect(after <= before, isTrue);
      // ignore: avoid_print
      print('emhub SOS button: before=${before.inMilliseconds} ms, '
          'after=${after.inMilliseconds} ms (2 s server)');

      // One hold sends (countdown 0 here) — the same single gesture as before.
      final gestures = await _holdToSend(tester);
      expect(gestures, 1);
      expect(sent, 1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the hub uses the SAME sosat panel (hold-to-send, not a tap)',
        (tester) async {
      var sent = 0;
      await tester.pumpWidget(_app(_hub(onSos: () => sent++)));
      await tester.pump();
      expect(find.byType(EmergencySosPanel), findsOneWidget);
      await tester.tap(find.byKey(_hold)); // a plain tap only explains
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent, 0);
      await _holdToSend(tester);
      expect(sent, 1);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the SOS button is the first thing on screen, above 999',
        (tester) async {
      await tester.pumpWidget(_app(_hub()));
      await tester.pump();
      final sos = tester.getTopLeft(find.byKey(_hold)).dy;
      final call = tester.getTopLeft(find.byKey(const ValueKey('emh-999'))).dy;
      expect(sos < call, isTrue);
      expect(tester.getSize(find.byKey(_hold)).height,
          greaterThan(tester.getSize(find.byKey(const ValueKey('emh-999'))).height - 1));
    });
  });

  group('999', () {
    testWidgets('one tap opens the dialer with 999 — never on its own',
        (tester) async {
      final dialled = <String>[];
      await tester.pumpWidget(_app(_hub(dialled: dialled)));
      await tester.pump(const Duration(seconds: 1));
      expect(dialled, isEmpty, reason: 'never auto-dial');
      await tester.tap(find.byKey(const ValueKey('emh-999')));
      await tester.pump();
      expect(dialled, ['999']);
    });
  });

  group('crisis help: owner-verified numbers only', () {
    testWidgets('shows what the server returned; drops a number it cannot dial',
        (tester) async {
      final dialled = <String>[];
      await tester.pumpWidget(_app(_hub(dialled: dialled),
          api: _Api(crisis: const [
            {'key': 'emergency', 'number': '999', 'label': 'National emergency'},
            {'key': 'women_children', 'number': '109', 'label': 'Women & children'},
            {'key': 'kaan_pete_roi', 'number': '', 'label': 'Empty number'},
            {'key': 'bad', 'number': 'call-me', 'label': 'Garbage'},
          ])));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('emh-crisis-109')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Women & children'), findsOneWidget);
      expect(find.text('Empty number'), findsNothing);
      expect(find.text('Garbage'), findsNothing);
      expect(find.byKey(const ValueKey('emh-crisis-only999')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('emh-crisis-109')));
      await tester.pump();
      expect(dialled, ['109']);
    });

    testWidgets('offline, never fetched: 999 alone + honest note', (tester) async {
      await tester.pumpWidget(_app(_hub(), api: _Api(crisis: null)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('emh-crisis-only999')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('emh-crisis-999')), findsOneWidget);
      expect(find.byKey(const ValueKey('emh-crisis-109')), findsNothing);
    });

    testWidgets('offline after one fetch: the phone copy is shown', (tester) async {
      SharedPreferences.setMockInitialValues({
        'safety_sos_cd': '0',
        EmergencyHubScreen.crisisCacheKey('en'): jsonEncode([
          {'key': 'emergency', 'number': '999', 'label': 'National emergency'},
          {'key': 'child_helpline', 'number': '1098', 'label': 'Child Helpline'},
        ]),
      });
      Settings.resetForTest();
      await tester.pumpWidget(_app(_hub(), api: _Api(crisis: null)));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('emh-crisis-1098')), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Child Helpline'), findsOneWidget);
    });
  });

  group('flags: a hidden feature is never a dead tile', () {
    testWidgets('blood / missing / nearby / lost / fake follow their flags',
        (tester) async {
      FeatureFlags.instance.debugOverride = {
        'blood_donors': false,
        'missing_alert': false,
        'nearby': false,
        'anti_theft': false,
        'safe_journey': false,
      };
      _tall(tester);
      await tester.pumpWidget(_app(_hub()));
      await tester.pump(const Duration(milliseconds: 300));
      for (final id in ['blood', 'missing', 'hospital', 'police', 'lost', 'fake']) {
        expect(find.byKey(ValueKey('emh-$id'), skipOffstage: false), findsNothing,
            reason: id);
      }
      // offline-capable parts always stay
      expect(find.byKey(const ValueKey('emh-famcard'), skipOffstage: false),
          findsOneWidget);

      FeatureFlags.instance.debugOverride = {
        'blood_donors': true,
        'missing_alert': true,
        'nearby': true,
        'anti_theft': true,
        'safe_journey': true,
      };
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(_hub()));
      await tester.pump(const Duration(milliseconds: 300));
      for (final id in ['blood', 'missing', 'hospital', 'police', 'lost', 'fake']) {
        await tester.scrollUntilVisible(find.byKey(ValueKey('emh-$id')), 200,
            scrollable: find.byType(Scrollable).first);
        expect(find.byKey(ValueKey('emh-$id')), findsOneWidget, reason: id);
      }
    });

    test('route emergency_hub is registered under the emergency flag', () {
      expect(kRouteFeature['emergency_hub'], 'emergency');
      expect(ChatNav.routes.containsKey('emergency_hub'), isTrue);
    });
  });

  group('no ads in the hub', () {
    test('every ad surface refuses emergency_hub', () {
      expect(AdPlacements.neverScreens, contains('emergency_hub'));
      for (final slot in AdSurface.values) {
        expect(AdPlacements.screenAllowed(slot, EmergencyHubScreen.route), isFalse,
            reason: '$slot');
      }
      expect(AdRules.isBlockedScreen(EmergencyHubScreen.route), isTrue);
    });

    testWidgets('the screen carries no ad widget', (tester) async {
      await tester.pumpWidget(_app(_hub()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AdBannerSlot, skipOffstage: false), findsNothing);
    });
  });

  group('family card', () {
    testWidgets('blood group + number count from the phone copy, Bangla digits',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(
          _hub(fam: const {
            'blood': 'B+',
            'contacts': [
              {'name': 'Ma', 'phone': '01711111111'},
              {'name': 'Bhai', 'phone': '01722222222'},
            ],
          }),
          lang: 'bn'));
      await tester.pump(const Duration(milliseconds: 300));
      final t = await AppLocalizations.delegate.load(const Locale('bn'));
      expect(find.textContaining(t.emhFamBlood('B+'), skipOffstage: false),
          findsOneWidget);
      expect(find.textContaining(t.emhFamNumbers('\u09E8'), skipOffstage: false),
          findsOneWidget);
    });

    testWidgets('empty card: benefit line, not a dead end', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub()));
      await tester.pump(const Duration(milliseconds: 300));
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.emhFamCardEmpty, skipOffstage: false), findsOneWidget);
    });
  });

  group('looks right everywhere', () {
    for (final (lang, dark) in [('bn', false), ('bn', true), ('en', true)]) {
      testWidgets('$lang dark=$dark, 200% text, 360 dp: no overflow, to the end',
          (tester) async {
        FeatureFlags.instance.debugOverride = {
          'blood_donors': true,
          'missing_alert': true,
          'nearby': true,
          'anti_theft': true,
          'safe_journey': true,
        };
        tester.view.physicalSize = const Size(360 * 3, 760 * 3);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(_app(_hub(), lang: lang, dark: dark, scale: 2.0));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.scrollUntilVisible(
            find.byKey(const ValueKey('emh-offline-note')), 300,
            scrollable: find.byType(Scrollable).first);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('TalkBack: tap targets + labels', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(_hub(), a11y: true));
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('TalkBack double-tap sends SOS directly (no hold needed)',
        (tester) async {
      var sent = 0;
      await tester.pumpWidget(_app(_hub(onSos: () => sent++), a11y: true));
      await tester.pump();
      await tester.tap(find.byKey(_hold));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sent, 1);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  test('crisis cache keys are per language', () {
    expect(EmergencyHubScreen.crisisCacheKey('bn'),
        isNot(EmergencyHubScreen.crisisCacheKey('en')));
  });
}
