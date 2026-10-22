import 'package:flutter/foundation.dart';

/// c3-msg — the ONE source of truth for unread counts on this phone: the chat
/// list rows, the My Circle tab badge and the app-icon badge source all read
/// it, so opening a chat clears all of them in the same frame (owner bug:
/// "10" stayed next to the name after reading everything).
///
/// App-icon badge: Android launchers badge from the app's ACTIVE
/// notifications; opening a chat cancels that chat's notification (see
/// FlnMsgSink.cancel), so the launcher badge drops at the same moment. No
/// badge plugin is needed (see .phaseB/proposals/c3-msg.md).
class UnreadStore {
  UnreadStore._();
  static final UnreadStore instance = UnreadStore._();

  final ValueNotifier<Map<String, int>> perChat =
      ValueNotifier<Map<String, int>>(const {});

  /// Sum across chats (tab badge / app badge source).
  final ValueNotifier<int> total = ValueNotifier<int>(0);

  /// Replace everything from a fresh /circle/chats load.
  void setAll(Map<String, int> counts) {
    perChat.value = Map.unmodifiable(counts);
    _sum();
  }

  int of(String key) => perChat.value[key] ?? 0;

  void set(String key, int n) {
    final m = Map<String, int>.from(perChat.value);
    if (n <= 0) {
      m.remove(key);
    } else {
      m[key] = n;
    }
    perChat.value = Map.unmodifiable(m);
    _sum();
  }

  /// "Read all" from the hub menu.
  void clearAll() => setAll(const {});

  /// Opening a chat / Mark as read.
  void clear(String key) => set(key, 0);

  void _sum() {
    var s = 0;
    for (final v in perChat.value.values) {
      s += v;
    }
    total.value = s;
  }

  @visibleForTesting
  void reset() {
    perChat.value = const {};
    total.value = 0;
  }
}
