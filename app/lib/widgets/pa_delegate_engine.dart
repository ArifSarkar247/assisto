import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device mirror of `backend/core/logic/pa_delegate.py` (PA SECRETARY MODE
/// delegate access, #111, §14). Deterministic scope model: LEAST-PRIVILEGE
/// default, a confirm gate on sensitive grants, and an append-only local audit.
///
/// IMPORTANT — this mirror is a UI CONVENIENCE for offline preview + honest
/// labelling. The AUTHORITATIVE grant lives server-side (PADelegate.scopes) and
/// every delegate action is re-checked there via `can_access` against the
/// DB-stored scopes. A scope a client merely holds here grants the delegate
/// NOTHING on the server; a forged scope reads as NOT granted. Never treat the
/// local set as permission to expose data.

/// One scope = one capability the owner may delegate.
class PaScope {
  final String id;
  final bool sensitive; // granting exposes private info / acts with consequence
  final bool write; // lets the delegate DO (not just see)
  final String exposesKey; // ARB key: honest "this lets them…" copy
  const PaScope(this.id, this.sensitive, this.write, this.exposesKey);
}

// Single source of truth, ordered least-risky first — mirrors SCOPE_CATALOG.
const String scopeSeeSchedule = 'see_schedule';
const String scopeViewBriefs = 'view_briefs';
const String scopeSeeTasks = 'see_tasks';
const String scopeApproveVisitors = 'approve_visitors';
const String scopeSendFollowups = 'send_followups';
const String scopeManageTasks = 'manage_tasks';
const String scopeViewContacts = 'view_contacts';
const String scopeSeeMoney = 'see_money';
const String scopeSeeHealth = 'see_health';
const String scopeSeeDocuments = 'see_documents';

const List<PaScope> kScopeCatalog = [
  PaScope(scopeSeeSchedule, false, false, 'paScopeExposesSchedule'),
  PaScope(scopeViewBriefs, false, false, 'paScopeExposesBriefs'),
  PaScope(scopeSeeTasks, false, false, 'paScopeExposesTasks'),
  PaScope(scopeApproveVisitors, true, true, 'paScopeExposesVisitors'),
  PaScope(scopeSendFollowups, true, true, 'paScopeExposesFollowups'),
  PaScope(scopeManageTasks, true, true, 'paScopeExposesManageTasks'),
  PaScope(scopeViewContacts, true, false, 'paScopeExposesContacts'),
  PaScope(scopeSeeMoney, true, false, 'paScopeExposesMoney'),
  PaScope(scopeSeeHealth, true, false, 'paScopeExposesHealth'),
  PaScope(scopeSeeDocuments, true, false, 'paScopeExposesDocuments'),
];

final Map<String, PaScope> _byId = {for (final s in kScopeCatalog) s.id: s};

// Conservative least-privilege default: only low-risk read-only scopes.
const Set<String> kDefaultScopes = {
  scopeSeeSchedule,
  scopeViewBriefs,
  scopeSeeTasks,
};

bool isKnownScope(String id) => _byId.containsKey(id);
bool isSensitiveScope(String id) => _byId[id]?.sensitive ?? true; // fail-safe
PaScope? scopeMeta(String id) => _byId[id];

/// Fresh least-privilege default set each call.
Set<String> defaultScopes() => Set<String>.from(kDefaultScopes);

/// Drop anything outside the catalog (defence in depth).
Set<String> normalizeScopes(Iterable<String>? scopes) =>
    {for (final s in (scopes ?? const <String>[])) if (isKnownScope(s)) s};

/// Pure toggle; unknown scope is a no-op.
Set<String> setScope(Set<String> scopes, String id, bool on) {
  final out = normalizeScopes(scopes);
  if (!isKnownScope(id)) return out;
  if (on) {
    out.add(id);
  } else {
    out.remove(id);
  }
  return out;
}

/// Default-DENY local view (the server runs the real check).
bool canAccess(Set<String> stored, String id) =>
    isKnownScope(id) && normalizeScopes(stored).contains(id);

/// Sensitive grants must pass the confirm gate; revoking never does.
bool grantRequiresConfirm(String id) =>
    !isKnownScope(id) || isSensitiveScope(id);

// ---------------------------------------------------------------- audit

class PaAuditEntry {
  final String scope;
  final String action; // viewed / acted / granted / revoked / denied
  final String at; // ISO-8601
  final bool allowed;
  final bool sensitive;
  const PaAuditEntry({
    required this.scope,
    required this.action,
    required this.at,
    required this.allowed,
    required this.sensitive,
  });

  Map<String, dynamic> toJson() => {
        'scope': scope,
        'action': action,
        'at': at,
        'allowed': allowed,
        'sensitive': sensitive,
      };

  factory PaAuditEntry.fromJson(Map<String, dynamic> j) => PaAuditEntry(
        scope: (j['scope'] ?? 'unknown').toString(),
        action: (j['action'] ?? 'viewed').toString(),
        at: (j['at'] ?? '').toString(),
        allowed: j['allowed'] == true,
        sensitive: j['sensitive'] == true,
      );
}

PaAuditEntry buildAuditEntry({
  required String scope,
  required String action,
  required DateTime at,
  bool allowed = true,
}) =>
    PaAuditEntry(
      scope: isKnownScope(scope) ? scope : 'unknown',
      action: action,
      at: at.toIso8601String(),
      allowed: allowed,
      sensitive: isSensitiveScope(scope) && isKnownScope(scope),
    );

class AuditSummary {
  final int total;
  final int denied;
  final int sensitive;
  const AuditSummary(this.total, this.denied, this.sensitive);
}

AuditSummary summarizeAudit(List<PaAuditEntry> entries) {
  var denied = 0, sensitive = 0;
  for (final e in entries) {
    if (!e.allowed) denied++;
    if (e.sensitive) sensitive++;
  }
  return AuditSummary(entries.length, denied, sensitive);
}

// ---------------------------------------------------------------- store
// Local persistence of the owner's draft scope config + the audit trail. The
// server is still authoritative; this lets the screen open instantly offline.

class PaDelegateStore {
  static const _scopeKey = 'pa_delegate_scopes_v1';
  static const _auditKey = 'pa_delegate_audit_v1';

  static Future<Set<String>?> loadScopes() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_scopeKey);
    if (raw == null || raw.isEmpty) return null; // null ⇒ never configured
    final list = (jsonDecode(raw) as List).map((e) => e.toString());
    return normalizeScopes(list);
  }

  static Future<void> saveScopes(Set<String> scopes) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_scopeKey, jsonEncode(normalizeScopes(scopes).toList()));
  }

  static Future<List<PaAuditEntry>> loadAudit() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_auditKey);
    if (raw == null || raw.isEmpty) return [];
    return (jsonDecode(raw) as List)
        .map((e) => PaAuditEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> appendAudit(PaAuditEntry entry) async {
    final p = await SharedPreferences.getInstance();
    final list = await loadAudit();
    final capped = [entry, ...list].take(100).toList();
    await p.setString(
        _auditKey, jsonEncode(capped.map((e) => e.toJson()).toList()));
  }
}
