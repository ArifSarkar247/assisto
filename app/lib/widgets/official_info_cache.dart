// p3guides: offline-first loader for GET /official-info/<section>.
// The payload (official helplines, welfare, remittance benchmarks, education
// links — each with a last-checked date) is cached per section + language so
// Probashi / Student corners stay readable with no network (e.g. abroad with
// no data). Content is server-localised; no copy lives here.
import 'dart:convert';

import '../api.dart';
import '../state.dart' show Settings;

class OfficialInfoResult {
  final Map<String, dynamic>? data;
  final bool fromCache; // true = served from the phone (no fresh fetch)
  final Object? error; // the fetch error when there was no cache either
  const OfficialInfoResult(this.data, this.fromCache, this.error);
}

String officialInfoCacheKey(String section, String lang) =>
    'official_info_v1_${section}_$lang';

Future<OfficialInfoResult> loadOfficialInfo(
    ApiClient api, String section, String lang) async {
  final key = officialInfoCacheKey(section, lang);
  try {
    final d = await api.officialInfo(section);
    await Settings.setString(key, jsonEncode(d));
    return OfficialInfoResult(d, false, null);
  } catch (e) {
    final raw = await Settings.getString(key);
    if (raw != null && raw.isNotEmpty) {
      try {
        return OfficialInfoResult(
            jsonDecode(raw) as Map<String, dynamic>, true, null);
      } catch (_) {}
    }
    return OfficialInfoResult(null, false, e);
  }
}

/// Labelled links from the payload (`[{label, url}]`).
List<({String label, String url})> officialLinks(dynamic v) => [
      for (final m in (v is List ? v : const []).whereType<Map>())
        (label: '${m['label'] ?? ''}', url: '${m['url'] ?? ''}')
    ];
