// mc-media2 — what a My Circle LOCATION / LIVE LOCATION / CONTACT CARD
// message carries INSIDE its E2E envelope.
//
// The message is content_type "location" or "contact" (inline ciphertext; the
// server never sees a coordinate, a name or a number). Its PLAINTEXT is
//
//     <readable fallback line>\n⁣SH1:<base64url(JSON)>
//
// the same shape as the p3 cards / cde controls: this app draws the card;
// older app versions show "Location" / "Contact" (1:1, notifications, chat
// list) or the readable first line with a maps link (groups).
//
//   location: {"t":"loc","lat":..,"lng":..,"acc":<m>,"lbl":<place label>,
//              "at":<ms fix time>, "live":1, "until":<ms>, "stop":1, "seq":n}
//   contact:  {"t":"contact","n":<name>,"p":[<numbers>],"uid":<Assisto user id>}
//
// A LIVE location is one message whose ciphertext the sender's phone replaces
// in place while Assisto is open (POST /circle/live/<id>); "until" ends it on
// every phone, "stop" ends it early.
import 'dart:convert';

const String kShareMarker = '⁣SH1:';

/// Content types whose plaintext is a share payload.
const Set<String> kShareKinds = {'location', 'contact'};

/// Live durations offered (mirrors core/logic/circle_media.LIVE_DURATIONS_MIN).
const Map<String, int> kLiveDurationsMin = {'15m': 15, '1h': 60, '8h': 480};

double? _d(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
int? _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

String _clip(String s, int n) {
  final c = s.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
  return c.length > n ? c.substring(0, n) : c;
}

/// A point, optionally live.
class LocationShare {
  final double lat;
  final double lng;
  final double? accuracy; // metres
  final String label;
  final int at; // ms since epoch of the fix
  final bool live;
  final int until; // ms since epoch (live only)
  final bool stopped;
  final int seq;

  const LocationShare({
    required this.lat,
    required this.lng,
    this.accuracy,
    this.label = '',
    this.at = 0,
    this.live = false,
    this.until = 0,
    this.stopped = false,
    this.seq = 0,
  });

  static bool validLatLng(double lat, double lng) =>
      lat.isFinite && lng.isFinite && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;

  LocationShare copyWith({
    double? lat,
    double? lng,
    double? accuracy,
    int? at,
    bool? stopped,
    int? seq,
    bool? live,
  }) =>
      LocationShare(
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        accuracy: accuracy ?? this.accuracy,
        label: label,
        at: at ?? this.at,
        live: live ?? this.live,
        until: until,
        stopped: stopped ?? this.stopped,
        seq: seq ?? this.seq,
      );

  /// A forward never carries "live": the forwarder can't update it.
  LocationShare asStatic() => LocationShare(
      lat: lat, lng: lng, accuracy: accuracy, label: label, at: at);

  /// Live and not stopped and not past its end (at [now]).
  bool isLiveAt(DateTime now) =>
      live && !stopped && now.millisecondsSinceEpoch < until;

  Map<String, dynamic> toJson() => {
        't': 'loc',
        'lat': double.parse(lat.toStringAsFixed(6)),
        'lng': double.parse(lng.toStringAsFixed(6)),
        if (accuracy != null) 'acc': accuracy!.round(),
        if (label.isNotEmpty) 'lbl': label,
        if (at > 0) 'at': at,
        if (live) 'live': 1,
        if (live) 'until': until,
        if (stopped) 'stop': 1,
        if (live) 'seq': seq,
      };

  static LocationShare? fromJson(Map j) {
    if (j['t'] != 'loc') return null;
    final lat = _d(j['lat']), lng = _d(j['lng']);
    if (lat == null || lng == null || !validLatLng(lat, lng)) return null;
    final acc = _d(j['acc']);
    final live = j['live'] == 1 || j['live'] == true;
    return LocationShare(
      lat: lat,
      lng: lng,
      accuracy: acc == null || !acc.isFinite || acc < 0 ? null : acc.clamp(0, 100000).toDouble(),
      label: _clip('${j['lbl'] ?? ''}', 80),
      at: _i(j['at']) ?? 0,
      live: live,
      until: live ? (_i(j['until']) ?? 0) : 0,
      stopped: j['stop'] == 1 || j['stop'] == true,
      seq: _i(j['seq']) ?? 0,
    );
  }

  String get coords => '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';

  /// "Open in Maps": the phone's own maps app (geo:) …
  Uri get geoUri {
    final q = '${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
    final l = label.isEmpty ? '' : '(${Uri.encodeComponent(label)})';
    return Uri.parse('geo:$q?q=$q$l');
  }

  /// … or the browser when no maps app is installed.
  Uri get webUri => Uri.parse(
      'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}');
}

/// A contact card: a name + numbers, or a My Circle member (Assisto user id).
class ContactShare {
  final String name;
  final List<String> phones;
  final int? uid;
  const ContactShare({required this.name, this.phones = const [], this.uid});

  static String cleanPhone(String raw) {
    final s = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    final plus = s.startsWith('+');
    final digits = s.replaceAll('+', '');
    final out = (plus ? '+' : '') + digits;
    return out.length > 20 ? out.substring(0, 20) : out;
  }

  Map<String, dynamic> toJson() => {
        't': 'contact',
        'n': name,
        if (phones.isNotEmpty) 'p': phones,
        if (uid != null) 'uid': uid,
      };

  static ContactShare? fromJson(Map j) {
    if (j['t'] != 'contact') return null;
    final name = _clip('${j['n'] ?? ''}', 80);
    final phones = <String>[];
    for (final p in (j['p'] is List ? j['p'] as List : const [])) {
      final c = cleanPhone('$p');
      if (c.replaceAll('+', '').length >= 3 && !phones.contains(c)) phones.add(c);
      if (phones.length >= 5) break;
    }
    final uid = _i(j['uid']);
    if (name.isEmpty && phones.isEmpty) return null;
    if (phones.isEmpty && (uid == null || uid <= 0)) return null;
    return ContactShare(name: name, phones: phones, uid: uid != null && uid > 0 ? uid : null);
  }
}

/// One decoded share (exactly one of [location] / [contact]).
class SharePayload {
  final LocationShare? location;
  final ContactShare? contact;
  const SharePayload.location(LocationShare this.location) : contact = null;
  const SharePayload.contact(ContactShare this.contact) : location = null;
}

/// The plaintext to encrypt ([fallback] = one readable line, sender's language).
String encodeShare(Map<String, dynamic> json, String fallback) {
  final line = fallback.replaceAll('\n', ' ').trim();
  final body = base64Url.encode(utf8.encode(jsonEncode(json)));
  return '$line\n$kShareMarker$body';
}

String encodeLocation(LocationShare s, String fallback) => encodeShare(s.toJson(), fallback);
String encodeContact(ContactShare s, String fallback) => encodeShare(s.toJson(), fallback);

bool isShareText(String plaintext) => plaintext.contains(kShareMarker);

/// The share inside a decrypted message, or null (ordinary text, malformed,
/// or a kind this build does not know — then the readable line shows).
SharePayload? decodeShare(String plaintext) {
  final i = plaintext.indexOf(kShareMarker);
  if (i < 0) return null;
  try {
    final raw = plaintext.substring(i + kShareMarker.length).trim();
    if (raw.length > 12000) return null;
    final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(raw))));
    if (j is! Map) return null;
    final loc = LocationShare.fromJson(j);
    if (loc != null) return SharePayload.location(loc);
    final c = ContactShare.fromJson(j);
    if (c != null) return SharePayload.contact(c);
  } catch (_) {}
  return null;
}

/// The readable line of a share message (marker + payload removed).
String shareFallback(String plaintext) {
  final i = plaintext.indexOf(kShareMarker);
  if (i < 0) return plaintext;
  return plaintext.substring(0, i).trim();
}

/// For a forward: a live location goes out as a still point (re-encoded),
/// anything else unchanged.
String shareForForward(String plaintext) {
  final s = decodeShare(plaintext);
  final loc = s?.location;
  if (loc == null || !loc.live) return plaintext;
  return encodeLocation(loc.asStatic(), shareFallback(plaintext));
}

/// The content type a forward of a [ct] message carries.
String mc2ForwardKind(String ct) => kShareKinds.contains(ct) ? ct : 'text';

/// The plaintext a forward of a [ct] message carries (live → still point).
String mc2ForwardText(String ct, String text) =>
    kShareKinds.contains(ct) ? shareForForward(text) : text;
