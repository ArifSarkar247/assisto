// cde-chat (order 6 D + E) — one chat's theme + nicknames: the logic the 1:1
// and group screens share. The screens draw; this class talks to the server,
// the DecorStore and the media outbox.
//
// Order of every change (theme or nickname):
//   1. POST the server copy (enforces Free/Premium, cleans the nickname,
//      returns the server time `at_ms`),
//   2. apply it on this phone at once (DecorStore),
//   3. the screen sends the E2E control message carrying the same `at` —
//      the other phone applies it the moment it arrives.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../api.dart';
import '../../photo_studio/ps_backend.dart';
import '../../photo_studio/ps_models.dart';
import '../../services/error_report.dart';
import '../media/media_descriptor.dart';
import '../media/media_outbox.dart';
import '../media/media_prep.dart';
import '../media/media_store.dart';
import 'chat_control.dart';
import 'chat_themes.dart';
import 'decor_api.dart';
import 'decor_store.dart';

/// A refused / failed change, with the server's own sentence when it gave one.
class DecorFailure implements Exception {
  final bool premium; // the plan doesn't include it -> show the plans
  final String message;
  const DecorFailure({this.premium = false, this.message = ''});
}

/// The AI-theme offer (null = not available: no image provider key, not
/// fundable right now — the entry is then hidden, never "coming soon").
class AiThemeOffer {
  final FundingOption option;
  const AiThemeOffer(this.option);
  int get credits => option.credits;
}

class DecorChat {
  DecorChat({
    required this.api,
    required this.chatKey,
    required this.chatId,
    required this.group,
    DecorStore? store,
    PsBackend? ps,
  })  : store = store ?? DecorStore.instance,
        _ps = ps;

  final ApiClient api;
  final String chatKey; // member:<edge id> | group:<id>
  final int chatId;
  final bool group;
  final DecorStore store;
  PsBackend? _ps;
  PsBackend get ps => _ps ??= ApiPsBackend(api);

  bool premium = false;
  bool _loadedServer = false;
  final Set<String> _seen = {}; // message ids already folded in

  ChatDecorState get state => store.get(chatKey);
  ChatThemeDef? get themeDef => chatThemeById(state.themeId);

  /// Local copy first (instant), then the server copy (reinstall / 2nd phone).
  Future<void> load() async {
    await store.ensure(chatKey);
    try {
      final j = group ? await api.decorGroup(chatId) : await api.decorMember(chatId);
      _adopt(j);
    } catch (e) {
      // offline: the local copy stands; the next open retries
    }
  }

  void _adopt(Map<String, dynamic> j) {
    premium = j['premium'] == true;
    _loadedServer = true;
    unawaited(group ? store.adoptGroupServer(chatKey, j) : store.adoptMemberServer(chatKey, j));
  }

  bool get serverKnown => _loadedServer;

  // ------------------------------------------------------------ incoming
  /// Fold one decrypted control message into this chat (any order, any
  /// number of times — the newest `at` wins).
  Future<bool> fold(String messageId, ChatControl c,
      {required bool mine, MediaDescriptor? photo}) async {
    if (c.isTimer) return false; // e-gaps: the screen owns the timer
    final key = '$messageId|${c.at}';
    if (_seen.contains(key)) return false;
    _seen.add(key);
    if (c.isTheme) {
      if (c.themeId == 'custom' || c.themeId == 'ai') {
        if (photo == null) return false;
        final ok = await store.applyTheme(chatKey, c.themeId, c.at, photoDesc: photo.toJson());
        unawaited(_fetchPhoto(photo));
        return ok;
      }
      return store.applyTheme(chatKey, c.themeId, c.at);
    }
    final slot = c.uid != null
        ? groupSlot(c.uid!)
        : (mine ? (c.who == 'sender' ? 'me' : 'peer') : (c.who == 'sender' ? 'peer' : 'me'));
    return store.applyNick(chatKey, slot, c.name, c.at);
  }

  /// The wallpaper photo on this phone (my own copy, or the received one
  /// once downloaded + decrypted). null = not here (yet).
  File? photoFile() {
    final s = state;
    if (s.photoPath.isNotEmpty) {
      final f = File(s.photoPath);
      if (f.existsSync()) return f;
    }
    final d = s.photo;
    if (d == null) return null;
    final f = MediaCache.instance.cachedSync(d);
    if (f == null) unawaited(_fetchPhoto(d));
    return f;
  }

  bool _fetching = false;
  Future<void> _fetchPhoto(MediaDescriptor d) async {
    if (_fetching || MediaCache.instance.cachedSync(d) != null) return;
    _fetching = true;
    try {
      final f = await MediaCache.instance.fetch(d);
      if (f != null) store.revision.value++;
    } catch (e) {
      reportNonFatal('cde_photo_fetch', e);
    } finally {
      _fetching = false;
    }
  }

  // ------------------------------------------------------------ outgoing
  Future<Map<String, dynamic>> _post(Future<Map<String, dynamic>> Function() call) async {
    try {
      final j = await call();
      _adopt(j);
      return j;
    } on ApiException catch (e) {
      if (e.status == 402) {
        premium = false;
        throw DecorFailure(premium: true, message: e.message);
      }
      throw DecorFailure(message: e.message);
    } catch (e) {
      throw const DecorFailure();
    }
  }

  static int _at(Map<String, dynamic> j) =>
      (j['at_ms'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;

  /// A preset theme. Returns the control to send in the chat.
  Future<ChatControl> setPreset(String id) async {
    final j = await _post(() => group ? api.setGroupTheme(chatId, id) : api.setMemberTheme(chatId, id));
    final at = _at(j);
    await store.applyTheme(chatKey, id, at);
    return ChatControl.theme(id, at: at);
  }

  /// A nickname ('' = remove). 1:1: [slot] 'peer' | 'me'; group: [uid].
  Future<ChatControl> setNick({String slot = '', int? uid, required String name}) async {
    final j = await _post(() => group
        ? api.setGroupNick(chatId, uid!, name)
        : api.setMemberNick(chatId, slot, name));
    final at = _at(j);
    // the server's cleaned nickname is the one everybody sees
    String clean = name;
    if (group) {
      clean = '${(j['nicknames'] as Map?)?['$uid'] ?? ''}';
    } else {
      clean = '${j[slot == 'peer' ? 'nick_peer' : 'nick_me'] ?? name}';
    }
    await store.applyNick(chatKey, group ? groupSlot(uid!) : slot, clean, at);
    return group
        ? ChatControl.nick(uid: uid, name: clean, at: at)
        : ChatControl.nick(who: slot == 'me' ? 'sender' : 'recipient', name: clean, at: at);
  }

  /// A photo theme (my photo, or the AI picture): server copy, my own local
  /// wallpaper at once, then the E2E photo message through the media outbox.
  Future<MediaJob> setPhoto(MediaDraft d, {String id = 'custom'}) async {
    final j = await _post(() => group ? api.setGroupTheme(chatId, id) : api.setMemberTheme(chatId, id));
    final at = _at(j);
    // my own copy for my wallpaper (the outbox moves its copy into the cache)
    final dir = await MediaDirs.sub('decor');
    final safe = chatKey.replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final mine = File('${dir.path}/${safe}_$at.${d.path.split('.').last}');
    await File(d.path).copy(mine.path);
    await store.applyTheme(chatKey, id, at, photoPath: mine.path);
    final job = MediaJob(
      id: newMediaId(),
      chatKind: group ? 'group' : 'member',
      chatId: chatId,
      kind: 'photo',
      srcPath: d.path,
      name: d.name,
      mime: d.mime,
      plainSize: d.size,
      at: DateTime.now(),
      width: d.width,
      height: d.height,
      thumbB64: d.thumbB64,
      control: ChatControl.theme(id, at: at).toJson(),
    );
    await MediaOutbox.instance.add(job);
    return job;
  }

  // ------------------------------------------------------------ AI theme
  /// Is the AI theme offered right now? Hidden unless an image provider key
  /// is connected AND `generate` is fundable for this user (Premium pool /
  /// credits). Never throws.
  Future<AiThemeOffer?> aiOffer() async {
    try {
      final cfg = await ps.config().timeout(const Duration(seconds: 6));
      if (!cfg.providerReady) return null;
      final q = cfg.quote(PsFeature.generate);
      if (!q.ok) return null;
      final opt = q.credits;
      if (opt == null) return null;
      return AiThemeOffer(opt);
    } catch (_) {
      return null;
    }
  }

  /// Make the AI picture through Photo Studio (credits / Premium pool,
  /// Profit Guard, safety rules, Face Lock) and return it as a photo draft.
  Future<MediaDraft> makeAiPicture(String prompt, AiThemeOffer offer) async {
    final p = prompt.trim();
    final made = await ps.createJob({
      'feature': PsFeature.generate.wire,
      'prompt': 'Phone chat wallpaper, portrait 9:16, soft and calm, no text, '
          'no people, no faces: $p',
      'via': offer.option.via,
      'own_photo': true,
    });
    final job = made.job;
    if (!made.ok || job == null) throw DecorFailure(message: made.message);
    final run = await ps.run(job.id);
    if (!run.ok) throw DecorFailure(message: run.message);
    final un = await ps.unlock(job.id, ExportKind.wallpaper);
    final url = '${un.body['result'] ?? ''}';
    if (!un.ok || url.isEmpty) throw DecorFailure(message: un.message);
    final Uint8List? bytes = await ps.download(url);
    if (bytes == null || bytes.isEmpty) throw const DecorFailure();
    return preparePhotoBytes(bytes, 'ai_theme.png');
  }

  @visibleForTesting
  void forgetSeen() => _seen.clear();
}
