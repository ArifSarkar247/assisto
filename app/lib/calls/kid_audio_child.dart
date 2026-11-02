import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../api.dart';
import '../feature_flags.dart';
import '../kid_audio_api.dart';
import '../l10n/app_localizations.dart';
import '../push/push_service.dart' show appNavigatorKey;
import '../screens/circle_call_screen.dart';
import '../services/journey_tracker.dart' show kServiceOwnKey;
import '../state.dart' show Settings;
import '../widgets/voice_sos_service.dart' show kVoiceSosStopButton;
import 'call_keepalive.dart';
import 'call_log.dart';

/// kidaudio (owner 2 Nov PART 1 b): the CHILD's phone side of emergency audio.
///
/// THE CONTRACT (tests: app/test/kid_audio_test.dart + backend
/// core/tests_kidaudio.py):
///  1. the server granted a session (active emergency, verified parent,
///     under-18 confirmed, consent by both) — this phone only ASKS;
///  2. the VISIBLE foreground notification "জরুরি অবস্থায় বাবা/মা শুনছেন"
///     + Stop goes up FIRST (the existing call keep-alive service; when voice
///     SOS already runs that service, its notification is switched to our
///     text). If it cannot be shown, nothing else happens: the server is told
///     notice_shown=false and ends the session — NO silent mic path;
///  3. only then the ordinary Circle voice call to the parent opens (the
///     existing calls / WebRTC stack, the call screen ON DISPLAY, audio via
///     AudioRouteService like every call);
///  4. the server ends the call at 3 minutes; Stop on the notification hangs
///     up at once.
/// Honest limit: Android 11+ does not let an app turn the microphone on from
/// the background, so this runs when Assisto is open / resumed (an SOS
/// screen usually is) or after one tap on the "Emergency" notification.
class KidAudioNoticeText {
  const KidAudioNoticeText({required this.channel, required this.title,
      required this.text, required this.stop, this.voiceStop = 'Stop',
      this.restoreTitle = '', this.restoreText = ''});
  final String channel;
  final String title;
  final String text;
  final String stop;

  /// The voice-SOS service's own Stop (kept when that service carries ours).
  final String voiceStop;

  /// What a borrowed notification says after the session.
  final String restoreTitle;
  final String restoreText;

  static KidAudioNoticeText of(AppLocalizations t, String guardianName) =>
      KidAudioNoticeText(
          channel: t.kauNoticeChannel,
          title: t.kauNoticeTitle,
          text: t.kauNoticeText(guardianName),
          stop: t.kauStop,
          voiceStop: t.vaStop,
          restoreTitle: t.kauNoticeRestoreTitle,
          restoreText: t.kauNoticeRestoreText);

  bool get valid => title.trim().isNotEmpty && stop.trim().isNotEmpty;
}

class KidAudioNotice {
  KidAudioNotice._();

  /// Show the foreground notification with our Stop. true only when it is
  /// really up. If voice SOS / Safe Journey already runs the (single)
  /// foreground service, ITS notification carries our text + Stop for the
  /// session (both task handlers forward the Stop) and is put back after.
  static Future<bool> show(KidAudioNoticeText n, Future<void> Function() onStop) async {
    if (!n.valid) return false;
    try {
      await CallKeepAlive.start(
          channelName: n.channel, title: n.title, text: n.text,
          hangupLabel: n.stop, onHangup: onStop);
      if (CallKeepAlive.isOurs) return true;
      if (!await FlutterForegroundTask.isRunningService) return false;
      final journey = await Settings.getBool(kServiceOwnKey, false);
      final keep = <NotificationButton>[
        if (!journey) NotificationButton(id: kVoiceSosStopButton, text: n.voiceStop),
      ];
      final r = await FlutterForegroundTask.updateService(
          notificationTitle: n.title,
          notificationText: n.text,
          notificationButtons: [
            ...keep,
            NotificationButton(id: kCallHangupButton, text: n.stop),
          ]);
      if (r is! ServiceRequestSuccess) return false;
      CallKeepAlive.listenHangup(onStop, () async {
        await FlutterForegroundTask.updateService(
            notificationTitle: n.restoreTitle,
            notificationText: n.restoreText,
            notificationButtons: keep);
      });
      return true;
    } catch (e) {
      callLog('kidaudio#notice', e);
    }
    return false;
  }
}

class KidAudioChild {
  KidAudioChild._();

  static bool _busy = false;
  static int? _lastSession;

  /// Test seams.
  @visibleForTesting
  static Future<bool> Function(KidAudioNoticeText n, Future<void> Function() onStop)
      showNotice = KidAudioNotice.show;
  @visibleForTesting
  static Future<void> Function(Map<String, dynamic> member) openCall = _openCallScreen;

  static Future<void> _openCallScreen(Map<String, dynamic> member) async {
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => CircleCallScreen(member: member, kind: 'voice'))));
  }

  /// On open / resume / the "listen" push. Cheap no-op when the flag is off.
  static Future<void> maybeStart(ApiClient api) async {
    if (api.token == null || !FeatureFlags.instance.isOn('child_emergency_audio')) return;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    final t = AppLocalizations.of(ctx);
    await run(
        fetchPending: api.kauPending,
        postEvent: api.kauEvent,
        texts: (name) => KidAudioNoticeText.of(t, name));
  }

  /// The whole child-side flow, testable without a phone. Returns what
  /// happened: none | notice_failed | refused | started.
  static Future<String> run({
    required Future<Map<String, dynamic>> Function() fetchPending,
    required Future<Map<String, dynamic>> Function(int id, Map<String, dynamic> body) postEvent,
    required KidAudioNoticeText Function(String guardianName) texts,
  }) async {
    if (_busy) return 'none';
    _busy = true;
    try {
      final r = await fetchPending();
      final p = r['pending'];
      if (p is! Map) return 'none';
      final id = p['id'];
      final memberId = p['member_id'];
      if (id is! int || memberId is! int || id == _lastSession) return 'none';
      _lastSession = id;
      final name = '${p['guardian_name'] ?? ''}';
      Future<void> stop() async {
        try {
          await postEvent(id, {'event': 'stop'});
        } catch (_) {}
        await CallKeepAlive.stop();
      }

      // 1) the visible notice FIRST
      final shown = await showNotice(texts(name), stop);
      if (!shown) {
        await postEvent(id, {'event': 'started', 'notice_shown': false});
        return 'notice_failed';
      }
      // 2) the server re-checks everything (emergency may be over)
      final s = await postEvent(id, {'event': 'started', 'notice_shown': true});
      if (s['ok'] != true) {
        await CallKeepAlive.stop();
        return 'refused';
      }
      // 3) an ordinary, visible Circle voice call to the parent
      await openCall({'id': memberId, 'name': name});
      return 'started';
    } catch (e) {
      callLog('kidaudio#run', e);
      return 'none';
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _busy = false;
    _lastSession = null;
  }
}
