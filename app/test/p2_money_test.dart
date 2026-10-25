// p2-money: app-open gate logic, sponsor card skip countdown, paywall
// reasons + trial, offers settings, sponsored post slot.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/ads/app_open_gate.dart';
import 'package:assisto/ads/sponsor_models.dart';
import 'package:assisto/ads/sponsor_widgets.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/offers_screens.dart';
import 'package:assisto/widgets/paywall_sheet.dart';

import 'p2_fakes.dart';

Widget _host(Widget child, {String lang = 'en'}) => MaterialApp(
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
  final now = DateTime(2026, 10, 23, 12);

  AdDecisionLike gate({
    bool paid = false,
    String screen = 'home',
    String entry = '',
    DateTime? joined,
    int shown = 0,
    DateTime? last,
    int cap = 3,
  }) =>
      AdDecisionLike(AppOpenGate.decide(
        loggedIn: true,
        paid: paid,
        enabled: true,
        screen: screen,
        entry: entry,
        now: now,
        joined: joined ?? DateTime(2026, 10, 20),
        dailyCap: cap,
        shownToday: shown,
        lastShownAt: last,
      ).reason);

  group('app-open gate', () {
    test('day 2 after sign-up, not the sign-up day', () {
      expect(gate(joined: DateTime(2026, 10, 23, 8)).r, 'too_new');
      expect(gate(joined: DateTime(2026, 10, 22, 23)).r, 'ok');
      expect(AppOpenGate.dayNumber(DateTime(2026, 10, 22, 23), now), 2);
    });

    test('max 3 a day + min gap (never below 1 h)', () {
      expect(gate(shown: 3).r, 'daily_cap');
      expect(gate(shown: 2).r, 'ok');
      expect(gate(last: now.subtract(const Duration(hours: 2))).r, 'too_soon');
      expect(gate(last: now.subtract(const Duration(hours: 3))).r, 'ok');
      expect(gate(cap: 0).r, 'disabled');
    });

    test('Free only; never on sensitive screens', () {
      expect(gate(paid: true).r, 'paid_plan');
      for (final s in ['sos', 'voice_sos', 'payment', 'checkout', 'plans', 'login',
        'otp', 'circle_call', 'incoming_call', 'unknown', 'credits']) {
        expect(gate(screen: s).r, 'blocked_screen', reason: s);
      }
    });

    test('never after a notification / deep link / call / SOS entry', () {
      for (final e in ['notification', 'deeplink', 'call', 'sos', 'widget', 'assist']) {
        expect(gate(entry: e).r, 'blocked_entry', reason: e);
      }
      AppEntry.mark('notification', now: now);
      expect(AppEntry.blocked(now: now.add(const Duration(seconds: 5))), isTrue);
      expect(AppEntry.blocked(now: now.add(const Duration(seconds: 25))), isFalse);
      AppEntry.reset();
      expect(AppEntry.current(), '');
    });

    test('skip countdown: 5 s minimum, clamped', () {
      final c = SkipCountdown(5);
      expect(c.canSkip, isFalse);
      for (var i = 0; i < 4; i++) {
        c.tick();
      }
      expect(c.remaining, 1);
      expect(c.canSkip, isFalse);
      c.tick();
      expect(c.canSkip, isTrue);
      expect(c.tick(), isFalse);
      expect(SkipCountdown(1).total, 5);
      expect(SkipCountdown(60).total, 15);
      expect(AdSlot.fromJson({'skip_after_s': 2}).skipAfterS, 5);
    });

    test('slot parsing: direct first, admob fill, none', () {
      final d = AdSlot.fromJson({'show': true, 'source': 'direct', 'creative': p2Creative()});
      expect(d.isDirect, isTrue);
      expect(d.creative!.title(false), '10% off new phones');
      expect(d.creative!.hasLink, isTrue);
      expect(AdSlot.fromJson({'show': true, 'source': 'admob'}).isAdmob, isTrue);
      expect(AdSlot.fromJson({'show': false, 'reason': 'no_fill'}).isDirect, isFalse);
      expect(SponsorCreative.fromJson({'campaign_id': 0}), isNull);
    });
  });

  group('sponsor app-open card', () {
    testWidgets('Skip works only after the countdown; impression once', (tester) async {
      final b = FakeSponsorBackend();
      final c = SponsorCreative.fromJson(p2Creative())!;
      final key = GlobalKey<SponsorAppOpenScreenState>();
      await tester.pumpWidget(_host(SponsorAppOpenScreen(
          key: key, creative: c, skipAfterS: 5, backend: b, autoTick: false)));
      await tester.pump();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2Sponsored), findsOneWidget);
      expect(find.text(t.p2SkipIn('5')), findsOneWidget);
      final skip = tester.widget<OutlinedButton>(find.byKey(const Key('p2-skip')));
      expect(skip.onPressed, isNull);
      for (var i = 0; i < 5; i++) {
        key.currentState!.tick();
      }
      await tester.pump();
      expect(find.text(t.p2Skip), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('p2-skip'))).onPressed,
          isNotNull);
      expect(b.events, ['impression:tok-7']);
    });
  });

  group('paywall', () {
    test('every reason has its own headline', () async {
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      final heads = PaywallReason.values.map((r) => paywallReasonText(t, r).$1).toSet();
      expect(heads.length, PaywallReason.values.length);
      expect(PaywallReason.outOfCredits.wire, 'out_of_credits');
      expect(PaywallReason.videoCall.wire, 'video_call');
    });

    testWidgets('benefits, safe yearly price, trial once', (tester) async {
      final b = FakeSponsorBackend();
      await tester.pumpWidget(_host(Scaffold(
          body: PaywallSheet(reason: PaywallReason.outOfCredits, backend: b))));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2PayReasonCredits), findsOneWidget);
      expect(find.text('90 AI credits every month'), findsOneWidget);
      expect(find.text(t.p2PayYearly('2,173', '9')), findsOneWidget);
      await tester.tap(find.byKey(const Key('p2-trial')));
      await tester.pumpAndSettle();
      expect(b.trials, 1);
      expect(find.text(t.p2PayTrialStarted('3')), findsOneWidget);
      expect(find.byKey(const Key('p2-trial')), findsNothing);
    });

    testWidgets('no trial button when it was used', (tester) async {
      final b = FakeSponsorBackend(offer: p2Offer(trial: false));
      await tester.pumpWidget(_host(Scaffold(
          body: PaywallSheet(reason: PaywallReason.adFree, backend: b))));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2PayReasonAdFree), findsOneWidget);
      expect(find.byKey(const Key('p2-trial')), findsNothing);
    });
  });

  group('offers settings', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('pick categories, notifications off, mute a brand', (tester) async {
      final b = FakeSponsorBackend();
      await tester.pumpWidget(_host(OffersSettingsScreen(backend: b)));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2OffersNotifsSub('2')), findsOneWidget);
      await tester.tap(find.text(t.p2CatFashion));
      await tester.pumpAndSettle();
      expect(b.saved.last['categories'], containsAll(['mobile', 'fashion']));
      await tester.tap(find.text(t.p2OffersNotifs));
      await tester.pumpAndSettle();
      expect(b.saved.last, {'notifs_on': false});
      // let the "Saved" snackbar go away (it covers the bottom rows)
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Shapla Mobile'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shapla Mobile'));
      await tester.pumpAndSettle();
      expect(b.muted[3], isTrue);
    });

    testWidgets('Premium: honest "offers are off" note', (tester) async {
      final b = FakeSponsorBackend(prefs: {
        'categories': [], 'notifs_on': true, 'notif_daily_cap': 2,
        'paid': true, 'premium_gets_offers': false,
      });
      await tester.pumpWidget(_host(OffersSettingsScreen(backend: b)));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2OffersPremiumOff), findsOneWidget);
    });

    testWidgets('onboarding picks wait locally and sync later', (tester) async {
      await tester.pumpWidget(_host(const Scaffold(body: OnbOffersStep())));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      await tester.tap(find.text(t.p2CatHealth));
      await tester.pumpAndSettle();
      final b = FakeSponsorBackend();
      await syncPendingOfferPrefs(b);
      expect(b.saved.single['categories'], ['health']);
      await syncPendingOfferPrefs(b);
      expect(b.saved.length, 1);
    });
  });

  group('sponsored post slot', () {
    testWidgets('direct creative renders with label; hide removes it', (tester) async {
      final b = FakeSponsorBackend(slotJson: {
        'show': true, 'source': 'direct',
        'creative': p2Creative(placement: 'community_post')
      });
      await tester.pumpWidget(_host(Scaffold(
          body: ListView(children: [SponsoredPostSlot(ctxKind: 'channel', ctxId: 1, backend: b)]))));
      await tester.pumpAndSettle();
      final t = await AppLocalizations.delegate.load(const Locale('en'));
      expect(find.text(t.p2Sponsored), findsOneWidget);
      expect(b.events, ['impression:tok-7']);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.p2HideAd));
      await tester.pumpAndSettle();
      expect(find.text(t.p2Sponsored), findsNothing);
      expect(b.events.last, 'hide:tok-7');
    });

    testWidgets('no fill -> nothing at all', (tester) async {
      final b = FakeSponsorBackend(slotJson: {'show': false, 'reason': 'too_small'});
      await tester.pumpWidget(_host(Scaffold(
          body: ListView(children: [SponsoredPostSlot(ctxKind: 'channel', ctxId: 1, backend: b)]))));
      await tester.pumpAndSettle();
      expect(find.byType(SponsoredPostCard), findsNothing);
    });
  });
}

class AdDecisionLike {
  AdDecisionLike(this.r);
  final String r;
}
