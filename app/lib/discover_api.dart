import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'config.dart';
import 'l10n/app_localizations.dart';

/// HOME "Discover" cards — server-driven (slot d1-discover).
///
/// The backend (`core/views_discover.py` + `core/logic/discover.py`) decides
/// WHO sees WHICH card (plan, audience, date window, min build; sponsored
/// reaches every plan, AdMob only Free users and only when no sponsor is
/// booked). The app only
/// renders what it receives, records impressions/taps (fire-and-forget) and
/// caches the last set so Discover works offline.
///
/// Built on the public [ApiClient] helpers so api.dart stays untouched.
extension DiscoverApi on ApiClient {
  /// GET /discover/cards?build=N -> {cards:[...], segment}
  /// h1-home: [heroAd] = the home hero is showing an AdMob native ad right
  /// now -> the server drops the Discover AdMob slot (one AdMob ad on home).
  Future<Map<String, dynamic>> discoverCards({int? build, bool heroAd = false}) {
    final q = [if (build != null) 'build=$build', if (heroAd) 'hero_ad=1'];
    return getJson('/discover/cards${q.isEmpty ? '' : '?${q.join('&')}'}');
  }

  /// POST /discover/track {card_id, event: impression|click}
  Future<Map<String, dynamic>> discoverTrack(int cardId, String event) =>
      postJson('/discover/track', {'card_id': cardId, 'event': event});

  // ---- owner admin (superuser; 403 otherwise) ----
  Future<Map<String, dynamic>> adminDiscoverList() =>
      getJson('/admin/discover/cards');

  Future<Map<String, dynamic>> adminDiscoverMeta() =>
      getJson('/admin/discover/meta');

  Future<Map<String, dynamic>> adminDiscoverCreate(Map<String, dynamic> body) =>
      postJson('/admin/discover/cards', body);

  Future<Map<String, dynamic>> adminDiscoverUpdate(
          int id, Map<String, dynamic> body) =>
      patchJson('/admin/discover/cards/$id', body);

  Future<Map<String, dynamic>> adminDiscoverDelete(int id) =>
      deleteJson('/admin/discover/cards/$id');

  Future<Map<String, dynamic>> adminDiscoverReorder(List<int> ids) =>
      postJson('/admin/discover/reorder', {'ids': ids});

  Future<Map<String, dynamic>> adminDiscoverPreview(String segment) =>
      getJson('/admin/discover/preview?segment=$segment');

  Future<Map<String, dynamic>> adminDiscoverReport(int id, {int days = 30}) =>
      getJson('/admin/discover/cards/$id/report?days=$days');

  /// CSV / PDF bytes for a sponsor ([fmt] = 'csv' | 'pdf').
  Future<List<int>> adminDiscoverExport(int id, String fmt, {int days = 30}) =>
      getBytes('/admin/discover/cards/$id/report.${fmt == 'pdf' ? 'pdf' : 'csv'}?days=$days');

  /// POST multipart image (PNG/JPEG/WEBP, <= 2 MB) for a card.
  Future<Map<String, dynamic>> adminDiscoverUploadImage(
      int id, String filePath) async {
    final req = http.MultipartRequest(
        'POST', AppConfig.api('/admin/discover/cards/$id/image'));
    if (token != null) req.headers['Authorization'] = 'Token $token';
    req.files.add(await http.MultipartFile.fromPath('image', filePath));
    final r = await http.Response.fromStream(await req.send());
    if (r.statusCode >= 200 && r.statusCode < 300) {
      return jsonDecode(r.body) as Map<String, dynamic>;
    }
    throw ApiException('upload failed (${r.statusCode})', r.statusCode);
  }
}

/// Icon names the server may send (mirror of `core/logic/discover.py` ICONS).
const Map<String, IconData> kDiscoverIcons = {
  'auto_fix_high': Icons.auto_fix_high_rounded,
  'phonelink_lock': Icons.phonelink_lock_rounded,
  'near_me': Icons.near_me_rounded,
  'diversity_3': Icons.diversity_3_rounded,
  'verified': Icons.verified_rounded,
  'directions_car': Icons.directions_car_rounded,
  'security': Icons.security_rounded,
  'workspace_premium': Icons.workspace_premium_rounded,
  'storefront': Icons.storefront_rounded,
  'account_tree': Icons.account_tree_rounded,
  'campaign': Icons.campaign_rounded,
  'star': Icons.star_outline_rounded,
  'local_offer': Icons.local_offer_rounded,
  'shopping_bag': Icons.shopping_bag_rounded,
  'favorite': Icons.favorite_outline_rounded,
  'school': Icons.school_rounded,
  'health': Icons.health_and_safety_rounded,
  'family': Icons.family_restroom_rounded,
  'money': Icons.account_balance_wallet_rounded,
  'lightbulb': Icons.lightbulb_outline_rounded,
};

/// One Discover card, from the server or the first-run fallback list.
class DiscoverItem {
  static const feature = 'FEATURE';
  static const ourProduct = 'OUR_PRODUCT';
  static const sponsored = 'SPONSORED';
  static const admob = 'ADMOB';

  /// Server id (null for the built-in fallback cards — those are not tracked).
  final int? id;
  final String key;
  final String type;
  final String titleBn, titleEn, descBn, descEn;
  final String icon;
  final String imageUrl;
  final String route;
  final String url;

  /// Fallback-only: localized copy straight from the ARB.
  final String Function(AppLocalizations t)? tTitle;
  final String Function(AppLocalizations t)? tDesc;

  const DiscoverItem({
    this.id,
    required this.key,
    required this.type,
    this.titleBn = '',
    this.titleEn = '',
    this.descBn = '',
    this.descEn = '',
    this.icon = '',
    this.imageUrl = '',
    this.route = '',
    this.url = '',
    this.tTitle,
    this.tDesc,
  });

  static String _s(Object? v) => v == null ? '' : v.toString();

  static Map _m(Object? v) => v is Map ? v : const {};

  factory DiscoverItem.fromJson(Map<String, dynamic> j) {
    final title = _m(j['title']);
    final desc = _m(j['description']);
    return DiscoverItem(
      id: j['id'] is num ? (j['id'] as num).toInt() : int.tryParse(_s(j['id'])),
      key: _s(j['key']),
      type: _s(j['type']),
      titleBn: _s(title['bn'] ?? j['title_bn']),
      titleEn: _s(title['en'] ?? j['title_en']),
      descBn: _s(desc['bn'] ?? j['desc_bn']),
      descEn: _s(desc['en'] ?? j['desc_en']),
      icon: _s(j['icon']),
      imageUrl: _s(j['image_url']),
      route: _s(j['route']),
      url: _s(j['url']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'key': key,
        'type': type,
        'title': {'bn': titleBn, 'en': titleEn},
        'description': {'bn': descBn, 'en': descEn},
        'icon': icon,
        'image_url': imageUrl,
        'route': route,
        'url': url,
      };

  bool get isSponsored => type == sponsored;
  bool get isProduct => type == ourProduct;
  bool get isAdmob => type == admob;
  bool get isExternal => url.isNotEmpty;

  /// Title in the UI language, falling back to the other language when the
  /// owner left one blank.
  String title(AppLocalizations t, String lang) {
    if (tTitle != null) return tTitle!(t);
    final a = lang == 'bn' ? titleBn : titleEn;
    return a.isNotEmpty ? a : (lang == 'bn' ? titleEn : titleBn);
  }

  String description(AppLocalizations t, String lang) {
    if (tDesc != null) return tDesc!(t);
    final a = lang == 'bn' ? descBn : descEn;
    return a.isNotEmpty ? a : (lang == 'bn' ? descEn : descBn);
  }

  IconData get iconData =>
      kDiscoverIcons[icon] ??
      (isExternal ? Icons.open_in_new_rounded : Icons.auto_awesome_rounded);

  /// Absolute image URL (server returns a relative signed `/api/v1/m/...`).
  String? get absoluteImageUrl {
    if (imageUrl.isEmpty) return null;
    if (imageUrl.startsWith('/')) return '${AppConfig.apiBase}$imageUrl';
    return imageUrl.startsWith('https://') ? imageUrl : null;
  }
}
