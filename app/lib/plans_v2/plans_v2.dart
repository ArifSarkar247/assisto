import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../widgets/ladder_common.dart' show fmtInt;

/// plans-v2 — the app's view of the server's plan matrix (owner order 27
/// Oct). The SERVER enforces every limit (core/entitlements_service.py,
/// crm/plan_gate.py); the app only reads `GET /plans/v2` to lock buttons
/// honestly and show usage like "18/20 contacts". With the plans_v2 flag
/// OFF the server answers `on: false` and every screen behaves as before.

/// Why a locked action asked to upgrade (from the server's structured 402
/// `upgrade_required` body, or built locally from /plans/v2 before a tap).
class UpgradeReason {
  /// crm_contacts | crm_write | crm_followup_reminders | automation |
  /// ai_sales_agent | booking_bot | reports | ledger_ai_addons
  final String feature;

  /// premium | business — the cheapest plan that unlocks it.
  final String neededPlan;
  final int? limit;
  final int? used;

  /// The server's own localized line (fallback when a feature is unknown).
  final String serverMessage;

  const UpgradeReason({
    required this.feature,
    required this.neededPlan,
    this.limit,
    this.used,
    this.serverMessage = '',
  });

  static int? _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  static UpgradeReason? fromBody(Map<String, dynamic>? b) {
    if (b == null) return null;
    if (b['error'] != 'upgrade_required' || b['feature'] == null) return null;
    final need = '${b['needed_plan'] ?? b['plan_required'] ?? 'business'}';
    return UpgradeReason(
      feature: '${b['feature']}',
      neededPlan: need == 'premium' ? 'premium' : 'business',
      limit: _i(b['limit']),
      used: _i(b['used']),
      serverMessage: '${b['detail'] ?? ''}',
    );
  }

  /// A server refusal -> the reason, or null for any other error.
  static UpgradeReason? fromError(Object e) {
    if (e is! ApiException || e.status != 402) return null;
    return fromBody(e.body);
  }
}

/// CRM contact usage of the org owner's plan.
class ContactUsage {
  final int used, limit;
  final bool unlimited, canAdd;
  const ContactUsage(
      {required this.used,
      required this.limit,
      required this.unlimited,
      required this.canAdd});

  factory ContactUsage.fromJson(Map<String, dynamic> j) => ContactUsage(
        used: UpgradeReason._i(j['used']) ?? 0,
        limit: UpgradeReason._i(j['limit']) ?? 0,
        unlimited: j['unlimited'] == true,
        canAdd: j['can_add'] != false,
      );
}

/// GET /plans/v2 — tier, trial, caps (+ the CRM org owner's caps/usage).
class PlansV2State {
  final bool on;
  final String tier;
  final bool trialActive, trialAvailable;
  final DateTime? trialUntil;
  final int trialDays;
  final String trialPlan;
  final Map<String, bool> caps;
  final Map<String, String> needed;

  /// The live matrix {free|premium|business: {crm_contacts, crm_write, ...}}.
  final Map<String, dynamic> matrix;

  /// The CRM org being viewed (owner's plan decides), when ?org= was given.
  final Map<String, bool> crmCaps;
  final ContactUsage? contacts;

  /// The CRM org OWNER's tier (their plan decides the CRM, not the viewer's).
  final String? crmOwnerTier;

  /// billapp: the caller's OWN CRM contact usage (when they own a CRM org),
  /// for the Plan screen's usage meter.
  final ContactUsage? ownContacts;

  const PlansV2State({
    this.on = false,
    this.tier = 'free',
    this.trialActive = false,
    this.trialAvailable = false,
    this.trialUntil,
    this.trialDays = 0,
    this.trialPlan = 'business',
    this.caps = const {},
    this.needed = const {},
    this.matrix = const {},
    this.crmCaps = const {},
    this.contacts,
    this.crmOwnerTier,
    this.ownContacts,
  });

  /// Flag off / not loaded: nothing locked by the app (server still decides).
  static const off = PlansV2State();

  static Map<String, bool> _caps(Object? m) => {
        if (m is Map)
          for (final e in m.entries) '${e.key}': e.value == true,
      };

  factory PlansV2State.fromJson(Map<String, dynamic> j) {
    final crm = (j['crm'] as Map?)?.cast<String, dynamic>();
    return PlansV2State(
      on: j['on'] == true,
      tier: '${j['tier'] ?? 'free'}',
      trialActive: j['trial_active'] == true,
      trialAvailable: j['trial_available'] == true,
      trialUntil: DateTime.tryParse('${j['trial_until'] ?? ''}')?.toLocal(),
      trialDays: UpgradeReason._i(j['trial_days']) ?? 0,
      trialPlan: '${j['trial_plan'] ?? 'business'}',
      caps: _caps(j['caps']),
      needed: {
        if (j['needed'] is Map)
          for (final e in (j['needed'] as Map).entries)
            '${e.key}': '${e.value ?? 'business'}',
      },
      matrix: (j['matrix'] as Map?)?.cast<String, dynamic>() ?? const {},
      crmCaps: _caps(crm?['caps']),
      crmOwnerTier: crm?['owner_tier'] == null ? null : '${crm!['owner_tier']}',
      contacts: crm?['contacts'] is Map
          ? ContactUsage.fromJson((crm!['contacts'] as Map).cast<String, dynamic>())
          : null,
      ownContacts: j['own_crm_contacts'] is Map
          ? ContactUsage.fromJson(
              (j['own_crm_contacts'] as Map).cast<String, dynamic>())
          : null,
    );
  }

  /// May the CRM org do [cap]? Always true while plans-v2 is off.
  bool crmAllows(String cap) => !on || (crmCaps[cap] ?? true);

  /// May this account do [cap]? Always true while plans-v2 is off.
  bool allows(String cap) => !on || (caps[cap] ?? true);

  String neededFor(String cap) =>
      needed[cap] ?? (cap == 'crm_write' || cap == 'crm_followup_reminders'
          ? 'premium'
          : 'business');

  /// The locked reason for [cap] in the CRM (null = allowed).
  UpgradeReason? crmLock(String cap) => crmAllows(cap)
      ? null
      : UpgradeReason(feature: cap, neededPlan: neededFor(cap));

  /// The contact-limit reason when no room is left (null = room left).
  UpgradeReason? contactLock() {
    final c = contacts;
    if (!on || c == null || c.canAdd) return null;
    return UpgradeReason(
        feature: 'crm_contacts',
        neededPlan: (crmOwnerTier ?? tier) == 'free' ? 'premium' : 'business',
        limit: c.limit,
        used: c.used);
  }
}

/// Loads /plans/v2; any failure = [PlansV2State.off] (never blocks a screen).
Future<PlansV2State> loadPlansV2(ApiClient api, {int? org}) async {
  try {
    final q = org != null ? '?org=$org' : '';
    return PlansV2State.fromJson(await api.getJson('/plans/v2$q'));
  } catch (_) {
    return PlansV2State.off;
  }
}

/// "18/20 contacts" (Bangla digits in the Bangla UI) or "Unlimited contacts".
String contactUsageText(BuildContext context, ContactUsage u) {
  final t = AppLocalizations.of(context);
  if (u.unlimited) return t.pv2UsageContactsUnlimited(fmtInt(context, u.used));
  return t.pv2UsageContacts(fmtInt(context, u.used), fmtInt(context, u.limit));
}

/// The plan's display name.
String planName(AppLocalizations t, String plan) =>
    plan == 'premium' ? t.pv2PlanPremium : (plan == 'free' ? t.pv2PlanFree : t.pv2PlanBusiness);

/// A trial end date with the year, e.g. "Nov 3, 2026" / Bangla digits in bn.
String trialDate(BuildContext context, DateTime d) {
  final loc = Localizations.localeOf(context).languageCode;
  try {
    return DateFormat.yMMMd(loc).format(d);
  } catch (_) {
    return DateFormat.yMMMd('en').format(d);
  }
}
