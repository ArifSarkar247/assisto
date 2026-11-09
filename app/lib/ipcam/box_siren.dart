// cctvbox: the owner pressed "Siren" or "Warning" on an alert (cctvact) —
// the Guard Box / phone camera at the place plays it through its speaker.
// Delivered in the heartbeat reply as `play: [{id, sound, seconds}]`; the
// owner's recorded warning is fetched with this device's token from
// the warn_url the play task names (cctvact: shop/device/warn-clip; never
// kept: a temp file, deleted after).
// Sound goes through the documented siren-style exception (STREAM_ALARM,
// the train alarm's native channel) behind an [AudioRouteService] lease.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../train/dest_alarm_sound.dart';

/// One play request from the heartbeat (unknown values -> safe defaults).
class PlayTask {
  final int id;
  final String sound; // 'siren' | 'warn'
  final int seconds; // 3..60
  final String warnUrl; // server path of the owner's clip ('' = none)
  const PlayTask(this.id, this.sound, this.seconds, [this.warnUrl = '']);

  static List<PlayTask> fromHeartbeat(Object? raw) {
    if (raw is! List) return const [];
    final out = <PlayTask>[];
    for (final m in raw.whereType<Map>()) {
      final id = (m['id'] as num?)?.toInt();
      if (id == null) continue;
      final sound = m['sound'] == 'warn' ? 'warn' : 'siren';
      final secs = ((m['seconds'] as num?)?.toInt() ?? 20).clamp(3, 60);
      final u = (m['warn_url'] ?? '').toString();
      out.add(PlayTask(id, sound, secs, u.startsWith('/api/v1/shop/device/') ? u : ''));
    }
    return out;
  }
}

typedef ClipFetch = Future<List<int>?> Function(String path);

class BoxSiren {
  final DestAlarmSound sound;
  final ClipFetch fetchClip;
  final Future<void> Function(Duration) wait;
  bool _busy = false;
  final _done = <int>{};
  BoxSiren(this.sound, this.fetchClip, {Future<void> Function(Duration)? wait})
      : wait = wait ?? ((d) => Future<void>.delayed(d));

  /// The app's real player for a device [token].
  factory BoxSiren.forDevice(String token, {int? cameraId, http.Client? client}) {
    Future<List<int>?> fetch(String path) async {
      final c = client ?? http.Client();
      try {
        // the path comes from the server's play task (never typed here)
        final r = await c.get(Uri.parse('${AppConfig.apiBase}$path'), headers: {
          'X-Shop-Token': token,
          if (cameraId != null) 'X-Shop-Camera': '$cameraId',
        }).timeout(const Duration(seconds: 20));
        return r.statusCode == 200 && r.bodyBytes.isNotEmpty ? r.bodyBytes : null;
      } catch (_) {
        return null;
      } finally {
        if (client == null) c.close();
      }
    }

    return BoxSiren(NativeDestAlarmSound(), fetch);
  }

  /// Play every new task (one at a time; a repeated id is ignored).
  /// Returns what really sounded, for the screen ('siren' / 'warn').
  Future<List<String>> handle(List<PlayTask> tasks) async {
    final played = <String>[];
    if (_busy) return played;
    _busy = true;
    try {
      for (final t in tasks) {
        if (!_done.add(t.id)) continue;
        if (t.sound == 'warn' && t.warnUrl.isNotEmpty) {
          final bytes = await fetchClip(t.warnUrl);
          if (bytes != null && await _playClip(bytes, t.seconds)) {
            played.add('warn');
            continue;
          }
          // no clip / not playable: the siren still deters (honest fallback)
        }
        if (await sound.start(sound: true, vibrate: false)) played.add('siren');
        await wait(Duration(seconds: t.seconds));
        await sound.stop();
      }
    } catch (_) {
      try {
        await sound.stop();
      } catch (_) {}
    } finally {
      _busy = false;
    }
    return played;
  }

  Future<bool> _playClip(List<int> bytes, int seconds) async {
    File? f;
    try {
      final dir = await getTemporaryDirectory();
      f = File('${dir.path}/warn_${DateTime.now().millisecondsSinceEpoch}.wav');
      await f.writeAsBytes(bytes, flush: true);
      // the warning repeats (about every 8 s) for the asked time
      var ok = false;
      final end = DateTime.now().add(Duration(seconds: seconds));
      do {
        ok = await sound.playClip(f.path) || ok;
        if (!ok) break;
        await wait(const Duration(seconds: 8));
      } while (DateTime.now().isBefore(end));
      await sound.stop();
      return ok;
    } catch (_) {
      return false;
    } finally {
      try {
        await f?.delete();
      } catch (_) {}
    }
  }
}
