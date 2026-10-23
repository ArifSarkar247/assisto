/// p2-money: what the server sends for one DIRECT sponsor creative and one
/// ad slot (`GET /ads/slot`). Pure Dart, parsed defensively.
library;

String _s(dynamic v) => v == null ? '' : '$v'.trim();

String _pick(dynamic m, bool bn) {
  if (m is Map) {
    final b = _s(m['bn']), e = _s(m['en']);
    return bn ? (b.isNotEmpty ? b : e) : (e.isNotEmpty ? e : b);
  }
  return _s(m);
}

List<String> _lines(dynamic m, bool bn) {
  final v = m is Map ? (bn ? m['bn'] : m['en']) ?? m['en'] ?? m['bn'] : m;
  return v is List ? v.map((e) => '$e').toList() : const [];
}

class SponsorCreative {
  const SponsorCreative({
    required this.campaignId,
    required this.sponsorId,
    required this.sponsor,
    required this.placement,
    required this.raw,
    this.token = '',
    this.url = '',
    this.imageUrl = '',
  });

  final int campaignId;
  final int sponsorId;
  final String sponsor;
  final String placement;
  final String token;
  final String url;
  final String imageUrl;
  final Map<String, dynamic> raw;

  static SponsorCreative? fromJson(dynamic j) {
    if (j is! Map) return null;
    final m = j.cast<String, dynamic>();
    final id = m['campaign_id'];
    final cid = id is num ? id.toInt() : int.tryParse('$id') ?? 0;
    if (cid <= 0) return null;
    final sid = m['sponsor_id'];
    return SponsorCreative(
      campaignId: cid,
      sponsorId: sid is num ? sid.toInt() : int.tryParse('$sid') ?? 0,
      sponsor: _s(m['sponsor']),
      placement: _s(m['placement']),
      token: _s(m['token']),
      url: _s(m['url']),
      imageUrl: _s(m['image_url']),
      raw: m,
    );
  }

  String title(bool bn) => _pick(raw['title'], bn);
  String body(bool bn) => _pick(raw['body'], bn);
  String cta(bool bn) => _pick(raw['cta'], bn);
  List<String> why(bool bn) => _lines(raw['why'], bn);
  bool get matchesYou => raw['matches_you'] == true;
  String get endsAt => _s(raw['ends_at']);

  /// Only https links ever open (the owner panel refuses anything else too).
  bool get hasLink => url.startsWith('https://');
}

class AdSlot {
  const AdSlot({
    this.show = false,
    this.source = 'none',
    this.reason = '',
    this.skipAfterS = 5,
    this.creative,
  });

  final bool show;

  /// 'direct' (our sponsor, served first) | 'admob' (fills an empty slot,
  /// only once AdMob is linked) | 'none'.
  final String source;
  final String reason;
  final int skipAfterS;
  final SponsorCreative? creative;

  static const none = AdSlot();

  bool get isDirect => show && source == 'direct' && creative != null;
  bool get isAdmob => show && source == 'admob';

  factory AdSlot.fromJson(Map<String, dynamic>? j) {
    if (j == null) return none;
    final sk = j['skip_after_s'];
    var skip = sk is num ? sk.toInt() : int.tryParse('$sk') ?? 5;
    // owner order: skippable after 5 s; never sooner, never above 15 s
    if (skip < 5) skip = 5;
    if (skip > 15) skip = 15;
    return AdSlot(
      show: j['show'] == true,
      source: _s(j['source']).isEmpty ? 'none' : _s(j['source']),
      reason: _s(j['reason']),
      skipAfterS: skip,
      creative: SponsorCreative.fromJson(j['creative']),
    );
  }
}
