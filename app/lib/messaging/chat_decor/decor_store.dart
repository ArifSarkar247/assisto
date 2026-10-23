// cde-chat (order 6 D + E) — this phone's copy of every chat's THEME and
// NICKNAMES. Fed by (a) E2E control messages as they arrive, (b) the server
// copy (GET circle/decor/..., member payload fields) for a reinstall / second
// phone. Newest write wins by the SERVER timestamp both carry, so the order in
// which a phone learns about changes never matters. Survives app restarts
// (SharedPreferences). Lazy: nothing is read at app launch.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/error_report.dart';
import '../media/media_descriptor.dart';

/// Nickname slots: 1:1 chats use 'peer' / 'me'; groups use 'u<user id>'.
String groupSlot(int uid) => 'u$uid';

@immutable
class ChatDecorState {
  final String themeId; // 'classic' = none
  final int themeAt;
  final Map<String, dynamic>? photoDesc; // md1 descriptor JSON (receiver)
  final String photoPath; // my own picked copy (sender)
  final Map<String, String> nicks;
  final Map<String, int> nickAt;
  const ChatDecorState({
    this.themeId = 'classic',
    this.themeAt = 0,
    this.photoDesc,
    this.photoPath = '',
    this.nicks = const {},
    this.nickAt = const {},
  });

  static const empty = ChatDecorState();

  String nick(String slot) => nicks[slot] ?? '';

  MediaDescriptor? get photo =>
      photoDesc == null ? null : MediaDescriptor.tryParse(jsonEncode(photoDesc));

  ChatDecorState copyWith({
    String? themeId,
    int? themeAt,
    Map<String, dynamic>? photoDesc,
    bool clearPhoto = false,
    String? photoPath,
    Map<String, String>? nicks,
    Map<String, int>? nickAt,
  }) =>
      ChatDecorState(
        themeId: themeId ?? this.themeId,
        themeAt: themeAt ?? this.themeAt,
        photoDesc: clearPhoto ? null : (photoDesc ?? this.photoDesc),
        photoPath: clearPhoto ? (photoPath ?? '') : (photoPath ?? this.photoPath),
        nicks: nicks ?? this.nicks,
        nickAt: nickAt ?? this.nickAt,
      );

  Map<String, dynamic> toJson() => {
        'theme': themeId,
        'theme_at': themeAt,
        if (photoDesc != null) 'photo': photoDesc,
        if (photoPath.isNotEmpty) 'photo_path': photoPath,
        'nicks': nicks,
        'nick_at': nickAt,
      };

  static ChatDecorState fromJson(Map<String, dynamic> j) {
    int i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
    final n = <String, String>{};
    final na = <String, int>{};
    (j['nicks'] as Map?)?.forEach((k, v) => n['$k'] = '$v');
    (j['nick_at'] as Map?)?.forEach((k, v) => na['$k'] = i(v));
    return ChatDecorState(
      themeId: '${j['theme'] ?? 'classic'}',
      themeAt: i(j['theme_at']),
      photoDesc: (j['photo'] as Map?)?.cast<String, dynamic>(),
      photoPath: '${j['photo_path'] ?? ''}',
      nicks: n,
      nickAt: na,
    );
  }
}

class DecorStore {
  DecorStore._();
  static final DecorStore instance = DecorStore._();

  static const _prefix = 'cde_decor_v1:';

  final Map<String, ChatDecorState> _mem = {};
  final Set<String> _loaded = {};
  bool _allLoaded = false;

  /// Bumps on every change — the chat list / headers / call screen listen.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  ChatDecorState get(String chatKey) => _mem[chatKey] ?? ChatDecorState.empty;

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (e) {
      reportNonFatal('cde_prefs', e);
      return null;
    }
  }

  /// Read one chat's state from disk (once).
  Future<ChatDecorState> ensure(String chatKey) async {
    if (_loaded.contains(chatKey)) return get(chatKey);
    final p = await _prefs();
    _loaded.add(chatKey);
    final raw = p?.getString('$_prefix$chatKey');
    if (raw != null && !_mem.containsKey(chatKey)) {
      try {
        _mem[chatKey] = ChatDecorState.fromJson(
            (jsonDecode(raw) as Map).cast<String, dynamic>());
        revision.value++;
      } catch (e) {
        reportNonFatal('cde_decode', e);
      }
    }
    return get(chatKey);
  }

  /// Every chat's state (the chat list needs all nicknames).
  Future<void> loadAll() async {
    if (_allLoaded) return;
    final p = await _prefs();
    _allLoaded = true;
    if (p == null) return;
    var any = false;
    for (final k in p.getKeys()) {
      if (!k.startsWith(_prefix)) continue;
      final chat = k.substring(_prefix.length);
      if (_mem.containsKey(chat)) continue;
      try {
        _mem[chat] = ChatDecorState.fromJson(
            (jsonDecode(p.getString(k) ?? '{}') as Map).cast<String, dynamic>());
        _loaded.add(chat);
        any = true;
      } catch (_) {}
    }
    if (any) revision.value++;
  }

  Future<void> _save(String chatKey) async {
    revision.value++;
    final p = await _prefs();
    try {
      await p?.setString('$_prefix$chatKey', jsonEncode(get(chatKey).toJson()));
    } catch (e) {
      reportNonFatal('cde_save', e);
    }
  }

  /// A theme change (control message or server). [at] = server ms; an older
  /// change than the one we have is ignored. Returns true when applied.
  Future<bool> applyTheme(String chatKey, String id, int at,
      {Map<String, dynamic>? photoDesc, String? photoPath}) async {
    await ensure(chatKey);
    final cur = get(chatKey);
    if (at < cur.themeAt) return false;
    if (at == cur.themeAt && id == cur.themeId &&
        (photoDesc == null || mapEquals(photoDesc, cur.photoDesc)) &&
        (photoPath == null || photoPath == cur.photoPath)) {
      return false;
    }
    final photo = id == 'custom' || id == 'ai';
    final same = at == cur.themeAt;
    _mem[chatKey] = !photo
        ? cur.copyWith(themeId: id, themeAt: at, clearPhoto: true)
        : (same
            // the descriptor / my own copy for the change we already know
            ? cur.copyWith(themeId: id, photoDesc: photoDesc, photoPath: photoPath)
            // a NEWER photo theme: never keep showing the old picture (the
            // server-only copy has no photo; the E2E message brings it)
            : ChatDecorState(
                themeId: id,
                themeAt: at,
                photoDesc: photoDesc,
                photoPath: photoPath ?? '',
                nicks: cur.nicks,
                nickAt: cur.nickAt));
    await _save(chatKey);
    return true;
  }

  /// A nickname change; [name] '' = removed.
  Future<bool> applyNick(String chatKey, String slot, String name, int at) async {
    await ensure(chatKey);
    final cur = get(chatKey);
    final was = cur.nickAt[slot] ?? 0;
    if (at < was) return false;
    if (at == was && cur.nick(slot) == name) return false;
    final n = Map<String, String>.from(cur.nicks);
    final na = Map<String, int>.from(cur.nickAt)..[slot] = at;
    if (name.isEmpty) {
      n.remove(slot);
    } else {
      n[slot] = name;
    }
    _mem[chatKey] = cur.copyWith(nicks: n, nickAt: na);
    await _save(chatKey);
    return true;
  }

  /// GET circle/decor/member/<id> (or a POST answer).
  Future<void> adoptMemberServer(String chatKey, Map<String, dynamic> j) async {
    final th = (j['theme'] as Map?)?.cast<String, dynamic>();
    if (th != null) {
      await applyTheme(chatKey, '${th['id'] ?? 'classic'}', _i(th['at_ms']));
    }
    final at = (j['nick_at'] as Map?) ?? const {};
    if (j.containsKey('nick_peer')) {
      await applyNick(chatKey, 'peer', '${j['nick_peer'] ?? ''}', _i(at['peer']));
    }
    if (j.containsKey('nick_me')) {
      await applyNick(chatKey, 'me', '${j['nick_me'] ?? ''}', _i(at['me']));
    }
  }

  /// GET circle/decor/group/<id>.
  Future<void> adoptGroupServer(String chatKey, Map<String, dynamic> j) async {
    final th = (j['theme'] as Map?)?.cast<String, dynamic>();
    if (th != null) {
      await applyTheme(chatKey, '${th['id'] ?? 'classic'}', _i(th['at_ms']));
    }
    final names = (j['nicknames'] as Map?) ?? const {};
    final at = (j['nick_at'] as Map?) ?? const {};
    final cur = get(chatKey);
    final keys = {
      ...names.keys.map((k) => 'u$k'),
      ...cur.nicks.keys.where((k) => k.startsWith('u')),
    };
    for (final slot in keys) {
      final uid = slot.substring(1);
      final has = names.containsKey(uid);
      final stamp = _i(at[uid]);
      // a nickname the server no longer has was removed (its stamp is gone
      // with it, so only drop what we never saw a newer change for)
      if (!has && stamp == 0 && (cur.nickAt[slot] ?? 0) > 0) {
        continue;
      }
      await applyNick(chatKey, slot, has ? '${names[uid]}' : '', stamp);
    }
  }

  /// The member payload of a chat list / chat open (nickname fields).
  Future<void> adoptMemberPayload(String chatKey, Map<String, dynamic> m) async {
    if (m.containsKey('nickname')) {
      await applyNick(chatKey, 'peer', '${m['nickname'] ?? ''}', _i(m['nickname_at']));
    }
    if (m.containsKey('my_nickname')) {
      await applyNick(chatKey, 'me', '${m['my_nickname'] ?? ''}', _i(m['my_nickname_at']));
    }
  }

  /// What THIS phone shows for the other person of a 1:1 chat.
  String peerName(String chatKey, String realName) {
    final n = get(chatKey).nick('peer');
    return n.isNotEmpty ? n : realName;
  }

  static int _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

  @visibleForTesting
  void reset() {
    _mem.clear();
    _loaded.clear();
    _allLoaded = false;
    revision.value = 0;
  }
}
