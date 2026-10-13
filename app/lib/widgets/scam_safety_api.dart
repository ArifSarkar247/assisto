import 'dart:convert';
import 'package:http/http.dart' as http;
import '../api.dart';
import '../config.dart';

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

  // ---- documents (send structured fields as a real map, not packed note) ----

  /// Create a document whose type-specific fields travel as a dedicated
  /// `details` MAP (JSON object) alongside the free-text `note` — NEVER packed
  /// into a single delimited string. POST /documents/ {title, doc_type,
  /// expiry_date?, details{}, note}. The integrator adds Document.details
  /// (JSONField) + a serializer 'details' field (see MIGRATION NOTE).
  Future<void> createDocumentWithDetails({
    required String title,
    required String docType,
    String? expiryDate,
    Map<String, String> details = const {},
    String note = '',
  }) =>
      createItem('documents', {
        'title': title,
        'doc_type': docType,
        if (expiryDate != null && expiryDate.isNotEmpty) 'expiry_date': expiryDate,
        'details': details,
        'note': note,
      });

  /// Same as [createDocumentWithDetails] but with an attached image file.
  /// Multipart can't nest a JSON object, so `details` rides as a single
  /// JSON-encoded string field the serializer decodes — the values themselves
  /// stay intact (no ';', '|', '=' corruption). Built from the public `token`
  /// + AppConfig.api so the shared api.dart is untouched.
  Future<void> uploadDocumentWithDetails({
    required String title,
    required String docType,
    String? expiryDate,
    Map<String, String> details = const {},
    String note = '',
    required String filePath,
  }) async {
    final req = http.MultipartRequest('POST', AppConfig.api('/documents/'));
    if (token != null) req.headers['Authorization'] = 'Token $token';
    req.fields['title'] = title;
    req.fields['doc_type'] = docType;
    if (expiryDate != null && expiryDate.isNotEmpty) {
      req.fields['expiry_date'] = expiryDate;
    }
    // JSON-encoded object; serializer decodes 'details' into the JSONField.
    req.fields['details'] = jsonEncode(details);
    if (note.isNotEmpty) req.fields['note'] = note;
    req.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await req.send();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw ApiException(
          'Document upload failed (${streamed.statusCode})', streamed.statusCode);
    }
  }
}
