import 'package:flutter/widgets.dart';

import '../../api.dart';

/// cctvteam (W11) — every server call of the multi-site grid, roles, share
/// links, access log and private neighbourhood watch, behind one seam so
/// widget tests / the screenshot gallery inject a fake. Shapes mirror
/// backend/core/cctv_team_views.py.
abstract class CctvTeamSource {
  Future<Map<String, dynamic>> grid();
  Future<Map<String, dynamic>> still(int cameraId, {bool fresh = false});
  Future<Map<String, dynamic>> roles(int siteId);
  Future<Map<String, dynamic>> setRole(int siteId, int userId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> accessLog(int siteId);
  Future<Map<String, dynamic>> shareLinks(int siteId);
  Future<Map<String, dynamic>> createShareLink(int siteId, Map<String, dynamic> body);
  Future<Map<String, dynamic>> revokeShareLink(int linkId);
  Future<Map<String, dynamic>> watchGroups();
  Future<Map<String, dynamic>> watchPosts(int groupId);
  Future<Map<String, dynamic>> watchShare(Map<String, dynamic> body);
  Future<void> watchDelete(int postId);
  Future<Map<String, dynamic>> watchReport(int postId, String reason, {bool block = false});
  Future<void> watchBlock(int userId);

  /// How a still / post photo is loaded (fakes return a memory image).
  /// Decoded small: a 2 GB phone never holds full-size frames for a grid.
  ImageProvider image(String url, {int width = 360}) =>
      ResizeImage(NetworkImage(url), width: width, policy: ResizeImagePolicy.fit);
}

class ApiCctvTeamSource extends CctvTeamSource {
  final ApiClient api;
  ApiCctvTeamSource(this.api);

  @override
  Future<Map<String, dynamic>> grid() => api.getJson('/shop/grid');
  @override
  Future<Map<String, dynamic>> still(int cameraId, {bool fresh = false}) => fresh
      ? api.postJson('/shop/cameras/$cameraId/still')
      : api.getJson('/shop/cameras/$cameraId/still');
  @override
  Future<Map<String, dynamic>> roles(int siteId) => api.getJson('/shop/sites/$siteId/roles');
  @override
  Future<Map<String, dynamic>> setRole(int siteId, int userId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/viewers/$userId/role', body);
  @override
  Future<Map<String, dynamic>> accessLog(int siteId) =>
      api.getJson('/shop/sites/$siteId/access-log');
  @override
  Future<Map<String, dynamic>> shareLinks(int siteId) =>
      api.getJson('/shop/sites/$siteId/share-links');
  @override
  Future<Map<String, dynamic>> createShareLink(int siteId, Map<String, dynamic> body) =>
      api.postJson('/shop/sites/$siteId/share-links', body);
  @override
  Future<Map<String, dynamic>> revokeShareLink(int linkId) =>
      api.postJson('/shop/share-links/$linkId/revoke');
  @override
  Future<Map<String, dynamic>> watchGroups() => api.getJson('/shop/watch/groups');
  @override
  Future<Map<String, dynamic>> watchPosts(int groupId) =>
      api.getJson('/shop/watch/posts?group=$groupId');
  @override
  Future<Map<String, dynamic>> watchShare(Map<String, dynamic> body) =>
      api.postJson('/shop/watch/posts', body);
  @override
  Future<void> watchDelete(int postId) async {
    await api.deleteJson('/shop/watch/posts/$postId');
  }

  @override
  Future<Map<String, dynamic>> watchReport(int postId, String reason, {bool block = false}) =>
      api.postJson('/shop/watch/posts/$postId/report', {'reason': reason, 'block': block});
  @override
  Future<void> watchBlock(int userId) async {
    await api.postJson('/shop/watch/block', {'user': userId});
  }
}

/// "14:05" today, "3/11 14:05" another day — digits in the UI language.
String ctmTime(String lang, String? iso, {DateTime? now}) {
  if (iso == null || iso.isEmpty) return '';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final n = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(d.hour)}:${two(d.minute)}';
  final same = d.year == n.year && d.month == n.month && d.day == n.day;
  return _digits(lang, same ? hm : '${d.day}/${d.month} $hm');
}

/// Whole minutes since `iso` (null when unknown).
int? ctmAgeMinutes(String? iso, {DateTime? now}) {
  if (iso == null || iso.isEmpty) return null;
  final d = DateTime.tryParse(iso);
  if (d == null) return null;
  final m = (now ?? DateTime.now()).toUtc().difference(d.toUtc()).inMinutes;
  return m < 0 ? 0 : m;
}

const _bnZero = 0x09E6;

String _digits(String lang, String s) {
  if (lang != 'bn') return s;
  final b = StringBuffer();
  for (final c in s.codeUnits) {
    b.writeCharCode(c >= 0x30 && c <= 0x39 ? _bnZero + (c - 0x30) : c);
  }
  return b.toString();
}
