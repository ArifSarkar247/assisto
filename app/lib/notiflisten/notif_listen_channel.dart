import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api.dart';

/// callmoney — Dart side of "com.assisto/notif_listen" (native:
/// android_overlay/.../notiflisten/). Every call is guarded and answers a
/// safe default (tests / iOS / an old build without the channel: "not
/// available", never a crash).
class NotifListenStatus {
  final bool available; // the native listener exists on this phone/build
  final bool granted; // Android "Notification access" is on for Assisto
  final bool callNote;
  final bool money;
  final bool moneyAuto;
  const NotifListenStatus({
    this.available = false,
    this.granted = false,
    this.callNote = false,
    this.money = false,
    this.moneyAuto = false,
  });
}

/// One allow-listed wallet/bank notification waiting on the phone.
class MoneyQueueItem {
  final int id;
  final String wallet;
  final String kind; // app | sms
  final String text;
  final DateTime at;
  const MoneyQueueItem(
      {required this.id, required this.wallet, required this.kind, required this.text, required this.at});
}

/// A tap on one of the two prompt notifications.
class NotifLaunch {
  final String kind; // callnote | money
  final String mode; // voice | type | income | expense | review
  final String source; // sim | whatsapp | messenger | wallet slug
  final int id;
  const NotifLaunch({required this.kind, required this.mode, required this.source, this.id = 0});
}

abstract class NotifListenBridge {
  Future<NotifListenStatus> status();
  Future<void> openAccessSettings();
  Future<void> setConfig(
      {required bool callNote,
      required bool money,
      required bool moneyAuto,
      required String lang,
      required Map<String, String> strings});
  Future<List<MoneyQueueItem>> takeMoneyQueue();
  Future<void> moneyDone(List<int> ids);
  Future<NotifLaunch?> takeLaunch();
}

class NotifListenChannel implements NotifListenBridge {
  static const _ch = MethodChannel('com.assisto/notif_listen');

  /// The bridge every screen uses; tests swap in a fake.
  static NotifListenBridge instance = NotifListenChannel();

  bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<NotifListenStatus> status() async {
    if (!_android) return const NotifListenStatus();
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('status');
      if (m == null) return const NotifListenStatus();
      return NotifListenStatus(
        available: true,
        granted: m['granted'] == true,
        callNote: m['callnote'] == true,
        money: m['money'] == true,
        moneyAuto: m['moneyAuto'] == true,
      );
    } catch (_) {
      return const NotifListenStatus(); // no channel in this build
    }
  }

  @override
  Future<void> openAccessSettings() async {
    try {
      await _ch.invokeMethod('openAccessSettings');
    } catch (_) {} // best-effort: no Settings screen on this phone: the UI explains the path
  }

  @override
  Future<void> setConfig(
      {required bool callNote,
      required bool money,
      required bool moneyAuto,
      required String lang,
      required Map<String, String> strings}) async {
    try {
      await _ch.invokeMethod('setConfig', {
        'callnote': callNote,
        'money': money,
        'moneyAuto': moneyAuto,
        'lang': lang,
        'strings': strings,
      });
    } catch (_) {} // best-effort: native missing: the switches still show the honest status
  }

  @override
  Future<List<MoneyQueueItem>> takeMoneyQueue() async {
    if (!_android) return const [];
    try {
      final l = await _ch.invokeListMethod<dynamic>('takeMoneyQueue') ?? const [];
      return [
        for (final e in l)
          if (e is Map)
            MoneyQueueItem(
              id: (e['id'] as num?)?.toInt() ?? 0,
              wallet: '${e['wallet'] ?? 'bank'}',
              kind: '${e['kind'] ?? 'app'}',
              text: '${e['text'] ?? ''}',
              at: DateTime.fromMillisecondsSinceEpoch((e['at'] as num?)?.toInt() ?? 0),
            )
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<void> moneyDone(List<int> ids) async {
    try {
      await _ch.invokeMethod('moneyDone', {'ids': ids});
    } catch (_) {} // best-effort: nothing queued natively
  }

  @override
  Future<NotifLaunch?> takeLaunch() async {
    if (!_android) return null;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('takeLaunch');
      if (m == null || m['kind'] == null) return null;
      return NotifLaunch(
        kind: '${m['kind']}',
        mode: '${m['mode'] ?? ''}',
        source: '${m['source'] ?? ''}',
        id: (m['id'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// POST /callnote/understand -> {ok, items} or {ok:false, reason, detail}.
extension CallNoteApi on ApiClient {
  Future<Map<String, dynamic>> callNoteUnderstand(String text, String now) =>
      postJsonRaw('/callnote/understand', {'text': text, 'now': now});
}
