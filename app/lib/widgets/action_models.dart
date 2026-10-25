import 'package:flutter/material.dart';

import '../theme.dart';
import '../l10n/app_localizations.dart';

/// Action Center domain model + pure presentation helpers (SPEC v2.1 §21,
/// feature #9). Lives in a NEW file so it ships without touching the shared
/// core `models.dart`. ZERO Bangla literals — every user-facing string comes
/// from `AppLocalizations` getters (emitted to `.phaseB/up_action_arb.json`).

/// A single action the AI has PREPARED and is holding for the user's approval
/// (autonomy level 3 — "do it with approval"). Parsed from the NEW
/// `GET /actions/pending` endpoint; see `action_api.dart` / integration note.
class PendingAction {
  final int id;

  /// Dotted action key, same vocabulary as the audit log (e.g.
  /// `agent.reminder`, `message.send`, `autopay.pay`). Drives module + icon.
  final String action;

  /// Explicit module slug from the server when present (e.g. `reminders`,
  /// `messenger`, `money`); falls back to the first dotted segment of [action].
  final String module;

  /// Short human title ("Send reminder to Rahim").
  final String title;

  /// Optional longer summary / preview (e.g. the drafted message body).
  final String summary;

  /// Autonomy level under which this action was queued (1-4). Transparency:
  /// the card can say "queued because you're on level N".
  final int autonomyLevel;

  final DateTime createdAt;

  /// Full prepared payload — surfaced read-only in the detail sheet and used
  /// as the editable seed when the user taps Edit.
  final Map<String, dynamic> detail;

  PendingAction({
    required this.id,
    required this.action,
    required this.module,
    required this.title,
    required this.summary,
    required this.autonomyLevel,
    required this.createdAt,
    required this.detail,
  });

  factory PendingAction.fromJson(Map<String, dynamic> j) {
    final act = (j['action'] ?? '') as String;
    final mod = (j['module'] as String?)?.trim();
    return PendingAction(
      id: (j['id'] ?? 0) as int,
      action: act,
      module: (mod != null && mod.isNotEmpty) ? mod : moduleOf(act),
      title: (j['title'] ?? act) as String,
      summary: (j['summary'] ?? '') as String,
      autonomyLevel: (j['autonomy_level'] ?? 3) as int,
      createdAt: DateTime.tryParse((j['created_at'] ?? '') as String) ??
          DateTime.now(),
      detail: (j['detail'] ?? const <String, dynamic>{})
          as Map<String, dynamic>,
    );
  }
}

/// The module slug for an audit/action key: the segment before the first dot
/// (`agent.reminder` -> `agent`, `source.toggle` -> `source`). Used for the
/// module filter and icon mapping on both PENDING and DONE lists.
String moduleOf(String action) {
  final dot = action.indexOf('.');
  return dot < 0 ? action : action.substring(0, dot);
}

/// The sub-type (segment after the first dot) — e.g. `reminder`, `delete`.
/// Empty when the action has no dot. Powers the optional type filter.
String typeOf(String action) {
  final dot = action.indexOf('.');
  return dot < 0 ? '' : action.substring(dot + 1);
}

/// A stable icon per module so the log is scannable. Unknown modules get a
/// neutral bullet — never a crash.
IconData actionIcon(String module) {
  switch (module) {
    case 'agent':
      return Icons.smart_toy_rounded;
    case 'reminder':
    case 'reminders':
      return Icons.alarm_rounded;
    case 'message':
    case 'messenger':
    case 'circle':
      return Icons.send_rounded;
    case 'memory':
      return Icons.psychology_rounded;
    case 'money':
    case 'autopay':
    case 'ladder':
      return Icons.account_balance_wallet_rounded;
    case 'medicine':
    case 'prescription':
      return Icons.medication_rounded;
    case 'scam':
      return Icons.shield_rounded;
    case 'safety':
      return Icons.health_and_safety_rounded;
    case 'document':
    case 'export':
      return Icons.description_rounded;
    case 'nominee':
      return Icons.family_restroom_rounded;
    case 'job':
      return Icons.work_outline_rounded;
    case 'account':
    case 'profile':
      return Icons.person_outline_rounded;
    case 'integration':
      return Icons.hub_rounded;
    case 'source':
      return Icons.tune_rounded;
    default:
      return Icons.history_toggle_off_rounded;
  }
}

/// Outcome tint for a DONE entry. `*.delete` + `*.reject` read as destructive,
/// `*.undo` as neutral-restored; everything else is a completed success.
Color actionOutcomeColor(String action, ColorScheme cs) {
  final t = typeOf(action);
  if (t == 'delete' || t == 'reject' || action.endsWith('stop_all')) {
    return Brand.danger;
  }
  if (t == 'undo') return cs.onSurfaceVariant;
  return Brand.success;
}

/// A readable label for a module slug, localised. Falls back to the raw slug
/// (capitalised) for modules the ARB doesn't name yet — honest, never blank.
String moduleLabel(AppLocalizations t, String module) {
  final map = <String, String>{
    'agent': t.actionModuleAgent,
    'reminder': t.actionModuleReminders,
    'reminders': t.actionModuleReminders,
    'message': t.actionModuleMessages,
    'messenger': t.actionModuleMessages,
    'circle': t.actionModuleMessages,
    'memory': t.actionModuleMemory,
    'money': t.actionModuleMoney,
    'autopay': t.actionModuleMoney,
    'ladder': t.actionModuleMoney,
    'medicine': t.actionModuleHealth,
    'prescription': t.actionModuleHealth,
    'safety': t.actionModuleSafety,
    'scam': t.actionModuleSafety,
    'document': t.actionModuleDocuments,
    'export': t.actionModuleDocuments,
    'nominee': t.actionModuleNominee,
    'job': t.actionModuleJobs,
    'account': t.actionModuleAccount,
    'profile': t.actionModuleAccount,
    'source': t.actionModuleAccount,
    'integration': t.actionModuleIntegrations,
  };
  final hit = map[module];
  if (hit != null) return hit;
  if (module.isEmpty) return t.actionModuleOther;
  return module[0].toUpperCase() + module.substring(1);
}

/// Human label for a full audit action key. Prefers a localised phrase for the
/// common verbs we know, otherwise shows "<Module>: <type>" so the raw record
/// stays legible (transparency) even for brand-new action strings.
String actionLabel(AppLocalizations t, String action) {
  final verb = <String, String>{
    'agent.reminder': t.actionLabelReminderSet,
    'agent.memory': t.actionLabelMemorySaved,
    'agent.medicine': t.actionLabelMedicineLogged,
    'agent.loan': t.actionLabelLoanLogged,
    'memory.create': t.actionLabelMemorySaved,
    'memory.update': t.actionLabelMemoryUpdated,
    'memory.delete': t.actionLabelMemoryDeleted,
    'medicine.taken': t.actionLabelMedicineTaken,
    'scam.check': t.actionLabelScamChecked,
    'scam.report': t.actionLabelScamReported,
    'export.pdf': t.actionLabelExported,
    'export.excel': t.actionLabelExported,
    'export.doctor_pdf': t.actionLabelExported,
    'document.create': t.actionLabelDocSaved,
    'document.delete': t.actionLabelDocDeleted,
    'safety.checkin.start': t.actionLabelCheckinStart,
    'safety.checkin.arrived': t.actionLabelCheckinArrived,
    'profile.update': t.actionLabelProfileUpdated,
    'source.toggle': t.actionLabelSourceToggled,
  }[action];
  if (verb != null) return verb;
  final type = typeOf(action);
  if (type.isEmpty) return moduleLabel(t, action);
  return '${moduleLabel(t, moduleOf(action))}: $type';
}

/// Short autonomy-level name for the "queued because you're on level N" chip.
String autonomyShort(AppLocalizations t, int level) {
  switch (level) {
    case 1:
      return t.autonomyRemindOnlyTitle;
    case 2:
      return t.autonomySuggestTitle;
    case 3:
      return t.autonomyApproveTitle;
    case 4:
      return t.autonomyAutoTitle;
    default:
      return t.autonomySuggestTitle;
  }
}
