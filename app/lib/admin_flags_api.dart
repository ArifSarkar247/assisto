import 'api.dart';

/// COST KILL-SWITCH & FEATURE-FLAGS — client surface for the owner/superuser
/// admin console (#178, SPEC v2.1 §21, ADVANCED).
///
/// Implemented as an EXTENSION on [ApiClient] built ONLY on its public
/// [ApiClient.getJson] / [ApiClient.postJson] helpers, so this ships WITHOUT
/// editing the shared api.dart. Paths match the integration doc (`api/v1/`
/// prefix is applied by [AppConfig.api]; no trailing slash).
///
/// Server is the authority: the backend (`core.logic.admin_flags`) re-validates
/// every flip and re-decides the confirm requirement. The Dart mirror
/// ([FlagCatalog]) only *predicts* the confirm gate so the dialog fires for the
/// same flips — the result the server returns always wins.
///
/// Owner/superuser gating: the endpoints return HTTP 403 for non-owners;
/// [getJson]/[postJson] surface that as an [ApiException] with `status == 403`,
/// which the screen renders as a dedicated "owner only" state. The entry point
/// is additionally pre-gated with [adminFlagsCanManage] so non-owners never see
/// the link.
extension AdminFlagsApi on ApiClient {
  /// GET /admin/flags -> {flags:[{id,kind,group,value,default,is_cost}],
  ///                      audit:[{flag,kind,old,new,actor,reason,at,confirm_code}],
  ///                      summary:{cost_on,cost_total,features_off,features_total,total}}
  Future<Map<String, dynamic>> adminFlags() => getJson('/admin/flags');

  /// POST /admin/flags/flip {flag, value, reason?} -> the same shape as
  /// [adminFlags] (fresh snapshot incl. the new audit row). The backend rejects
  /// a blank reason where its confirm gate requires one (HTTP 400 with a
  /// problems list), and a 403 for non-owners.
  Future<Map<String, dynamic>> adminFlipFlag(
          String flag, bool value, String reason) =>
      postJson('/admin/flags/flip',
          {'flag': flag, 'value': value, 'reason': reason});

  /// Role probe: true iff the current user may manage flags. Fail-closed — any
  /// error (403 / offline / unexpected) resolves to false so non-owners never
  /// see the entry point.
  Future<bool> adminFlagsCanManage() async {
    try {
      final r = await getJson('/admin/flags?probe=1');
      if (r['can_manage'] is bool) return r['can_manage'] as bool;
      return true;
    } on ApiException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// On-device mirror of the backend flag catalog (`core.logic.admin_flags`).
/// DETERMINISTIC and in lock-step with the Python catalog so the confirm gate
/// fires for the exact same flips offline / before the round-trip. The screen
/// never invents flags — it renders whatever the server returns; this catalog
/// only classifies (kind / confirm requirement) and maps ids to localized
/// labels + group headers (labels resolved via AppLocalizations; zero Bangla
/// in source).
class FlagCatalog {
  FlagCatalog._();

  static const kindCost = 'cost';
  static const kindFeature = 'feature';

  /// Whether flipping [flagId] to [newValue] needs a typed-reason confirm.
  /// Mirrors `admin_flags.needs_confirm`: cost flags ALWAYS (both ways),
  /// feature flags only when turning OFF.
  static bool needsConfirm(String kind, bool newValue) {
    if (kind == kindCost) return true;
    return newValue == false; // feature: confirm on disable
  }

  /// Stable reason code -> localized confirm copy. Mirrors
  /// `admin_flags.confirm_reason_code`.
  static String confirmCode(String kind, bool newValue) {
    if (!needsConfirm(kind, newValue)) return '';
    if (kind == kindCost) return newValue ? 'enable_cost' : 'disable_cost';
    return 'disable_feature';
  }
}
