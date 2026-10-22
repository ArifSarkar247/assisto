import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../push/push_payload.dart';
import 'badges_bus.dart';
import 'msg_prefs.dart';

/// c3-msg — WhatsApp-style message notifications, built ON THE DEVICE.
///
/// The FCM push for a message is DATA-ONLY and carries ids + the sender's
/// display name — never text (backend/core/push.py hook_circle_message). On
/// arrival the device:
///   1. pulls the chat's not-yet-seen window as CIPHERTEXT
///      (POST /circle/notify/pull — this is also the DELIVERED ✓✓ ack),
///   2. decrypts it with the on-device key,
///   3. draws ONE MessagingStyle notification per conversation (latest 5
///      messages, sender name + person avatar, grouped under one summary),
///      with INLINE REPLY and "Mark as read" actions.
/// Inline reply runs in flutter_local_notifications' action isolate (works
/// with the app in the background or swiped away — no cold start of the UI):
/// it encrypts on the device and posts the envelope, marks the chat read and
/// clears the notification. Hidden-content mode shows only "N new messages".

const kMsgWindow = 5;
const kActionReply = 'c3_reply';
const kActionRead = 'c3_read';
const kMsgGroupKey = 'com.assisto.MESSAGES';
const kMsgSummaryId = 0x7c3c3;
const kAvatarDrawable = 'c3_person_avatar';

/// One line of the MessagingStyle notification (already decrypted).
@immutable
class NotifLine {
  final String sender;
  final String senderKey;
  final String text;
  final DateTime at;
  final bool mine;
  const NotifLine(
      {required this.sender,
      required this.senderKey,
      required this.text,
      required this.at,
      this.mine = false});
}

@immutable
class MsgNotifModel {
  final String kind; // member | group
  final int chatId;
  final String title;
  final bool isGroup;
  final List<NotifLine> lines;
  final int unseen;
  final bool hidden;
  final String lang;
  const MsgNotifModel({
    required this.kind,
    required this.chatId,
    required this.title,
    required this.isGroup,
    required this.lines,
    required this.unseen,
    required this.hidden,
    required this.lang,
  });

  bool get isEmpty => lines.isEmpty;
  String get tag => notifTag(kind, chatId);
  int get notificationId => notifIdFor(kind, chatId);
  String get shortcutId => 'c3chat_${kind}_$chatId';

  /// Payload stored on the notification (tap / actions round-trip). Ids only.
  String get payload => jsonEncode({
        'kind': 'message',
        'chat_kind': kind,
        'chat_id': '$chatId',
        'lang': lang,
        'route': isGroup ? 'circle/group' : 'circle/chat',
      });
}

String notifTag(String kind, int id) => 'c3chat:$kind:$id';

/// Same id the legacy PushNotifier used for this chat (so an old-style
/// notification is replaced, not duplicated).
int notifIdFor(String kind, int id) => PushPayload({
      'kind': 'message',
      'chat_kind': kind,
      'chat_id': '$id',
    }).notificationId;

typedef EnvelopeDecrypt = String? Function(Map<String, dynamic> env);

/// Decrypt with this phone's identity (ECDH is symmetric: my own lines
/// decrypt with the peer's key the server pointed at).
EnvelopeDecrypt e2eDecryptor(IdentityKeyPair self, {E2E? e2e}) {
  final engine = e2e ?? SoftwareE2E();
  return (env) {
    try {
      final pub = '${env['peer_public_key'] ?? ''}';
      final ct = '${env['ciphertext'] ?? ''}';
      if (pub.isEmpty || ct.isEmpty) return null;
      return engine.decrypt(
        self: self,
        senderPublicKey: Uint8List.fromList(base64Decode(pub)),
        ct: Ciphertext(
          scheme: '${env['scheme'] ?? engine.scheme}',
          ciphertextB64: ct,
          nonceB64: '${env['nonce'] ?? ''}',
          senderKeyId: '${env['sender_key_id'] ?? ''}',
        ),
      );
    } catch (_) {
      return null;
    }
  };
}

String _mediaLabel(AppLocalizations t, String ct) {
  switch (ct) {
    case 'photo':
    case 'image':
      return t.circlePhoto;
    case 'video':
      return t.circleVideo;
    case 'voice':
    case 'audio':
      return t.circleVoiceNote;
    case 'document':
      return t.circleAttachDocument;
    case 'contact':
      return t.circleAttachContact;
    case 'location':
      return t.circleAttachLocation;
    default:
      return t.circleAttach;
  }
}

/// PURE: the notification model from a /circle/notify/pull response.
MsgNotifModel buildMsgNotifModel(
  Map<String, dynamic> pull, {
  required EnvelopeDecrypt decrypt,
  required bool hide,
  required AppLocalizations t,
  required String lang,
  int window = kMsgWindow,
}) {
  final chat = (pull['chat'] as Map?)?.cast<String, dynamic>() ?? const {};
  final kind = chat['kind'] == 'group' ? 'group' : 'member';
  final id = int.tryParse('${chat['id'] ?? ''}') ?? 0;
  final isGroup = chat['is_group'] == true || kind == 'group';
  final title = '${chat['title'] ?? ''}'.trim();
  final meName = '${((pull['me'] as Map?) ?? const {})['name'] ?? ''}';
  final raw = ((pull['messages'] as List?) ?? const [])
      .whereType<Map>()
      .map((m) => m.cast<String, dynamic>())
      .toList();
  final unseen = (pull['unseen'] is int)
      ? pull['unseen'] as int
      : raw.where((m) => m['mine'] != true).length;
  final slice = raw.length <= window ? raw : raw.sublist(raw.length - window);

  if (hide) {
    final n = max(1, unseen);
    return MsgNotifModel(
      kind: kind,
      chatId: id,
      title: title.isEmpty ? 'Assisto' : title,
      isGroup: isGroup,
      unseen: unseen,
      hidden: true,
      lang: lang,
      lines: slice.isEmpty
          ? const []
          : [
              NotifLine(
                sender: title.isEmpty ? 'Assisto' : title,
                senderKey: 'chat-$kind-$id',
                text: t.c3NotifHiddenCount(n),
                at: DateTime.tryParse('${slice.last['created_at'] ?? ''}')
                        ?.toLocal() ??
                    DateTime.now(),
              ),
            ],
    );
  }

  final lines = <NotifLine>[];
  for (final m in slice) {
    final mine = m['mine'] == true;
    final ct = '${m['content_type'] ?? 'text'}';
    String text;
    if ('${m['deleted'] ?? ''}' == 'everyone') {
      text = t.circleDeletedPlaceholder;
    } else if (ct != 'text') {
      text = _mediaLabel(t, ct);
    } else {
      text = decrypt(m) ?? t.c3NotifEncrypted;
    }
    final sender = mine
        ? t.c3You
        : ('${m['sender_name'] ?? ''}'.trim().isNotEmpty
            ? '${m['sender_name']}'.trim()
            : (title.isEmpty ? 'Assisto' : title));
    lines.add(NotifLine(
      sender: sender,
      senderKey: mine ? 'me' : 'u${m['sender_id'] ?? ''}',
      text: text,
      at: DateTime.tryParse('${m['created_at'] ?? ''}')?.toLocal() ??
          DateTime.now(),
      mine: mine,
    ));
  }
  return MsgNotifModel(
    kind: kind,
    chatId: id,
    title: title.isEmpty ? (meName.isEmpty ? 'Assisto' : meName) : title,
    isGroup: isGroup,
    unseen: unseen,
    hidden: false,
    lang: lang,
    lines: lines,
  );
}

/// The Android notification for a model.
NotificationDetails msgNotificationDetails(MsgNotifModel m, AppLocalizations t,
    {required String channelId, bool silent = false}) {
  const avatar = DrawableResourceAndroidIcon(kAvatarDrawable);
  final me = Person(name: t.c3You, key: 'me', icon: avatar);
  final style = MessagingStyleInformation(
    me,
    conversationTitle: m.isGroup ? m.title : null,
    groupConversation: m.isGroup,
    messages: [
      for (final l in m.lines)
        Message(
            l.text,
            l.at,
            l.mine
                ? null
                : Person(
                    name: l.sender, key: l.senderKey, icon: avatar, important: true)),
    ],
  );
  return NotificationDetails(
    android: AndroidNotificationDetails(
      channelId,
      t.pushChMessages,
      channelDescription: t.pushChMessagesDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: style,
      groupKey: kMsgGroupKey,
      tag: m.tag,
      shortcutId: m.shortcutId,
      visibility: NotificationVisibility.private,
      onlyAlertOnce: silent,
      silent: silent,
      number: m.unseen,
      actions: [
        AndroidNotificationAction(
          kActionReply,
          t.c3NotifReply,
          showsUserInterface: false,
          cancelNotification: false,
          allowGeneratedReplies: true,
          inputs: [AndroidNotificationActionInput(label: t.c3NotifReplyHint)],
        ),
        AndroidNotificationAction(kActionRead, t.c3NotifMarkRead,
            showsUserInterface: false, cancelNotification: true),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Backend + sink seams (fakes in tests)
// ---------------------------------------------------------------------------
abstract class MsgBackend {
  Future<Map<String, dynamic>> pull(String kind, int id, {int limit = kMsgWindow});
  Future<void> seen(String kind, int id);
  Future<Map<String, dynamic>> send(String kind, int id, Map<String, dynamic> env);
  Future<List<Map<String, dynamic>>> groupRoster(int id);
}

/// Own HTTP client so it works in the FCM / action background isolates.
class HttpMsgBackend implements MsgBackend {
  final String token;
  final String lang;
  final http.Client _c;
  HttpMsgBackend(this.token, {this.lang = 'bn', http.Client? client})
      : _c = client ?? http.Client();

  Map<String, String> get _h => {
        'Authorization': 'Token $token',
        'Content-Type': 'application/json',
        'Accept-Language': lang,
      };

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final r = await _c
        .post(AppConfig.api(path), headers: _h, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw StateError('http ${r.statusCode}');
    }
    return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> pull(String kind, int id, {int limit = kMsgWindow}) =>
      _post('/circle/notify/pull', {'chat_kind': kind, 'chat_id': id, 'limit': limit});

  @override
  Future<void> seen(String kind, int id) => _post(
      kind == 'group' ? '/circle/groups/$id/seen' : '/circle/$id/seen', {});

  @override
  Future<Map<String, dynamic>> send(String kind, int id, Map<String, dynamic> env) =>
      _post(kind == 'group' ? '/circle/groups/$id/messages' : '/circle/$id/messages',
          env);

  @override
  Future<List<Map<String, dynamic>>> groupRoster(int id) async {
    final r = await _c
        .get(AppConfig.api('/circle/groups/$id/members'), headers: _h)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw StateError('http ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['results'] ?? const []) as List)
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }
}

abstract class MsgNotifSink {
  Future<void> show(MsgNotifModel m, AppLocalizations t, {bool silent = false});
  Future<void> cancel(String kind, int id);
}

class FlnMsgSink implements MsgNotifSink {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<String> _ensureChannel(AppLocalizations t) async {
    final id = await MsgPrefs.channelId();
    try {
      // shared key snd_msg_uri: null = phone default, '' = silent
      final uri = await MsgPrefs.soundUri();
      await _android?.createNotificationChannel(AndroidNotificationChannel(
        id,
        t.pushChMessages,
        description: t.pushChMessagesDesc,
        importance: Importance.high,
        playSound: uri == null || uri.isNotEmpty,
        sound: (uri == null || uri.isEmpty)
            ? null
            : UriAndroidNotificationSound(uri),
      ));
    } catch (_) {}
    return id;
  }

  @override
  Future<void> show(MsgNotifModel m, AppLocalizations t, {bool silent = false}) async {
    try {
      if (m.isEmpty) {
        await cancel(m.kind, m.chatId);
        return;
      }
      final ch = await _ensureChannel(t);
      final last = m.lines.last;
      await _plugin.show(
        m.notificationId,
        m.isGroup ? m.title : last.sender,
        last.text,
        msgNotificationDetails(m, t, channelId: ch, silent: silent),
        payload: m.payload,
      );
      await _summary(t, ch);
    } catch (e) {
      if (kDebugMode) debugPrint('c3 notif show failed: $e');
    }
  }

  Future<void> _summary(AppLocalizations t, String ch) async {
    try {
      final active = await _android?.getActiveNotifications() ?? const [];
      final convs = active
          .where((n) => (n.tag ?? '').startsWith('c3chat:'))
          .length;
      if (convs < 2) return;
      await _plugin.show(
        kMsgSummaryId,
        'Assisto',
        t.c3NotifSummary(convs),
        NotificationDetails(
          android: AndroidNotificationDetails(ch, t.pushChMessages,
              groupKey: kMsgGroupKey,
              setAsGroupSummary: true,
              onlyAlertOnce: true,
              silent: true,
              category: AndroidNotificationCategory.message),
        ),
      );
    } catch (_) {}
  }

  @override
  Future<void> cancel(String kind, int id) async {
    try {
      await _plugin.cancel(notifIdFor(kind, id), tag: notifTag(kind, id));
      // a legacy (untagged) notification for the same chat
      await _plugin.cancel(notifIdFor(kind, id));
      final active = await _android?.getActiveNotifications() ?? const [];
      if (!active.any((n) => (n.tag ?? '').startsWith('c3chat:'))) {
        await _plugin.cancel(kMsgSummaryId);
      }
    } catch (_) {}
  }
}

/// Which chat is open on screen right now ('member:12'), so a foreground push
/// for it doesn't ring (the open chat polls + marks seen itself).
class MsgActiveChat {
  MsgActiveChat._();
  static String? current;
  static bool isOpen(String kind, int id) =>
      current == '${kind == 'group' ? 'group' : 'member'}:$id';
}

AppLocalizations msgL10n(String lang) {
  try {
    return lookupAppLocalizations(Locale(lang == 'en' ? 'en' : 'bn'));
  } catch (_) {
    return lookupAppLocalizations(const Locale('en'));
  }
}

/// The message-notification brain (UI isolate, FCM background isolate and the
/// notification-action isolate all use it).
class MsgPushHandler {
  final MsgBackend backend;
  final Future<IdentityKeyPair?> Function() identity;
  final MsgNotifSink sink;
  final E2E e2e;
  final Future<bool> Function() hideContent;
  final String Function() clientMsgId;

  MsgPushHandler({
    required this.backend,
    required this.identity,
    required this.sink,
    E2E? e2e,
    Future<bool> Function()? hideContent,
    String Function()? clientMsgId,
  })  : e2e = e2e ?? SoftwareE2E(),
        hideContent = hideContent ?? MsgPrefs.hideContent,
        clientMsgId = clientMsgId ??
            (() => 'nr-${DateTime.now().microsecondsSinceEpoch}');

  static ({String kind, int id})? chatOf(PushPayload p) {
    if (p.kind != 'message') return null;
    final id = int.tryParse(p.chatId);
    if (id == null) return null;
    return (kind: p.data['chat_kind'] == 'group' ? 'group' : 'member', id: id);
  }

  /// Draw (or refresh / clear) the conversation notification for a push.
  /// Returns false when it could not (caller falls back to the plain
  /// title/body notification so a message is never silently lost).
  Future<bool> onPush(PushPayload p) async {
    final chat = chatOf(p);
    if (chat == null) return false;
    final t = msgL10n(p.lang);
    try {
      final pull = await backend.pull(chat.kind, chat.id);
      final self = await identity();
      // this phone's switch OR the account-wide "Message preview" off
      final hide = await hideContent() || p.data['preview'] == '0';
      final model = buildMsgNotifModel(pull,
          decrypt: self == null ? (_) => null : e2eDecryptor(self, e2e: e2e),
          hide: hide,
          t: t,
          lang: p.lang);
      if (model.isEmpty) {
        // already read on another device (or the chat is open) → clear
        await sink.cancel(chat.kind, chat.id);
        return true;
      }
      await sink.show(model, t);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('c3 onPush failed: $e');
      return false;
    }
  }

  /// "Mark as read" from the notification.
  Future<void> markRead(String kind, int id) async {
    try {
      await backend.seen(kind, id);
      BadgesBus.instance.poke(); // b2-badges
    } catch (_) {}
    await sink.cancel(kind, id);
  }

  /// Inline reply: encrypt on the device, post the envelope, mark the chat
  /// read, clear the notification. On failure the notification is redrawn
  /// with a "not sent" line so the user knows (and can open the chat).
  Future<bool> reply(String kind, int id, String text, {String lang = 'bn'}) async {
    final body = text.trim();
    final t = msgL10n(lang);
    if (body.isEmpty) return false;
    try {
      final self = await identity();
      if (self == null) throw StateError('no identity');
      final Map<String, dynamic> env;
      if (kind == 'group') {
        final roster = await backend.groupRoster(id);
        final per = <String, dynamic>{};
        final rids = <int>[];
        for (final r in roster) {
          final pub = '${r['public_key'] ?? ''}';
          if (r['is_self'] == true || pub.isEmpty) continue;
          final mid = int.tryParse('${r['member_id'] ?? ''}');
          if (mid == null) continue;
          final ct = e2e.encrypt(
              self: self,
              recipientPublicKey: Uint8List.fromList(base64Decode(pub)),
              plaintext: body);
          per['$mid'] = {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64};
          rids.add(mid);
        }
        if (per.isEmpty) throw StateError('no recipients');
        env = {
          'recipient_ids': rids,
          'per_recipient': per,
          'sender_key_id': self.keyId,
          'scheme': e2e.scheme,
          'client_msg_id': clientMsgId(),
        };
      } else {
        final pull = await backend.pull(kind, id, limit: 1);
        final pub = '${((pull['chat'] as Map?) ?? const {})['peer_public_key'] ?? ''}';
        if (pub.isEmpty) throw StateError('no peer key');
        final ct = e2e.encrypt(
            self: self,
            recipientPublicKey: Uint8List.fromList(base64Decode(pub)),
            plaintext: body);
        env = {
          'content_type': 'text',
          'client_msg_id': clientMsgId(),
          ...ct.toEnvelopeFields(),
        };
      }
      await backend.send(kind, id, env);
      try {
        await backend.seen(kind, id);
      } catch (_) {}
      await sink.cancel(kind, id);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('c3 reply failed: $e');
      try {
        final pull = await backend.pull(kind, id);
        final self = await identity();
        final m = buildMsgNotifModel(pull,
            decrypt: self == null ? (_) => null : e2eDecryptor(self, e2e: e2e),
            hide: await hideContent(),
            t: t,
            lang: lang);
        await sink.show(
            MsgNotifModel(
              kind: kind,
              chatId: id,
              title: m.title,
              isGroup: m.isGroup,
              unseen: m.unseen,
              hidden: m.hidden,
              lang: lang,
              lines: [
                ...m.lines,
                NotifLine(
                    sender: t.c3You,
                    senderKey: 'me',
                    text: t.c3NotifReplyFailed,
                    at: DateTime.now(),
                    mine: true),
              ],
            ),
            t,
            silent: true);
      } catch (_) {
        await sink.cancel(kind, id);
      }
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// Isolate entry helpers (no BuildContext, own storage + HTTP)
// ---------------------------------------------------------------------------
const _secure = FlutterSecureStorage();

Future<IdentityKeyPair?> loadStoredIdentity() async {
  try {
    final s = await _secure.read(key: 'circle_identity_v1');
    if (s == null) return null;
    final j = jsonDecode(s) as Map<String, dynamic>;
    return IdentityKeyPair(base64Decode(j['priv'] as String),
        base64Decode(j['pub'] as String), j['kid'] as String);
  } catch (_) {
    return null;
  }
}

Future<MsgPushHandler?> backgroundMsgHandler({String lang = 'bn', String? token}) async {
  try {
    token ??= await _secure.read(key: 'token');
    if (token == null || token.isEmpty) return null;
    return MsgPushHandler(
      backend: HttpMsgBackend(token, lang: lang),
      identity: loadStoredIdentity,
      sink: FlnMsgSink(),
    );
  } catch (_) {
    return null;
  }
}

/// A notification action (reply / mark read) — any isolate. Returns true if
/// it was a c3 action.
Future<bool> handleMsgNotificationAction(NotificationResponse r) async {
  if (r.actionId != kActionReply && r.actionId != kActionRead) return false;
  final p = PushPayload.decode(r.payload);
  if (p == null) return true;
  final chat = MsgPushHandler.chatOf(p);
  if (chat == null) return true;
  final h = await backgroundMsgHandler(lang: p.lang);
  if (h == null) return true;
  if (r.actionId == kActionRead) {
    await h.markRead(chat.kind, chat.id);
  } else {
    await h.reply(chat.kind, chat.id, r.input ?? '', lang: p.lang);
  }
  return true;
}
