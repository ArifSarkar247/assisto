import '../api.dart';

/// Phase-B module API surface for Scam + Safety + Vault-renewal.
///
/// Implemented as an EXTENSION on ApiClient (built only on its public methods:
/// getJson / getBytes / scamCheck / createItem) so this module ships without
/// editing the shared api.dart. The integrator SHOULD later move these into
/// ApiClient proper (see "api.dart methods" in the module report) — the
/// signatures and paths below are authoritative.
extension ScamSafetyApi on ApiClient {
  // ---- scam ----

  /// Rich scam detection. Delegates to the existing POST /scam/check, which the
  /// integrator wires to core.logic.scam.check_message — returning the NEW
  /// contract {score, verdict, level, label, emoji, patterns[], advice, summary}.
  Future<Map<String, dynamic>> scamDetect(String message) => scamCheck(message);

  /// The curated scam-pattern library for the "learn the scams" tab.
  /// GET /scam/library -> {patterns:[{key,level,name,why,do}]}  (localised).
  Future<List<Map<String, dynamic>>> scamLibrary() async {
    final r = await getJson('/scam/library');
    return ((r['patterns'] ?? r['library'] ?? []) as List)
        .cast<Map<String, dynamic>>();
  }

  /// Report a scam message to the family (foreground poll today; push when
  /// Firebase is added). POST /scam/report {message}.
  Future<void> scamReportFamily(String message) =>
      createItem('scam/report', {'message': message});

  // ---- govt guides (for vault renewal steps) ----

  /// Flattened, localised govt-service guides list (see core/logic/guides.py
  /// localized()): [{key, name, portal, steps:[...]}, ...].
  /// GET /guides -> the integrator returns guides.localized(lang)['services'].
  Future<List<Map<String, dynamic>>> govtGuides() async {
    final r = await getJson('/guides');
    final services = r['services'] ?? r['guides'] ?? [];
    return (services as List).cast<Map<String, dynamic>>();
  }

  // ---- safety: safe-arrival check-in ----

  /// Start a safe-arrival check-in so the family poll can detect overdue
  /// arrivals. POST /safety/checkin {place, eta} (eta ISO-8601).
  Future<void> safetyCheckinStart({String? place, required String etaIso}) =>
      createItem('safety/checkin', {'place': place ?? '', 'eta': etaIso});

  /// Mark the active check-in as arrived (clears the pending alert).
  /// POST /safety/checkin/arrived {}.
  Future<void> safetyCheckinArrived() =>
      createItem('safety/checkin/arrived', const {});
}
