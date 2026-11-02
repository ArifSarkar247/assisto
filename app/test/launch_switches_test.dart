// launch (8 Nov narrow production, owner_actions/LAUNCH_SWITCHES_8NOV_BN.md):
// with the RECOMMENDED switch set, no visible entry point may lead to a
// hidden feature, and no AI surface may pretend an AI answered while no AI
// provider key is live.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:assisto/billing/billing_format.dart';
import 'package:assisto/feature_flags.dart';
import 'package:assisto/feature_registry.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/screens/business/ai_assistant_screen.dart'
    show isRuleDraft;
import 'package:assisto/screens/business/bizagent/seller_agent_screen.dart'
    show baAiSwitchSub;
import 'package:assisto/screens/business/bizagent/seller_inbox_screen.dart'
    show isRuleReplySource;
import 'package:assisto/screens/home_v2/home_v2_shortcuts.dart';
import 'package:assisto/screens/onboarding_screen.dart'
    show OnbStep, onboardingSteps;
import 'package:assisto/screens/web_photo_link_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/chatnav.dart';
import 'package:assisto/widgets/feature_unavailable.dart';
import 'package:assisto/widgets/sidebar_sections.dart';

/// The recommended 8 Nov Play set (LAUNCH_SWITCHES_8NOV_BN.md): ON only for
/// these; every other registry key OFF.
const kLaunchOn = {
  'my_circle', 'calls', // My Circle messages + calls
  'reminders', 'notes', 'memory', // reminders + notes (+ "AI knows" privacy view)
  'money', 'budget', 'budget_remittance', // budget + remittance
  'family', 'safe_journey', 'emergency', // Family SOS + alerts, Safe Journey
  'business', 'crm', 'contacts', // khata + CRM (+ its contacts list)
  'documents', // notes attach papers, family card shares documents
  'voice_assistant', // the frozen home's centre voice button
  'referral', // My Circle invite + plans/credits
  'home_v2', // the frozen home
};

Map<String, bool> launchSet() =>
    {for (final k in kFeatureDefaults.keys) k: kLaunchOn.contains(k)};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Settings.resetForTest();
    FeatureFlags.instance.resetForTest();
  });
  tearDown(() => FeatureFlags.instance.resetForTest());

  test('every recommended key is a real registry key', () {
    for (final k in kLaunchOn) {
      expect(kFeatureDefaults.containsKey(k), isTrue, reason: k);
    }
  });

  group('launch set: no visible entry leads to a hidden feature', () {
    setUp(() => FeatureFlags.instance.debugOverride = launchSet());

    test('ChatNav routes: none belongs to a switched-off feature', () {
      for (final r in ChatNav.routes.keys) {
        final f = FeatureFlags.featureOf(r);
        if (f != null) expect(kLaunchOn, contains(f), reason: r);
      }
      // the elderly home's Help tile opens 'guide' (Service guide, OFF)
      expect(ChatNav.routes.containsKey('guide'), isFalse);
      expect(ChatNav.routes.containsKey('photo_studio'), isFalse);
    });

    test('sidebar / All Services / search: only ON features', () {
      for (final s in SidebarSections.all) {
        for (final i in s.items) {
          if (i.feature != null) {
            expect(kLaunchOn, contains(i.feature), reason: i.feature);
          }
        }
      }
    });

    test('home shortcut catalogue: only routes that really open', () {
      for (final s in HomeV2Shortcuts.catalog) {
        expect(FeatureFlags.instance.homeTileAllowed(s.route), isTrue,
            reason: s.route);
      }
      expect(HomeV2Shortcuts.catalog.map((s) => s.route),
          isNot(contains('watchman')));
      expect(HomeV2Shortcuts.catalog.map((s) => s.route),
          isNot(contains('sales_agent')));
      expect(HomeV2Shortcuts.catalog.map((s) => s.route),
          isNot(contains('vehicle_tracking')));
    });

    test('onboarding: no offers page (offers OFF), assistant page stays', () {
      final steps = onboardingSteps();
      expect(steps, isNot(contains(OnbStep.offers)));
      expect(steps, contains(OnbStep.assistant));
      expect(steps.first, OnbStep.lang);
      expect(steps.last, OnbStep.linkParent);
    });

    test('credits price list: no row for a hidden feature', () {
      for (final code in [
        'photo_enhance', 'photo_colorize', 'ai_sales', 'shop_extra_camera',
        'shop_live_relay_min', 'vehicle_tracking_month', 'remote_support_min',
        'scan_ocr',
      ]) {
        expect(FeatureFlags.instance.isOn(costFeature(code)), isFalse,
            reason: code);
      }
      for (final code in ['ai_msg_cheap', 'video_min', 'sms', 'web_answer']) {
        expect(FeatureFlags.instance.isOn(costFeature(code)), isTrue,
            reason: code);
      }
    });
  });

  group('onboarding pages follow their flags', () {
    test('defaults: all 7 pages', () {
      expect(onboardingSteps().length, 7);
    });
    test('voice + offers OFF: 5 pages, order kept', () {
      FeatureFlags.instance.debugOverride = {
        'voice_assistant': false,
        'offers': false,
      };
      expect(onboardingSteps(), [
        OnbStep.lang,
        OnbStep.role,
        OnbStep.permissions,
        OnbStep.firstWin,
        OnbStep.linkParent,
      ]);
    });
  });

  testWidgets('website photo link with Photo Studio OFF -> friendly notice',
      (tester) async {
    FeatureFlags.instance.debugOverride = {'photo_studio': false};
    await tester.pumpWidget(const MaterialApp(
      locale: Locale('bn'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: WebPhotoLinkScreen(token: 'tok'),
    ));
    await tester.pump();
    expect(find.byType(FeatureUnavailableScreen), findsOneWidget);
  });

  group('AI-key-off honesty (business)', () {
    test('a draft made without AI is a rule draft', () {
      expect(isRuleDraft({'text': 'x', 'mock': true}), isTrue);
      expect(isRuleDraft({'text': 'x', 'mock': false}), isFalse);
      expect(isRuleDraft(null), isFalse);
    });

    test('fallback / rule replies are never labelled AI', () {
      expect(isRuleReplySource('rule'), isTrue);
      expect(isRuleReplySource('fallback'), isTrue);
      expect(isRuleReplySource('ai'), isFalse);
      expect(isRuleReplySource(null), isFalse);
    });

    for (final lang in ['bn', 'en']) {
      test('agent switch subtitle is honest without a key ($lang)', () async {
        final t = await AppLocalizations.delegate.load(Locale(lang));
        expect(baAiSwitchSub(t, false, const {}), t.baAiOffSub);
        expect(baAiSwitchSub(t, true, const {'ai_available': true}),
            t.baAiOnSub);
        // older server without the field: unchanged
        expect(baAiSwitchSub(t, true, const {}), t.baAiOnSub);
        final off = baAiSwitchSub(t, true, const {'ai_available': false});
        expect(off, contains(t.aivNoKeyTitle));
        expect(off, contains(t.g1ByRule));
        expect(off, isNot(contains(t.baAiOnSub)));
      });
    }
  });
}
