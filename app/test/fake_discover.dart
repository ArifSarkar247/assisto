import 'package:assisto/api.dart';

/// d1-discover fake data for the screenshot gallery (wired from FakeApi).
/// Returns null for any non-Discover path so FakeApi keeps handling it.
Map<String, dynamic>? fakeDiscoverGet(String path, bool bn, String mode) {
  if (!path.startsWith('/discover/') && !path.startsWith('/admin/discover/')) {
    return null;
  }
  if (mode == 'fail') {
    throw ApiException(bn ? 'সংযোগ করা গেল না' : 'Could not connect', 503);
  }
  if (path.startsWith('/discover/cards')) {
    // The server seed (same look as the built-in list) — home shots unchanged.
    return {'segment': 'premium', 'cards': mode == 'empty' ? [] : _seed()};
  }
  if (path == '/admin/discover/meta') {
    return {
      'routes': ['photo_enhance', 'phone_safety', 'journey', 'messages', 'plans', 'notes'],
      'icons': ['auto_fix_high', 'phonelink_lock', 'near_me', 'storefront', 'campaign', 'star'],
      'types': ['FEATURE', 'OUR_PRODUCT', 'SPONSORED', 'ADMOB'],
      'audiences': ['all', 'free', 'premium', 'business'],
    };
  }
  if (path == '/admin/discover/cards') {
    return {'can_manage': true, 'cards': mode == 'empty' ? [] : fakeDiscoverAdminCards()};
  }
  if (path.startsWith('/admin/discover/preview')) {
    final free = path.contains('segment=free');
    return {
      'segment': free ? 'free' : 'premium',
      'cards': [if (free) _sponsoredApp(), ..._seed().take(3)],
    };
  }
  if (RegExp(r'^/admin/discover/cards/\d+/report').hasMatch(path)) {
    final now = DateTime.now();
    final rows = [
      for (var i = 6; i >= 0; i--)
        {
          'date': now.subtract(Duration(days: i)).toIso8601String().substring(0, 10),
          'impressions': 300 + i * 40,
          'clicks': 9 + i,
          'ctr': double.parse((100 * (9 + i) / (300 + i * 40)).toStringAsFixed(2)),
        }
    ];
    final ti = rows.fold<int>(0, (a, r) => a + (r['impressions'] as int));
    final tc = rows.fold<int>(0, (a, r) => a + (r['clicks'] as int));
    return {
      'card': {'id': 20, 'key': 'fresh-market', 'type': 'SPONSORED', 'title_en': 'Fresh Market',
        'title_bn': 'ফ্রেশ মার্কেট', 'sponsor_name': 'Fresh Market Ltd', 'sponsor_revenue': 5000.0},
      'from': rows.first['date'], 'to': rows.last['date'], 'rows': rows,
      'totals': {'impressions': ti, 'clicks': tc, 'ctr': double.parse((100 * tc / ti).toStringAsFixed(2))},
    };
  }
  return null;
}

Map<String, dynamic> _sponsoredApp() => {
      'id': 20, 'key': 'fresh-market', 'type': 'SPONSORED', 'label': 'sponsored',
      'title': {'bn': 'ফ্রেশ মার্কেট', 'en': 'Fresh Market'},
      'description': {'bn': 'তাজা সবজি ঘরে পৌঁছে দেওয়া হয়।', 'en': 'Fresh vegetables delivered to your door.'},
      'icon': 'shopping_bag', 'image_url': '', 'route': '', 'url': 'https://shop.example.com',
    };

List<Map<String, dynamic>> _seed() {
  Map<String, dynamic> c(int id, String key, String type, String icon, String route, String url,
          String tbn, String ten, String dbn, String den) =>
      {'id': id, 'key': key, 'type': type, 'label': type == 'OUR_PRODUCT' ? 'our_products' : '',
        'title': {'bn': tbn, 'en': ten}, 'description': {'bn': dbn, 'en': den},
        'icon': icon, 'image_url': '', 'route': route, 'url': url};
  return [
    c(1, 'photo_enhance', 'FEATURE', 'auto_fix_high', 'photo_enhance', '', 'ছবি উন্নত করুন', 'Enhance photo',
        'যেকোনো ছবি কয়েক সেকেন্ডে পরিষ্কার ও উজ্জ্বল করুন।', 'Sharpen and brighten any photo in seconds.'),
    c(2, 'phone_safety', 'FEATURE', 'phonelink_lock', 'phone_safety', '', 'চুরি-প্রতিরোধ', 'Anti-theft',
        'ফোন হারালে বা চুরি হলে সুরক্ষিত রাখুন।', 'Protect your phone if it is lost or stolen.'),
    c(3, 'journey', 'FEATURE', 'near_me', 'journey', '', 'নিরাপদ যাত্রা', 'Safe Journey',
        'পথে পরিবারের সঙ্গে লাইভ লোকেশন শেয়ার করুন।', 'Share live location with family on the road.'),
    c(9, 'asalify', 'OUR_PRODUCT', 'storefront', '', 'https://asalify.com', 'Asalify', 'Asalify',
        'আমাদের সহজ অনলাইন স্টোর বিল্ডার — asalify.com।', 'Our easy online store builder — asalify.com.'),
  ];
}

List<Map<String, dynamic>> fakeDiscoverAdminCards() {
  Map<String, dynamic> a(int id, String type, String tbn, String ten, String icon,
          {String route = '', String url = '', bool enabled = true, bool live = true,
          String audience = 'all', int imp = 0, int clk = 0, String sponsor = '', double rev = 0}) =>
      {'id': id, 'key': 'k$id', 'type': type, 'title_bn': tbn, 'title_en': ten,
        'desc_bn': '', 'desc_en': '', 'icon': icon, 'route': route, 'url': url,
        'order': id * 10, 'enabled': enabled, 'live': live, 'audience': audience,
        'start_at': null, 'end_at': null, 'min_build': null, 'sponsor_name': sponsor,
        'sponsor_revenue': rev, 'image_url': '', 'label': '',
        'stats': {'impressions': imp, 'clicks': clk, 'ctr': imp == 0 ? 0 : double.parse((100 * clk / imp).toStringAsFixed(2))}};
  return [
    a(20, 'SPONSORED', 'ফ্রেশ মার্কেট', 'Fresh Market', 'shopping_bag', url: 'https://shop.example.com',
        audience: 'free', imp: 2380, clk: 81, sponsor: 'Fresh Market Ltd', rev: 5000),
    a(1, 'FEATURE', 'ছবি উন্নত করুন', 'Enhance photo', 'auto_fix_high', route: 'photo_enhance', imp: 940, clk: 57),
    a(2, 'FEATURE', 'চুরি-প্রতিরোধ', 'Anti-theft', 'phonelink_lock', route: 'phone_safety', imp: 812, clk: 33),
    a(9, 'OUR_PRODUCT', 'Asalify', 'Asalify', 'storefront', url: 'https://asalify.com', imp: 650, clk: 21),
    a(30, 'ADMOB', '', '', 'campaign', enabled: false, live: false, audience: 'free'),
  ];
}
