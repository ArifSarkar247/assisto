import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../screens/circle_chat_screen.dart';
import '../screens/circle_group_chat_screen.dart';
import '../screens/messenger/messenger_home_screen.dart';
import 'msg_notify.dart';

/// c3-msg — open ONE specific chat (notification tap, bubble, conversation
/// shortcut). Falls back to the My Circle hub when the chat or the on-device
/// key can't be resolved (honest, never a dead tap).
class ChatOpener {
  ChatOpener._();

  /// "member:12" / "group:3" → (kind, id).
  static ({String kind, int id})? parse(String? key) {
    if (key == null) return null;
    final i = key.indexOf(':');
    if (i <= 0) return null;
    final id = int.tryParse(key.substring(i + 1));
    if (id == null) return null;
    return (kind: key.substring(0, i) == 'group' ? 'group' : 'member', id: id);
  }

  static Future<void> open(NavigatorState nav, ApiClient api, String kind, int id) async {
    try {
      final identity = await loadStoredIdentity()
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
      if (identity == null) throw StateError('no identity');
      if (kind == 'group') {
        final g = await api.getJson('/circle/groups/$id');
        nav.push(MaterialPageRoute(
            builder: (_) => CircleGroupChatScreen(group: g, identity: identity)));
        return;
      }
      final r = await api.getJson('/circle/members');
      final list = ((r['results'] ?? r['members'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>());
      final member = list.firstWhere((m) => '${m['id']}' == '$id');
      nav.push(MaterialPageRoute(
          builder: (_) => CircleChatScreen(member: member, identity: identity)));
    } catch (_) {
      nav.push(MaterialPageRoute(builder: (_) => const MessengerHomeScreen()));
    }
  }
}
