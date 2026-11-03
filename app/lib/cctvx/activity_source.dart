// cctvactivity (W10) — every server call of the CCTV ACTIVITY screens behind
// one seam so widget tests / the screenshot gallery inject a fake. Shapes
// mirror backend/core/cctv_activity.py.
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api.dart';

abstract class ActivitySource {
  /// GET shop/sites/<id>/activity?date= — the day (visitors next to sales,
  /// open/close, watchman, health, summary lines; settings for the owner).
  Future<Map<String, dynamic>> day(int siteId, {String? date});

  /// PUT shop/sites/<id>/activity/settings.
  Future<Map<String, dynamic>> saveSettings(int siteId, Map<String, dynamic> body);

  /// POST shop/sites/<id>/activity/confirm — {date, open, close}.
  Future<Map<String, dynamic>> confirm(int siteId, String date, {String? open, String? close});

  /// GET shop/sites/<id>/visitors — search by words + time.
  Future<Map<String, dynamic>> visitors(int siteId,
      {String? date, int days = 1, String q = '', String? from, String? to});

  /// GET shop/sites/<id>/timelapse — the day's stored photo links + plan.
  Future<Map<String, dynamic>> timelapse(int siteId, {String? date, int? cameraId});

  /// One stored photo from its link (no auth header — signed / media link).
  Future<Uint8List> download(String url);
}

String _qs(Map<String, String?> m) {
  final parts = <String>[
    for (final e in m.entries)
      if (e.value != null && e.value!.isNotEmpty)
        '${e.key}=${Uri.encodeQueryComponent(e.value!)}'
  ];
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

class ApiActivitySource implements ActivitySource {
  final ApiClient api;
  ApiActivitySource(this.api);

  static const _maxBytes = 3 * 1024 * 1024;

  @override
  Future<Map<String, dynamic>> day(int siteId, {String? date}) =>
      api.getJson('/shop/sites/$siteId/activity${_qs({'date': date})}');

  @override
  Future<Map<String, dynamic>> saveSettings(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/activity/settings', body);

  @override
  Future<Map<String, dynamic>> confirm(int siteId, String date, {String? open, String? close}) =>
      api.postJson('/shop/sites/$siteId/activity/confirm', {
        'date': date,
        if (open != null) 'open': open,
        if (close != null) 'close': close,
      });

  @override
  Future<Map<String, dynamic>> visitors(int siteId,
          {String? date, int days = 1, String q = '', String? from, String? to}) =>
      api.getJson('/shop/sites/$siteId/visitors${_qs({
            'date': date,
            'days': '$days',
            'q': q.trim(),
            'from': from,
            'to': to,
          })}');

  @override
  Future<Map<String, dynamic>> timelapse(int siteId, {String? date, int? cameraId}) =>
      api.getJson('/shop/sites/$siteId/timelapse${_qs({
            'date': date,
            'camera': cameraId?.toString(),
          })}');

  @override
  Future<Uint8List> download(String url) async {
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw ApiException('Error ${r.statusCode}', r.statusCode);
    if (r.bodyBytes.length > _maxBytes) throw ApiException('Error 413', 413);
    return r.bodyBytes;
  }
}
