// cctvcap (owner decision 3 Nov 10:40): the CCTV caps in the app — AI checks
// line, 80 % / 100 % Bangla notices, "SOS / alerts / evidence never stop",
// the one-tap "বাড়তি প্যাক" (credits; not-enough-credits is never a dead
// end), and live view preferring P2P / same Wi-Fi (held relay candidates +
// the path chip).
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:assisto/api.dart';
import 'package:assisto/cctvguard/cctv_usage_card.dart';
import 'package:assisto/cctvguard/live_cost.dart';
import 'package:assisto/cctvguard/live_path_chip.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/theme.dart';

import 'cctvcap_fakes.dart';

Widget _app(Widget home, {String lang = 'en', double scale = 1.0, bool dark = false}) => MaterialApp(
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
    );

Widget _card(FakePackBuyer buyer, {String lang = 'en', Map<String, dynamic>? usage,
        VoidCallback? onGetCredits}) =>
    Scaffold(
      body: ListView(children: [
        CctvUsageCard(
          load: () async => usage ?? cgUsageCap(lang: lang),
          buy: buyer.call,
          onGetCredits: onGetCredits,
        ),
      ]),
    );

const _relay = 'candidate:1 1 udp 41885439 203.0.113.9 50000 typ relay raddr 0.0.0.0 rport 0';
const _host = 'candidate:2 1 udp 2122260223 192.168.1.20 40000 typ host generation 0';

void main() {
  group('prefer P2P / same Wi-Fi', () {
    test('relay candidates are held 1.5 s by default', () {
      final h = RelayCandidateHold(send: (_) {});
      expect(h.hold, const Duration(milliseconds: 1500));
      h.dispose();
    });

    test('same Wi-Fi connects first: our relay is never offered', () async {
      final sent = <String>[];
      final h = RelayCandidateHold(
          send: (c) => sent.add(c['candidate'] as String), hold: const Duration(milliseconds: 20));
      h.offer({'candidate': _relay});
      h.offer({'candidate': _host});
      expect(sent, [_host]); // host goes out at once, relay waits
      h.connected();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sent, [_host]);
      expect(LiveCost.pathOf('host', 'host'), LivePath.lan);
      h.dispose();
    });

    test('badge: relay latches; only relay uses the allowance', () {
      expect(LiveCost.badge(relayed: false, path: LivePath.lan), LivePath.lan);
      expect(LiveCost.badge(relayed: false, path: LivePath.direct), LivePath.direct);
      expect(LiveCost.badge(relayed: true, path: LivePath.direct), LivePath.relay);
      expect(LiveCost.badge(relayed: false, path: LivePath.unknown), LivePath.unknown);
      expect(LiveCost.countsAgainstAllowance(LivePath.relay), isTrue);
      expect(LiveCost.countsAgainstAllowance(LivePath.lan), isFalse);
      expect(LiveCost.countsAgainstAllowance(LivePath.direct), isFalse);
    });

    testWidgets('path chip: same Wi-Fi / direct / relay, hidden when unknown', (tester) async {
      Future<void> show(LivePath p, {bool relayed = false, String lang = 'en'}) =>
          tester.pumpWidget(_app(Scaffold(body: Center(child: LivePathChip(path: p, relayed: relayed))),
              lang: lang));
      await show(LivePath.lan);
      expect(find.text('Direct · same Wi-Fi'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_rounded), findsOneWidget);
      await show(LivePath.direct);
      expect(find.text('Direct (free)'), findsOneWidget);
      await show(LivePath.direct, relayed: true);
      expect(find.text('Relay'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_sync_rounded), findsOneWidget);
      await show(LivePath.unknown);
      expect(find.byKey(const Key('shopLivePath')), findsNothing);
      await show(LivePath.lan, lang: 'bn');
      expect(find.byKey(const Key('shopLivePath')), findsOneWidget);
    });
  });

  group('caps on the camera screen', () {
    testWidgets('bn: AI line in Bangla digits, full pill, safety line, pack button', (tester) async {
      await tester.pumpWidget(_app(_card(FakePackBuyer(lang: 'bn'), lang: 'bn'), lang: 'bn'));
      await tester.pump();
      expect(find.text('AI ছবি-যাচাই: এই মাসে ১০০টির মধ্যে ১০০টি'), findsOneWidget);
      expect(find.text('এই মাসের AI যাচাই শেষ'), findsOneWidget);
      expect(find.textContaining('(AI নয়)'), findsOneWidget);
      expect(find.text('SOS, সতর্কতা, ছবি ও প্রমাণ কখনো থামে না।'), findsOneWidget);
      expect(find.text('বাড়তি প্যাক'), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('cctvCapPackBtn'))).height,
          greaterThanOrEqualTo(48));
    });

    testWidgets('AI at 80 %: notice pill, no "used up"', (tester) async {
      await tester.pumpWidget(_app(_card(FakePackBuyer(),
          usage: {...cgUsageCap(), 'cap': cgCap(relay: 'ok', ai: 'notice', aiUsed: 80)})));
      await tester.pump();
      expect(find.text('80% of AI checks used'), findsOneWidget);
      expect(find.text('AI checks used up this month'), findsNothing);
      expect(find.byKey(const Key('cctvCapPackBtn')), findsOneWidget);
    });

    testWidgets('below 80 % on both: no notice, no pack button', (tester) async {
      await tester.pumpWidget(_app(_card(FakePackBuyer(),
          usage: {...cgUsageCap(relay: 'ok'), 'cap': cgCap(relay: 'ok', ai: 'ok', aiUsed: 10)})));
      await tester.pump();
      expect(find.byKey(const Key('cctvCapAiLine')), findsOneWidget);
      expect(find.byKey(const Key('cctvCapPackBtn')), findsNothing);
      expect(find.byKey(const Key('cctvCapSafety')), findsNothing);
    });

    testWidgets('limits off: counted only, never a pack offer', (tester) async {
      await tester.pumpWidget(_app(_card(FakePackBuyer(), usage: cgUsageCap(enforced: false, ai: 'ok'))));
      await tester.pump();
      expect(find.byKey(const Key('cctvCapPackBtn')), findsNothing);
    });

    testWidgets('bn: one tap buys the relay pack; the card refreshes', (tester) async {
      final buyer = FakePackBuyer(lang: 'bn');
      await tester.pumpWidget(_app(_card(buyer, lang: 'bn'), lang: 'bn'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cctvCapPackBtn')));
      await tester.pumpAndSettle();
      expect(find.text('এই মাসের জন্য বাড়তি প্যাক'), findsOneWidget);
      expect(find.text('রিলে-লাইভ +১ GB'), findsOneWidget);
      expect(find.text('AI ছবি-যাচাই +১০০টি'), findsOneWidget);
      expect(find.text('১৫০ টাকা · ১৫০ ক্রেডিট'), findsOneWidget);
      expect(find.text('আপনার ক্রেডিট: ১২০'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cctvCapBuy_relay')));
      await tester.pumpAndSettle();
      expect(buyer.calls, ['relay']);
      expect(find.text('এই মাসের জন্য বাড়তি প্যাক'), findsNothing); // sheet closed
      expect(find.text('এই মাসের জন্য প্যাক যোগ হয়েছে।'), findsOneWidget);
    });

    testWidgets('not enough credits: honest line + "get credits" (no dead end)', (tester) async {
      final buyer = FakePackBuyer()..failWith = ApiException('Not enough credits — add credits first.', 402);
      var opened = 0;
      await tester.pumpWidget(_app(_card(buyer, onGetCredits: () => opened++)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('cctvCapPackBtn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cctvCapBuy_ai')));
      await tester.pumpAndSettle();
      expect(find.text('Not enough credits — add credits first.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cctvCapGetCredits')));
      await tester.pump();
      expect(opened, 1);
      // a retry after a failure works again (buttons are re-enabled)
      buyer.failWith = null;
      await tester.tap(find.byKey(const Key('cctvCapBuy_ai')));
      await tester.pumpAndSettle();
      expect(buyer.calls, ['ai', 'ai']);
    });

    testWidgets('200% font + dark (card + sheet): no overflow', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 760 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_card(FakePackBuyer(lang: 'bn'), lang: 'bn'),
          lang: 'bn', scale: 2.0, dark: true));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('cctvCapPackBtn')));
      await tester.tap(find.byKey(const Key('cctvCapPackBtn')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
