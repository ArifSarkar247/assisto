// cctvbox — Dart side of the Guard Box video decoder (IpCamDecoder.kt on the
// "com.assisto/guardbox" channel) + the pure feeding rules.
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'rtsp_client.dart';

/// One decoded picture.
class IpFrame {
  final Uint8List jpeg;
  final Uint8List gray; // gw x gh luminance, row stride = gw
  final int gw, gh, w, h;
  const IpFrame(this.jpeg, this.gray, this.gw, this.gh, this.w, this.h);
}

/// The decoder seam (tests inject a fake; the app uses [NativeIpDecoder]).
abstract class IpDecoder {
  Future<bool> available();
  Future<String?> open(String mime, List<Uint8List> csd); // null = ok, else error
  Future<bool> feed(Uint8List au, int ptsUs);
  Future<IpFrame?> grab({int gw = 160, int maxW = 640, int quality = 70, int timeoutMs = 3000});
  Future<void> close();
}

class NativeIpDecoder implements IpDecoder {
  static const _ch = MethodChannel('com.assisto/guardbox');
  String lastError = '';

  /// cctv-accuracy: the native decoder SLOT (one per LAN-grid tile; the
  /// Guard Box keeps the default 'guard').
  final String id;
  NativeIpDecoder({this.id = 'guard'});

  @override
  Future<bool> available() async {
    try {
      return await _ch.invokeMethod<bool>('decAvailable') == true;
    } catch (_) {
      return false; // an older build without the decoder
    }
  }

  Future<Map<String, dynamic>?> _call(String m, [Map<String, dynamic>? a]) async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>(m, {...?a, 'id': id});
      if (r != null && r['ok'] != true) lastError = (r['error'] ?? '').toString();
      return r;
    } catch (e) {
      lastError = e.runtimeType.toString();
      return null;
    }
  }

  @override
  Future<String?> open(String mime, List<Uint8List> csd) async {
    final r = await _call('decOpen', {'mime': mime, 'csd': csd});
    return r?['ok'] == true ? null : (lastError.isEmpty ? 'open' : lastError);
  }

  @override
  Future<bool> feed(Uint8List au, int ptsUs) async =>
      (await _call('decFeed', {'data': au, 'pts': ptsUs}))?['ok'] == true;

  @override
  Future<IpFrame?> grab({int gw = 160, int maxW = 640, int quality = 70, int timeoutMs = 3000}) async {
    final r = await _call('decGrab', {'gw': gw, 'maxW': maxW, 'q': quality, 'timeoutMs': timeoutMs});
    if (r == null || r['ok'] != true) return null;
    final j = r['jpeg'], g = r['gray'];
    if (j is! Uint8List || g is! Uint8List) return null;
    return IpFrame(j, g, (r['gw'] as num).toInt(), (r['gh'] as num).toInt(), (r['w'] as num).toInt(),
        (r['h'] as num).toInt());
  }

  @override
  Future<void> close() async {
    await _call('decClose');
  }
}

/// Which access units reach the decoder. An old phone that cannot keep up
/// drops to "key pictures only" (about one picture every 1-4 s from most
/// cameras) instead of falling minutes behind:
///   * a backlog over [maxBacklog] -> drop everything until the next key
///     picture (a P-picture without its reference would decode as garbage);
///   * [lowPowerAfter] such drops within 60 s -> key pictures only from then.
class FeedGate {
  final int maxBacklog;
  final int lowPowerAfter;
  bool waitKey = true; // the decoder starts on a key picture
  bool keyOnly;
  int dropped = 0;
  final _overflows = <DateTime>[];
  FeedGate({this.maxBacklog = 20, this.lowPowerAfter = 3, this.keyOnly = false});

  /// [backlog] = units already waiting. True = feed this one.
  bool accept(AccessUnit au, int backlog, {DateTime? now}) {
    if (backlog >= maxBacklog) {
      final t = now ?? DateTime.now();
      _overflows
        ..add(t)
        ..removeWhere((e) => t.difference(e) > const Duration(seconds: 60));
      if (_overflows.length >= lowPowerAfter) keyOnly = true;
      waitKey = true;
      dropped++;
      return false;
    }
    if (au.key) {
      waitKey = false;
      return true;
    }
    if (waitKey || keyOnly) {
      dropped++;
      return false;
    }
    return true;
  }

  /// The decoder failed: restart from the next key picture.
  void restart() => waitKey = true;
}
