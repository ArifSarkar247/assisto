// p2-money: gallery states for test/screenshots_test.dart — the full-screen
// sponsor card (countdown + skippable), the Sponsored post, the home-hero
// sponsor, "why am I seeing this", offers settings + feed + onboarding step,
// and the paywall for each moment of need.
import 'package:flutter/material.dart';

import 'package:assisto/ads/sponsor_models.dart';
import 'package:assisto/ads/sponsor_widgets.dart';
import 'package:assisto/screens/offers_screens.dart';
import 'package:assisto/widgets/paywall_sheet.dart';

import 'p2_fakes.dart';

Widget _sheetLike(Widget child) => Scaffold(
      backgroundColor: Colors.black54,
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsets.only(top: 24), child: child),
        ),
      ),
    );

SponsorCreative _c(String placement, {bool match = false}) =>
    SponsorCreative.fromJson(p2Creative(placement: placement, match: match))!;

Widget _pay(PaywallReason r, String l, {bool trial = true}) => _sheetLike(PaywallSheet(
    reason: r,
    backend: FakeSponsorBackend(),
    offer: p2Offer(trial: trial, bn: l == 'bn')));

final Map<String, Widget Function(String)> p2Shots = {
  'p2_appopen_countdown': (_) => SponsorAppOpenScreen(
      creative: _c('app_open'), backend: FakeSponsorBackend(), autoTick: false),
  'p2_post_end_of_channel': (_) => Scaffold(
        appBar: AppBar(title: const Text('Dhaka Deals')),
        body: ListView(children: [
          const SizedBox(height: 120),
          SponsoredPostCard(creative: _c('community_post')),
        ]),
      ),
  'p2_hero_sponsor': (_) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SponsorHeroCard(creative: _c('hero'), height: 280),
          ),
        ),
      ),
  'p2_why_sheet': (_) => _sheetLike(SponsorWhySheet(
      creative: _c('community_post'), onHide: () {}, onMute: () {})),
  'p2_offers_settings': (_) => OffersSettingsScreen(backend: FakeSponsorBackend()),
  'p2_offers_feed': (_) => OffersFeedScreen(backend: FakeSponsorBackend()),
  'p2_onb_offers': (_) => const Scaffold(body: SafeArea(child: OnbOffersStep())),
  'p2_paywall_credits': (l) => _pay(PaywallReason.outOfCredits, l),
  'p2_paywall_video': (l) => _pay(PaywallReason.videoCall, l),
  'p2_paywall_adfree_no_trial': (l) => _pay(PaywallReason.adFree, l, trial: false),
  'p2_paywall_family': (l) => _pay(PaywallReason.familyLimit, l),
};
