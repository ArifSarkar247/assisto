import 'package:flutter/material.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../payments/credits_out_sheet.dart';
import '../screens/probashi/probashi_plan_screen.dart';
import '../safe_plans/safe_plans_screen.dart';
import 'cctv_locked_sheet.dart';
import 'plans_v2.dart';
import 'upgrade_sheet.dart';

/// buyinside (owner order 10 Nov 00:50) — "buy inside every paid feature".
///
/// Many users never find the Plans page, so every paid feature opens its OWN
/// buy screen at the exact moment the need appears, and the user comes back
/// to the same screen with the feature unlocked (the call returns true; the
/// caller reloads / re-sends the kept request once):
///
///  * a plan feature (Premium / Business) -> [UpgradeSheet]: icon, feature
///    name, 3 benefits, "Start 7 days free" (only while the server says the
///    trial is available), the price button, "then X a month · cancel any
///    time · paid with Google Play", a link to all plans;
///  * CCTV -> [CctvLockedSheet] (the Play subscription with its 7-day free
///    trial offer, 500 Tk a month for 2 cameras);
///  * a credit feature (AI chat, photo, any credit use) -> the credits sheet
///    INSIDE the task ([CreditsOut]): packs + 2 ads = 1 Normal answer; the
///    caller keeps the user's text and re-sends it once after a purchase;
///  * Probashi / Safe Family plans -> their own plan screens.
///
/// NEVER on SOS, Emergency, Safe Journey core, Family Care core, Care Call
/// free schedules, blood donor or Quran: test/buy_inside_guard_test.dart
/// fences those files, and fails when a feature listed here has no entry.
enum Unlock { credits, premium, business, cctv, probashi, safe }

class PaidFeature {
  final String key;
  final Unlock unlock;
  final IconData icon;

  /// app/lib file (relative to lib/) that holds this feature's buy entry
  /// (`BuyInside.open/handle` with [key], an [UpgradeSheet] / [CreditsOut]
  /// call). The guard test reads it.
  final String entry;
  const PaidFeature(this.key, this.unlock, this.icon, this.entry);

  String get plan => switch (unlock) {
        Unlock.premium => 'premium',
        Unlock.business => 'business',
        Unlock.cctv => 'cctv',
        Unlock.probashi => 'probashi',
        Unlock.safe => 'safe_family',
        Unlock.credits => 'credits',
      };
}

/// EVERY feature that a plan or credits unlock (owner_actions/
/// PAID_FEATURES_BUY_BUTTONS_BN.md is the same list in Bangla). Keys equal
/// the backend's gate / feature keys (core/logic/paid_gates.py).
const kPaidFeatures = <String, PaidFeature>{
  // ---- Premium (CRM, ledger AI, calls, decor, storage, ad-free)
  'crm_write': PaidFeature('crm_write', Unlock.premium, Icons.view_kanban_rounded,
      'screens/crm/crm_lead_form_screen.dart'),
  'crm_contacts': PaidFeature('crm_contacts', Unlock.premium, Icons.contacts_rounded,
      'screens/crm/crm_contacts_tab.dart'),
  'crm_followup_reminders': PaidFeature('crm_followup_reminders', Unlock.premium,
      Icons.alarm_rounded, 'screens/crm/crm_lead_detail_screen.dart'),
  'shop_quote': PaidFeature('shop_quote', Unlock.premium, Icons.request_quote_rounded,
      'screens/crm/shop_quote_screens.dart'),
  'ledger_ai_addons': PaidFeature('ledger_ai_addons', Unlock.premium,
      Icons.menu_book_rounded, 'widgets/business_extras.dart'),
  'video_call': PaidFeature('video_call', Unlock.premium, Icons.videocam_rounded,
      'screens/circle_call_screen.dart'),
  'call_link': PaidFeature('call_link', Unlock.premium, Icons.link_rounded,
      'screens/circle_chat_screen.dart'),
  'chat_themes': PaidFeature('chat_themes', Unlock.premium, Icons.palette_rounded,
      'screens/circle_chat_screen.dart'),
  'ad_free': PaidFeature('ad_free', Unlock.premium, Icons.block_rounded,
      'ads/sponsor_widgets.dart'),
  'storage': PaidFeature('storage', Unlock.premium, Icons.cloud_rounded,
      'widgets/storage_meter.dart'),
  'photo_ultra_hd': PaidFeature('photo_ultra_hd', Unlock.premium,
      Icons.high_quality_rounded, 'photo_studio/ps_gate_sheet.dart'),
  // ---- Business (AI sales agent, automation, reports, booking, marketing)
  'automation': PaidFeature('automation', Unlock.business, Icons.bolt_rounded,
      'screens/crm/crm_automation_screen.dart'),
  'ai_sales_agent': PaidFeature('ai_sales_agent', Unlock.business,
      Icons.support_agent_rounded, 'screens/business/bizagent/seller_agent_screen.dart'),
  'business_ai_reply': PaidFeature('business_ai_reply', Unlock.business,
      Icons.smart_toy_rounded, 'screens/business/ai_assistant_screen.dart'),
  'reports': PaidFeature('reports', Unlock.business, Icons.bar_chart_rounded,
      'screens/business/reports_screen.dart'),
  'booking_bot': PaidFeature('booking_bot', Unlock.business,
      Icons.event_available_rounded, 'screens/booking/booking_setup_screen.dart'),
  'mkt_followup': PaidFeature('mkt_followup', Unlock.business, Icons.campaign_rounded,
      'screens/mktengine/mkt_engine_screen.dart'),
  'shop_cctv_site': PaidFeature('shop_cctv_site', Unlock.business,
      Icons.storefront_rounded, 'screens/watchman/watchman_setup.dart'),
  // ---- CCTV plan (Play subscription, 7-day free trial)
  'cctv': PaidFeature('cctv', Unlock.cctv, Icons.videocam_rounded,
      'screens/watchman/watchman_screen.dart'),
  'cctv_camera_cap': PaidFeature('cctv_camera_cap', Unlock.cctv,
      Icons.add_a_photo_rounded, 'screens/watchman/watchman_add_camera.dart'),
  'cctv_phonecam': PaidFeature('cctv_phonecam', Unlock.cctv, Icons.phone_android_rounded,
      'screens/watchman/watchman_add_camera.dart'),
  'cctv_relay': PaidFeature('cctv_relay', Unlock.cctv, Icons.live_tv_rounded,
      'cctvguard/vendor_live_screen.dart'),
  // ---- Probashi / Safe Family plans
  'probashi': PaidFeature('probashi', Unlock.probashi, Icons.flight_rounded,
      'screens/probashi/probashi_plan_screen.dart'),
  'carecall_extra': PaidFeature('carecall_extra', Unlock.safe, Icons.alarm_add_rounded,
      'carecall/carecall_new_screen.dart'),
  // ---- AI credits (the credits sheet inside the task)
  'ai_chat': PaidFeature('ai_chat', Unlock.credits, Icons.chat_rounded,
      'screens/ai_chat_screen.dart'),
  'chat_photo': PaidFeature('chat_photo', Unlock.credits, Icons.photo_camera_rounded,
      'chat_vision/chat_photo.dart'),
  'photo_studio': PaidFeature('photo_studio', Unlock.credits, Icons.auto_fix_high_rounded,
      'photo_studio/ps_gate_sheet.dart'),
  'world': PaidFeature('world', Unlock.credits, Icons.public_rounded,
      'screens/world/world_ask_screen.dart'),
  'jobs': PaidFeature('jobs', Unlock.credits, Icons.work_rounded,
      'widgets/jobs_detail.dart'),
  'circle_assisto': PaidFeature('circle_assisto', Unlock.credits, Icons.forum_rounded,
      'p3/assisto_sheet.dart'),
  'agent_core': PaidFeature('agent_core', Unlock.credits, Icons.auto_awesome_rounded,
      'screens/agent_core/agent_run_panel.dart'),
  'vehicle': PaidFeature('vehicle', Unlock.credits, Icons.directions_car_rounded,
      'screens/vehicle_tracker_screen.dart'),
  'voice_input': PaidFeature('voice_input', Unlock.credits, Icons.mic_rounded,
      'widgets/voice_input.dart'),
  'day_planner': PaidFeature('day_planner', Unlock.credits, Icons.event_note_rounded,
      'screens/day_planner_screen.dart'),
  'ielts': PaidFeature('ielts', Unlock.credits, Icons.school_rounded,
      'screens/ielts_screen.dart'),
  'learn_roleplay': PaidFeature('learn_roleplay', Unlock.credits,
      Icons.record_voice_over_rounded, 'screens/language_pack_screen.dart'),
  'crm_proposal': PaidFeature('crm_proposal', Unlock.credits, Icons.description_rounded,
      'screens/crm/crm_proposal_screen.dart'),
  'bizai_winback': PaidFeature('bizai_winback', Unlock.credits, Icons.replay_rounded,
      'bizai/winback_screen.dart'),
  'bizagent_send': PaidFeature('bizagent_send', Unlock.credits, Icons.send_rounded,
      'screens/business/bizagent/seller_agent_screen.dart'),
  'cctv_extra_pack': PaidFeature('cctv_extra_pack', Unlock.credits, Icons.add_chart_rounded,
      'cctvguard/cctv_cap_section.dart'),
  'cctv_video_addon': PaidFeature('cctv_video_addon', Unlock.credits,
      Icons.video_library_rounded, 'screens/watchman/cctv_recording_screen.dart'),
};

/// Where the current purchase started (sent as `origin` with precheck /
/// verify / checkout / trial start; counted without personal data).
class BuyOrigin {
  BuyOrigin._();
  static String current = '';
}

class BuyInside {
  BuyInside._();

  /// Tests: replace the routing (key -> unlocked?).
  static Future<bool> Function(BuildContext context, String key)? debugOpen;

  /// Open the in-place buy screen of [key]. True when the feature is now
  /// unlocked (bought, trial started, credits landed) — the caller reloads
  /// or re-sends the kept request ONCE.
  static Future<bool> open(BuildContext context, String key,
      {bool draftKept = false, UpgradeReason? reason, int need = 0}) async {
    BuyOrigin.current = key;
    final d = debugOpen;
    if (d != null) return d(context, key);
    final f = kPaidFeatures[key];
    final unlock = f?.unlock ??
        (reason != null
            ? (reason.neededPlan == 'premium' ? Unlock.premium : Unlock.business)
            : Unlock.credits);
    switch (unlock) {
      case Unlock.credits:
        return CreditsOut.offer(context,
            screen: key, draftKept: draftKept, need: need);
      case Unlock.premium:
      case Unlock.business:
        final r = reason ??
            UpgradeReason(
                feature: key,
                neededPlan: unlock == Unlock.premium ? 'premium' : 'business');
        return (await UpgradeSheet.show(context, r)) == true;
      case Unlock.cctv:
        return (await CctvLockedSheet.show(context, featureKey: key)) == true;
      case Unlock.probashi:
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ProbashiPlanScreen()));
        return false;
      case Unlock.safe:
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SafePlansScreen()));
        return false;
    }
  }

  /// If [e] is a server refusal for money (out of credits / plan needed),
  /// open the right buy screen for [key] and return true (handled). The
  /// caller never clears what the user typed.
  static Future<bool> handle(BuildContext context, Object e, String key,
      {bool draftKept = true, void Function(bool unlocked)? then}) async {
    final up = UpgradeReason.fromError(e);
    final credits = isOutOfCredits(e);
    final plan = e is ApiException &&
        (((e.status == 402 || e.status == 403) &&
                (_planReasons.contains(e.reason) ||
                    _planReasons.contains('${e.body?['error'] ?? ''}'))) ||
            (e.status == 402 && e.body?['upgrade_required'] == true) ||
            (e.status == 413 && e.body?['error'] == 'storage_full'));
    if (up == null && !credits && !plan) return false;
    final ok = await open(context, key,
        draftKept: draftKept, reason: up, need: _need(e));
    then?.call(ok);
    return true;
  }

  static const _planReasons = {
    'plan_required',
    'premium_required',
    'business_required',
    'upgrade_required',
    'paid_only',
    'camera_cap',
    'cctv_plan_required',
    'storage_full',
  };

  static int _need(Object e) {
    if (e is ApiException) {
      final n = e.body?['need'];
      if (n is num) return n.toInt();
    }
    return 0;
  }
}

/// Feature name of a paid feature for the buy screen title (null = the
/// sheet's own reason text).
String? paidFeatureName(AppLocalizations t, String key) => switch (key) {
      'video_call' => t.biFeatVideoCall,
      'call_link' => t.biFeatCallLink,
      'chat_themes' => t.biFeatChatThemes,
      'ad_free' => t.biFeatAdFree,
      'storage' => t.biFeatStorage,
      'photo_ultra_hd' => t.biFeatPhotoUltra,
      'business_ai_reply' => t.biFeatBizAiReply,
      'mkt_followup' => t.biFeatMktFollowup,
      'shop_cctv_site' => t.biFeatShopCctv,
      'shop_quote' => t.biFeatShopQuote,
      _ => null,
    };
