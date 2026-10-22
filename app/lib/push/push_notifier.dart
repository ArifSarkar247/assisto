import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant, Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../calls/call_log.dart';
import '../calls/call_sound_prefs.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import 'push_payload.dart';
import '../messaging/msg_notify.dart';

/// Draws Assisto pushes as local notifications. Usable from the UI isolate AND
/// from the FCM background isolate (no BuildContext — strings come from
/// [lookupAppLocalizations] using the payload's `lang`). Every call is
/// guarded: a notification failure can never crash either isolate.
class PushNotifier {
  PushNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _bgInitDone = false;

  static const actionAccept = 'accept';
  static const actionDecline = 'decline';

  /// Android FLAG_INSISTENT: repeat the ringtone until answered/cancelled.
  static const _flagInsistent = 4;

  static AppLocalizations _t(String lang) {
    try {
      return lookupAppLocalizations(Locale(lang == 'en' ? 'en' : 'bn'));
    } catch (_) {
      return lookupAppLocalizations(const Locale('en'));
    }
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// The five channels the backend targets (push.CHANNELS). Creating an
  /// existing channel only refreshes its name/description, so this is safe to
  /// call on every language change.
  static List<AndroidNotificationChannel> channels(String lang) {
    final t = _t(lang);
    return [
      AndroidNotificationChannel(PushChannels.messages, t.pushChMessages,
          description: t.pushChMessagesDesc, importance: Importance.high),
      AndroidNotificationChannel(PushChannels.calls, t.pushChCalls,
          description: t.pushChCallsDesc,
          importance: Importance.max,
          sound: const UriAndroidNotificationSound(
              'content://settings/system/ringtone'),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone),
      // c2-calls: quiet-ish "Missed call" (default notification sound).
      AndroidNotificationChannel(PushChannels.missedCalls, t.c2ChMissedCalls,
          description: t.c2ChMissedCallsDesc, importance: Importance.high),
      AndroidNotificationChannel(PushChannels.reminders, t.pushChReminders,
          description: t.pushChRemindersDesc, importance: Importance.high),
      AndroidNotificationChannel(PushChannels.alerts, t.pushChAlerts,
          description: t.pushChAlertsDesc, importance: Importance.high),
      AndroidNotificationChannel(PushChannels.sos, t.pushChSos,
          description: t.pushChSosDesc,
          importance: Importance.max,
          audioAttributesUsage: AudioAttributesUsage.alarm),
    ];
  }

  static Future<void> createChannels(String lang) async {
    try {
      final a = _android;
      if (a == null) return;
      for (final c in channels(lang)) {
        await a.createNotificationChannel(c);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('push channels failed: $e');
    }
  }

  /// Notification details for one payload (pure apart from the strings).
  /// c2-calls: the ringing channel for a chosen ringtone ([ringtoneUri]
  /// null = the phone's default ringtone, channel 'calls').
  static AndroidNotificationChannel callChannel(String lang, String? ringtoneUri) {
    final t = _t(lang);
    return AndroidNotificationChannel(
        CallSoundPrefs.channelIdFor(ringtoneUri), t.pushChCalls,
        description: t.pushChCallsDesc,
        importance: Importance.max,
        sound: UriAndroidNotificationSound(
            ringtoneUri ?? 'content://settings/system/ringtone'),
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone);
  }

  static NotificationDetails detailsFor(PushPayload p, {String? ringtoneUri}) {
    final t = _t(p.lang);
    final ch = channels(p.lang).firstWhere((c) => c.id == p.channel,
        orElse: () => channels(p.lang).first);
    if (p.isMissedCall) {
      return NotificationDetails(
        android: AndroidNotificationDetails(ch.id, ch.name,
            channelDescription: ch.description,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.missedCall,
            autoCancel: true),
      );
    }
    if (p.isCall) {
      final cc = callChannel(p.lang, ringtoneUri);
      return NotificationDetails(
        android: AndroidNotificationDetails(cc.id, cc.name,
            channelDescription: cc.description,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            sound: cc.sound,
            audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            // the backend TTL for a ring is 30 s; stop ringing a bit later
            timeoutAfter: 45000,
            visibility: NotificationVisibility.public,
            additionalFlags: Int32List.fromList(const [_flagInsistent]),
            actions: [
              AndroidNotificationAction(actionDecline, t.pushCallDecline,
                  cancelNotification: true, showsUserInterface: false),
              AndroidNotificationAction(actionAccept, t.pushCallAccept,
                  cancelNotification: true, showsUserInterface: true),
            ]),
      );
    }
    if (p.isSos) {
      return NotificationDetails(
        android: AndroidNotificationDetails(ch.id, ch.name,
            channelDescription: ch.description,
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            audioAttributesUsage: AudioAttributesUsage.alarm,
            fullScreenIntent: !p.silent,
            visibility: NotificationVisibility.public),
      );
    }
    return NotificationDetails(
      android: AndroidNotificationDetails(ch.id, ch.name,
          channelDescription: ch.description,
          importance: ch.importance,
          priority: Priority.high,
          category: p.kind == 'message'
              ? AndroidNotificationCategory.message
              : (p.kind == 'reminder'
                  ? AndroidNotificationCategory.reminder
                  : null)),
    );
  }

  static String titleFor(PushPayload p) {
    if (p.title.isNotEmpty) return p.title;
    final t = _t(p.lang);
    if (p.isCall) {
      return p.isVideo ? t.pushIncomingVideo : t.pushIncomingVoice;
    }
    return 'Assisto';
  }

  /// Show [p] (or, for `call_cancel`, dismiss the ring it refers to).
  static Future<void> show(PushPayload p) async {
    try {
      if (p.isCallCancel) {
        await _plugin.cancel(p.notificationId);
        return;
      }
      if (!p.isKnownKind) return;
      String? ring;
      if (p.isCall) {
        // c2-calls: tell the caller this phone is REALLY ringing, and ring
        // with the chosen (per-contact / Assisto / picked) ringtone.
        unawaited(ackRinging(p.callId));
        ring = await CallSoundPrefs.ringtoneFor(p.chatId);
        if (ring != null) {
          try {
            await _android?.createNotificationChannel(callChannel(p.lang, ring));
          } catch (_) {
            ring = null;
          }
        }
      }
      await _plugin.show(p.notificationId, titleFor(p),
          p.body.isEmpty ? null : p.body, detailsFor(p, ringtoneUri: ring),
          payload: p.encode());
    } catch (e) {
      if (kDebugMode) debugPrint('push show failed: $e');
    }
  }

  /// Background-isolate entry: initialise the plugin once (no permission
  /// prompts here), make sure channels exist, then draw.
  static Future<void> showFromBackground(Map<String, dynamic> data) async {
    try {
      final p = PushPayload.fromData(data);
      if (!_bgInitDone) {
        await _plugin.initialize(
          const InitializationSettings(
              android: AndroidInitializationSettings('@mipmap/ic_launcher')),
          onDidReceiveBackgroundNotificationResponse:
              assistoNotificationBackground,
        );
        await createChannels(p.lang);
        _bgInitDone = true;
      }
      await show(p);
    } catch (e) {
      if (kDebugMode) debugPrint('push bg failed: $e');
    }
  }

  /// c3-msg: background message push → MessagingStyle (see
  /// messaging/msg_notify.dart). False = not drawn (caller falls back).
  static Future<bool> showMessageFromBackground(Map<String, dynamic> data) async {
    try {
      final p = PushPayload.fromData(data);
      await _ensureBgInit(p.lang);
      final h = await backgroundMsgHandler(lang: p.lang);
      if (h == null) return false;
      return await h.onPush(p);
    } catch (_) {
      return false;
    }
  }

  static Future<void> _ensureBgInit(String lang) async {
    if (_bgInitDone) return;
    await _plugin.initialize(
      const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveBackgroundNotificationResponse: assistoNotificationBackground,
    );
    await createChannels(lang);
    _bgInitDone = true;
  }

  static Future<void> cancelCall(String callId) async {
    try {
      await _plugin.cancel(
          PushPayload({'kind': 'call', 'call_id': callId}).notificationId);
    } catch (e) {
      callLog('push_notifier#call1', e);
    }
  }

  /// Android 14+: is the full-screen-intent permission granted? Asking
  /// opens the system page (there is no runtime dialog). Returns null when
  /// the platform can't tell us.
  static Future<bool?> requestFullScreenIntent() async {
    try {
      return await _android?.requestFullScreenIntentPermission();
    } catch (_) {
      return null;
    }
  }

  /// c2-calls: "this phone is ringing" (best effort; own HTTP client so it
  /// works from the FCM background isolate). Only after this does the caller
  /// see "Ringing…" and hear ringback.
  static Future<void> ackRinging(String callId, {String? token}) =>
      _callEvent(callId, 'ringing', token: token);

  static Future<void> _callEvent(String callId, String event,
      {String? token}) async {
    if (callId.isEmpty) return;
    try {
      token ??= await const FlutterSecureStorage().read(key: 'token');
      if (token == null || token.isEmpty) return;
      await http
          .post(AppConfig.api('/circle/calls/$callId/event'),
              headers: {
                'Authorization': 'Token $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'event': event}))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      callLog('push_notifier#call2', e);
    }
  }

  /// Decline a ringing call on the server (best effort, own HTTP client so it
  /// also works from the notification-action background isolate).
  static Future<void> declineCall(String callId, {String? token}) async {
    if (callId.isEmpty) return;
    try {
      token ??= await const FlutterSecureStorage().read(key: 'token');
      if (token == null || token.isEmpty) return;
      await http
          .post(AppConfig.api('/circle/calls/$callId/event'),
              headers: {
                'Authorization': 'Token $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'event': 'decline'}))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      callLog('push_notifier#call3', e);
    }
  }
}

/// Notification ACTION tapped while the app is not running (Decline has
/// showsUserInterface:false so it lands here without opening the app).
@pragma('vm:entry-point')
void assistoNotificationBackground(NotificationResponse r) {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
  } catch (e) {
    callLog('push_notifier#call4', e);
  }
  // c3-msg: inline reply / mark as read (encrypt + send from this isolate).
  if (r.actionId == kActionReply || r.actionId == kActionRead) {
    unawaited(handleMsgNotificationAction(r));
    return;
  }
  final p = PushPayload.decode(r.payload);
  if (p == null) return;
  if (r.actionId == PushNotifier.actionDecline && p.isCall) {
    unawaited(PushNotifier.declineCall(p.callId));
    unawaited(PushNotifier.cancelCall(p.callId));
  }
}
