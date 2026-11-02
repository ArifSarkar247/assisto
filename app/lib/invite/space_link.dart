import 'package:flutter/material.dart';

/// channels (2 Nov) — shared CHANNEL / COMMUNITY links.
///
///  * https://lifeassisto.com/ch/<handle>[?k=<code>] — a channel (k = the
///    private invite code; public channels need none);
///  * https://lifeassisto.com/cm/<code> — a community invite (joining asks an
///    admin first).
///
/// Android App Links (android.yml adds the /ch/ and /cm/ intent filters on
/// the verified lifeassisto.com host) hand the URL to Flutter: warm as a
/// route name ("/ch/…"), cold as the full URL in defaultRouteName. Without
/// the app the same URL is a web page with "Open in Assisto" + Google Play.
/// A typed / pasted link or bare community code goes through [parse] too.
class SpaceLink {
  const SpaceLink._(this.kind, this.handle, this.code);

  /// 'channel' or 'community'.
  final String kind;

  /// Channel @handle (channels only).
  final String handle;

  /// Private channel invite code, or the community invite code.
  final String code;

  bool get isChannel => kind == 'channel';

  static const _codeChars = 'abcdefghjkmnpqrstuvwxyz23456789';

  static String _clean(String s, int max) {
    final out = StringBuffer();
    for (final c in s.toLowerCase().split('')) {
      if (_codeChars.contains(c)) out.write(c);
    }
    final r = out.toString();
    return r.length > max ? r.substring(0, max) : r;
  }

  /// A link / path / bare community code -> [SpaceLink], else null.
  static SpaceLink? parse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    Uri u;
    try {
      u = Uri.parse(s.contains('://') || s.startsWith('/') ? s : '/$s');
    } catch (_) {
      return null;
    }
    if (u.hasAuthority && !u.host.endsWith('lifeassisto.com')) return null;
    final seg = u.pathSegments.where((x) => x.isNotEmpty).toList();
    if (seg.length == 2 && seg[0] == 'ch') {
      final h = seg[1].toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
      if (h.isEmpty || h.length > 32) return null;
      return SpaceLink._('channel', h, _clean(u.queryParameters['k'] ?? '', 16));
    }
    if (seg.length == 2 && seg[0] == 'cm') {
      final c = _clean(seg[1], 16);
      return c.length >= 6 ? SpaceLink._('community', '', c) : null;
    }
    // a bare community code typed into "Join with a link or code"
    if (!u.hasAuthority && seg.length == 1 && !s.contains('/')) {
      final c = _clean(seg[0], 16);
      if (c.length == 10 && c.length == seg[0].length) {
        return SpaceLink._('community', '', c);
      }
    }
    return null;
  }

  static bool isSpacePath(String? name) =>
      name != null &&
      (name.contains('/ch/') || name.contains('/cm/')) &&
      parse(name) != null;

  /// A link that arrived signed out (opened after sign-in by the root).
  static SpaceLink? pending;

  static bool _coldDone = false;

  /// MaterialApp.onGenerateRoute: "/ch/…" or "/cm/…" -> [builder], else null.
  static Route<dynamic>? route(
      RouteSettings s, Widget Function(SpaceLink link) builder) {
    final name = s.name ?? '';
    if (!name.startsWith('/') || !isSpacePath(name)) return null;
    final l = parse(name)!;
    return MaterialPageRoute<void>(settings: s, builder: (_) => builder(l));
  }

  /// Cold start: the full URL sits in defaultRouteName; push the link screen
  /// on top of home once.
  static void maybeOpenColdStart(BuildContext context, String defaultRouteName,
      Widget Function(SpaceLink link) builder) {
    if (_coldDone) return;
    _coldDone = true;
    if (defaultRouteName.startsWith('/')) return; // handled by [route]
    if (!isSpacePath(defaultRouteName)) return;
    final l = parse(defaultRouteName);
    if (l == null) return;
    try {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => builder(l)));
    } catch (_) {}
  }

  @visibleForTesting
  static void resetColdStart() => _coldDone = false;
}
