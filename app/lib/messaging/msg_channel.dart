import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// circlebub (owner 3 Nov 16:30, part C) — the My Circle message channel.
///
/// Android never lets an app change a channel's sound after it exists, so
/// Assisto's own "pop" (res/raw/assisto_pop.wav, composed by
/// tool/sounds/make_msg_sounds.py) needs a NEW channel id. Users of the old
/// 'messages' channel are migrated ONCE: their importance (muted / silent /
/// normal) and vibration choice are read from the old channel, copied onto
/// the new one, and only then is the old channel deleted (never recreated —
/// Android would restore a deleted id with its old settings).
///
/// The SAME rules live in Kotlin (messaging/MessageNotifier.kt
/// `migrateChannel`) for the native safety-net notification; keep in step.
/// A picked custom sound keeps its 'messages_<hash>' channel and "silent"
/// keeps 'messages_silent' (unchanged).
class MsgChannel {
  MsgChannel._();

  /// The default message channel (Assisto pop).
  static const id = 'chat_msg_v2';

  /// The pre-circlebub default channel (phone default sound) — deleted.
  static const legacyId = 'messages';

  /// res/raw names (kept from shrinking by res/raw/assisto_keep.xml).
  static const sound = 'assisto_pop';
  static const tick = 'assisto_tick';

  /// Is this one of OUR message channels (default, silent, picked sound)?
  static bool isMessageChannel(String id) =>
      id == MsgChannel.id || id == legacyId || id.startsWith('messages_');

  /// The new channel, carrying over the user's choices from [old] (null = a
  /// fresh install / already migrated → Assisto's defaults).
  static AndroidNotificationChannel channelFor(
      {required String name,
      required String description,
      AndroidNotificationChannel? old}) {
    final playSound = old?.playSound ?? true;
    return AndroidNotificationChannel(
      id,
      name,
      description: description,
      // a muted (none / min / low) old channel stays muted
      importance: old?.importance ?? Importance.high,
      enableVibration: old?.enableVibration ?? true,
      playSound: playSound,
      sound: playSound
          ? const RawResourceAndroidNotificationSound(sound)
          : null,
    );
  }

  /// What a migration must do, given the channels on the phone (pure, so
  /// CI can check every case).
  static MsgChannelPlan plan(List<AndroidNotificationChannel> existing) {
    AndroidNotificationChannel? find(String i) {
      for (final c in existing) {
        if (c.id == i) return c;
      }
      return null;
    }

    final old = find(legacyId);
    final now = find(id);
    return MsgChannelPlan(
      create: now == null,
      carryFrom: now == null ? old : null,
      deleteLegacy: old != null,
    );
  }

  static String? _ready;
  @visibleForTesting
  static void resetForTest() => _ready = null;

  /// Create the channel (migrating once) — any isolate; never throws.
  /// Order: read old → create new (with old choices) → delete old.
  static Future<String> ensure(AndroidFlutterLocalNotificationsPlugin? a,
      {required String name, required String description}) async {
    if (a == null) return id;
    if (_ready == name) return id; // once per isolate + language
    try {
      final chs = await a.getNotificationChannels() ?? const [];
      final p = plan(chs);
      if (p.create) {
        await a.createNotificationChannel(
            channelFor(name: name, description: description, old: p.carryFrom));
      } else {
        // refresh name / description only (Android keeps user settings)
        await a.createNotificationChannel(
            channelFor(name: name, description: description));
      }
      if (p.deleteLegacy) await a.deleteNotificationChannel(legacyId);
      _ready = name;
    } catch (e) {
      if (kDebugMode) debugPrint('msg channel: $e');
    }
    return id;
  }
}

@immutable
class MsgChannelPlan {
  const MsgChannelPlan(
      {required this.create, required this.carryFrom, required this.deleteLegacy});

  /// The new channel does not exist yet.
  final bool create;

  /// The old channel whose importance / vibration / sound-on to copy.
  final AndroidNotificationChannel? carryFrom;

  /// The old 'messages' channel is still there → delete it after creating.
  final bool deleteLegacy;
}
