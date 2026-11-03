import '../../api.dart';
import '../../services/error_report.dart';

/// viewonce — THE one app-side source of the owner's My Circle media limits
/// (owner order 3 Nov 16:30, part F). Fetched once per app run from
/// GET /circle/media/limits (Owner Admin > pricing > limits, editable
/// without a new build); the safe owner defaults below hold until then and
/// the server re-checks every upload (Bangla + English refusal).
///
/// Owner defaults: video <= 3 min, compressed on the phone to 720p and
/// <= 25 MB (longer clips go to the trim screen first); files <= 100 MB;
/// up to 30 photos / videos at once, auto-compressed; voice <= 15 min.
class MediaLimits {
  MediaLimits._();
  static const int _mb = 1024 * 1024;

  /// Per-file caps (plain bytes) by kind.
  static int photo = 16 * _mb, voice = 16 * _mb, document = 100 * _mb, video = 25 * _mb;

  /// Photos / videos in one send (circlemedia's multi-photo picker reads it).
  static int photosPerSend = 30;

  /// Longest video (longer = trim screen) and voice message, in seconds.
  static int videoSeconds = 180;
  static int voiceSeconds = 900;

  /// Videos are compressed so their SHORT side is at most this (720p).
  static int videoHeight = 720;

  /// Unopened view-once media is deleted from the server after this.
  static int viewOnceDays = 14;

  static bool _loaded = false;
  static bool get loaded => _loaded;

  static Future<void> load(ApiClient api) async {
    if (_loaded) return;
    try {
      apply(await api.getJson('/circle/media/limits'));
      _loaded = true;
    } catch (e) {
      reportNonFatal('md1_limits', e); // defaults stay; the server re-checks
    }
  }

  /// PURE (tests): take the server's answer; anything missing / silly keeps
  /// the current value (never 0 = "nothing allowed" by a typo).
  static void apply(Map<String, dynamic> r) {
    int v(String k, int d) {
      final x = (r[k] as num?)?.toInt();
      return (x == null || x <= 0) ? d : x;
    }

    photo = v('photo_max_bytes', photo);
    voice = v('voice_max_bytes', voice);
    document = v('doc_max_bytes', document);
    video = v('video_max_bytes', video); // mc-media2
    photosPerSend = v('photos_per_send', photosPerSend);
    videoSeconds = v('video_max_seconds', videoSeconds);
    voiceSeconds = v('voice_max_seconds', voiceSeconds);
    videoHeight = v('video_height', videoHeight);
    viewOnceDays = v('view_once_days', viewOnceDays);
  }

  static int of(String kind) => kind == 'photo'
      ? photo
      : kind == 'voice'
          ? voice
          : kind == 'video'
              ? video
              : document;

  /// A video longer than this must be trimmed before it can be sent.
  static bool needsTrim(int? durationMs) =>
      durationMs != null && durationMs > videoSeconds * 1000 + 500;

  /// The video bitrate (bits/s) that keeps [seconds] of 720p under the
  /// [video] cap with 10 % headroom and 64 kb/s of audio; 2.5 Mb/s at most
  /// (plenty for 720p on a phone screen), 350 kb/s at least.
  static int videoBitrateFor(int seconds) {
    final s = seconds <= 0 ? 1 : seconds;
    final budget = (video * 8 * 0.90) ~/ s - 64000;
    return budget.clamp(350000, 2500000);
  }

  /// Tests only.
  static void resetForTest() {
    photo = 16 * _mb;
    voice = 16 * _mb;
    document = 100 * _mb;
    video = 25 * _mb;
    photosPerSend = 30;
    videoSeconds = 180;
    voiceSeconds = 900;
    videoHeight = 720;
    viewOnceDays = 14;
    _loaded = false;
  }
}
