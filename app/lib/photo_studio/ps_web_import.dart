import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../api.dart';
import 'ps_backend.dart';
import 'ps_models.dart';

/// w1-webphoto — a passport/visa photo made on lifeassisto.com/photo, opened
/// in Photo Studio through the deep link https://lifeassisto.com/photo/app?t=…
///
/// The server hands over ONLY a Photo Studio job (kind `enhance_hd`, with the
/// passport/visa preset as its option) plus its preview — reduced and
/// watermarked for free users. The clean file is the job's result and leaves
/// only through the normal export gate (ads / credits / Premium). No bypass.
class WebPhotoImport {
  const WebPhotoImport({
    required this.job,
    required this.preview,
    this.label = '',
    this.studioOption = '',
  });
  final PsJob job;
  final Uint8List preview;
  final String label;

  /// 'passport_bd' | 'visa_bd' | '' — pre-selected in the studio.
  final String studioOption;
}

enum WebClaimStatus { ok, expired, failed }

class WebClaimResult {
  const WebClaimResult(this.status, {this.import, this.message = ''});
  final WebClaimStatus status;
  final WebPhotoImport? import;
  final String message;
}

/// Server seam (fake in tests / the gallery).
abstract class WebPhotoApi {
  /// Claims the website photo ONCE (login required, <= 1 hour old).
  Future<WebClaimResult> claim(String token);
}

class ApiWebPhotoApi implements WebPhotoApi {
  ApiWebPhotoApi(this.api, this.backend);
  final ApiClient api;
  final PsBackend backend;

  @override
  Future<WebClaimResult> claim(String token) async {
    Map<String, dynamic> j;
    try {
      j = await api.postJsonRaw('/web-photo/claim', {'token': token});
    } catch (_) {
      return const WebClaimResult(WebClaimStatus.failed);
    }
    return decodeClaim(j, backend);
  }
}

/// Shared by the real API and the fakes: body (with `_status`) -> result.
Future<WebClaimResult> decodeClaim(
    Map<String, dynamic> j, PsBackend backend) async {
  final st = j['_status'] is num ? (j['_status'] as num).toInt() : 200;
  final msg = '${j['message'] ?? ''}';
  if (st == 410 || st == 404) {
    return WebClaimResult(WebClaimStatus.expired, message: msg);
  }
  if (st != 200 || j['ok'] != true || j['job'] is! Map) {
    return WebClaimResult(WebClaimStatus.failed, message: msg);
  }
  final job = PsJob.fromJson(j['job'] as Map);
  if (job.previewUrl.isEmpty) {
    return const WebClaimResult(WebClaimStatus.failed);
  }
  final prev = await backend.download(job.previewUrl);
  if (prev == null || prev.isEmpty) {
    return const WebClaimResult(WebClaimStatus.failed);
  }
  return WebClaimResult(WebClaimStatus.ok,
      import: WebPhotoImport(
          job: job,
          preview: prev,
          label: '${j['label'] ?? ''}',
          studioOption: '${j['studio_option'] ?? ''}'));
}

/// Deep-link parsing + the "sign in first" hand-off.
class WebPhotoLink {
  WebPhotoLink._();

  static const path = '/photo/app';

  /// A token waiting for sign-in (set when the link arrives logged out).
  static String? pending;

  /// Token from a route name or full URL (`/photo/app?t=…` or
  /// `https://lifeassisto.com/photo/app?t=…`); null when not ours.
  static String? tokenFrom(String? name) {
    if (name == null || name.isEmpty) return null;
    final Uri u;
    try {
      u = Uri.parse(name);
    } catch (_) {
      return null;
    }
    if (u.path != path) return null;
    if (u.hasAuthority && !u.host.endsWith('lifeassisto.com')) return null;
    final t = u.queryParameters['t'] ?? '';
    if (t.isEmpty || t.length > 64) return null;
    if (!RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(t)) return null;
    return t;
  }

  static bool _coldDone = false;

  /// Cold start: FlutterActivity hands the App Link over as the FULL URL
  /// (Intent.getData().toString()) in PlatformDispatcher.defaultRouteName.
  /// [route] ignores full URLs, so the Navigator falls back to home as
  /// before (no warning), and the home calls this once after its first frame
  /// to push the link screen ON TOP of home.
  static void maybeOpenColdStart(BuildContext context, String defaultRouteName,
      Widget Function(String token) builder) {
    if (_coldDone) return;
    _coldDone = true;
    if (defaultRouteName.startsWith('/')) return; // handled by [route]
    final t = tokenFrom(defaultRouteName);
    if (t == null) return;
    try {
      Navigator.of(context).push(PageRouteBuilder<void>(
        settings: const RouteSettings(name: path),
        pageBuilder: (_, __, ___) => builder(t),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ));
    } catch (_) {}
  }

  @visibleForTesting
  static void resetColdStart() => _coldDone = false;

  /// MaterialApp.onGenerateRoute hook: our deep link -> [builder], else null
  /// (so every other route behaves exactly as before).
  static Route<dynamic>? route(
      RouteSettings s, Widget Function(String token) builder) {
    // path-form names only (warm pushes / path initial routes); a full URL
    // is the cold-start case, see [maybeOpenColdStart]
    if (!(s.name ?? '').startsWith('/')) return null;
    final t = tokenFrom(s.name);
    if (t == null) return null;
    return PageRouteBuilder<void>(
      settings: s,
      pageBuilder: (_, __, ___) => builder(t),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    );
  }
}
