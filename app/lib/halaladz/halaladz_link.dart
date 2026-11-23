import 'package:flutter/material.dart';

import 'halaladz_api.dart' show normHzCode;

/// halaladz — the deep link assisto://link-halaladz?code=CODE.
///
/// android.yml adds a VIEW intent filter (scheme assisto, host link-halaladz)
/// on MainActivity. COLD start: Flutter's defaultRouteName is the full URI.
/// WARM start: Flutter keeps only path + query, so MainActivity.onNewIntent
/// gives the URI the path /link-halaladz first -> route "/link-halaladz?code=".
/// The link only FILLS IN the code: the person still taps "Link account"
/// (a link someone sends can never link an account by itself).
class HalalAdzDeepLink {
  HalalAdzDeepLink._();

  static const path = '/link-halaladz';

  /// A route name / URI -> the (normalized) code, '' for a link without a
  /// valid code, null when it is not a HalalAdz link at all.
  static String? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final u = Uri.tryParse(raw.trim());
    if (u == null) return null;
    final isLink = (u.scheme == 'assisto' &&
            (u.host == 'link-halaladz' || u.path == path)) ||
        (u.scheme.isEmpty && u.path == path);
    if (!isLink) return null;
    return normHzCode(u.queryParameters['code']) ?? '';
  }

  /// A code that arrived signed out (opened by the root after sign-in).
  static String? pending;

  static bool _coldDone = false;

  /// MaterialApp.onGenerateRoute: "/link-halaladz?code=…" -> [builder].
  static Route<dynamic>? route(
      RouteSettings s, Widget Function(String code) builder) {
    final name = s.name ?? '';
    if (!name.startsWith(path)) return null;
    final code = parse(name);
    if (code == null) return null;
    return MaterialPageRoute<void>(settings: s, builder: (_) => builder(code));
  }

  /// Cold start: the full URI sits in defaultRouteName. Signed out -> kept
  /// in [pending]; signed in -> the link screen on top of home, once.
  static void maybeOpenColdStart(BuildContext context, String defaultRouteName,
      Widget Function(String code) builder,
      {required bool loggedIn}) {
    if (_coldDone) return;
    _coldDone = true;
    if (defaultRouteName.startsWith('/')) return; // warm form: [route]
    final code = parse(defaultRouteName);
    if (code == null) return;
    if (!loggedIn) {
      pending = code;
      return;
    }
    try {
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => builder(code)));
    } catch (_) {}
  }

  @visibleForTesting
  static void resetColdStart() => _coldDone = false;
}
