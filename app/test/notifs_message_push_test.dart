// notifs (owner 2 Nov, build 282: "My Circle messages show NO notification")
//
// ROOT CAUSE: the release APK's resource shrinker stripped
// drawable/c3_person_avatar (used only BY NAME from Dart) → IconCompat threw
// for resource id 0 → FlnMsgSink.show swallowed the error → onPush still
// returned true → no fallback → nothing drawn, ever.
//
// GUARD: a message push ALWAYS yields a notification — with / without
// preview, when decryption fails, when the key is missing, when drawing
// throws (→ onPush false → caller draws the plain one), and the native
// safety-net rules (mirrored in msg_fallback.dart). Plus: every drawable the
// Dart side names is in the resource keep list.
import 'dart:convert';
import 'dart:io';

import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/msg_fallback.dart';
import 'package:assisto/messaging/msg_notify.dart';
import 'package:assisto/messaging/msg_push_done.dart';
import 'package:assisto/push/push_payload.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _e2e = SoftwareE2E();
final _me = _e2e.generateIdentity();
final _peer = _e2e.generateIdentity();
final _t = lookupAppLocalizations(const Locale('en'));

Map<String, dynamic> _pull(List<Map<String, dynamic>> msgs) => {
      'chat': {'kind': 'member', 'id': 12, 'title': 'Amina', 'is_group': false},
      'me': {'id': 9, 'name': 'Me'},
      'unseen': msgs.length,
      'messages': msgs,
    };

Map<String, dynamic> _msg(int id, String text) {
  final ct = _e2e.encrypt(self: _peer, recipientPublicKey: _me.publicKey, plaintext: text);
  return {
    'id': id,
    'sender_id': 1,
    'mine': false,
    'sender_name': 'Amina',
    'content_type': 'text',
    'ciphertext': ct.ciphertextB64,
    'nonce': ct.nonceB64,
    'sender_key_id': ct.senderKeyId,
    'scheme': ct.scheme,
    'peer_public_key': base64Encode(_peer.publicKey),
    'deleted': '',
    'created_at': DateTime(2026, 11, 2, 10, id).toUtc().toIso8601String(),
  };
}

class _Backend implements MsgBackend {
  final Map<String, dynamic>? resp;
  _Backend(this.resp);
  @override
  Future<Map<String, dynamic>> pull(String kind, int id, {int limit = kMsgWindow}) async {
    if (resp == null) throw StateError('offline');
    return resp!;
  }

  @override
  Future<void> seen(String kind, int id) async {}
  @override
  Future<Map<String, dynamic>> send(String kind, int id, Map<String, dynamic> env) async => {};
  @override
  Future<List<Map<String, dynamic>>> groupRoster(int id) async => const [];
}

class _Sink implements MsgNotifSink {
  final bool fail;
  _Sink({this.fail = false});
  final shown = <MsgNotifModel>[];
  @override
  Future<void> show(MsgNotifModel m, AppLocalizations t, {bool silent = false}) async {
    if (fail) throw StateError('IconCompat: Drawable resource ID must not be 0');
    shown.add(m);
  }

  @override
  Future<void> cancel(String kind, int id) async {}
}

MsgPushHandler _h(_Backend b, _Sink s, {bool hide = false, bool noKey = false}) =>
    MsgPushHandler(
      backend: b,
      identity: () async => noKey ? null : _me,
      sink: s,
      e2e: _e2e,
      hideContent: () async => hide,
    );

PushPayload _push({String preview = '1'}) => PushPayload({
      'kind': 'message',
      'chat_kind': 'member',
      'chat_id': '12',
      'message_id': '77',
      'sender_name': 'Amina',
      'preview': preview,
      'lang': 'en',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('a message push always yields a notification', () {
    test('preview on → sender + decrypted text', () async {
      final s = _Sink();
      expect(await _h(_Backend(_pull([_msg(1, 'hello')])), s).onPush(_push()), isTrue);
      expect(s.shown.single.lines.single.sender, 'Amina');
      expect(s.shown.single.lines.single.text, 'hello');
    });

    test('preview off (push preview=0) → hidden, still drawn', () async {
      final s = _Sink();
      expect(await _h(_Backend(_pull([_msg(1, 'secret')])), s).onPush(_push(preview: '0')), isTrue);
      expect(s.shown.single.hidden, isTrue);
      expect(s.shown.single.lines.single.text, isNot(contains('secret')));
    });

    test('decrypt failure (no key on this phone) → "New message", still drawn', () async {
      final s = _Sink();
      expect(await _h(_Backend(_pull([_msg(1, 'hello')])), s, noKey: true).onPush(_push()), isTrue);
      expect(s.shown.single.lines.single.text, _t.c3NotifEncrypted);
    });

    test('drawing throws → onPush false (caller draws the plain notification)', () async {
      // build 282: this returned TRUE and nothing was ever shown
      final s = _Sink(fail: true);
      expect(await _h(_Backend(_pull([_msg(1, 'hello')])), s).onPush(_push()), isFalse);
    });

    test('pull fails (offline) → onPush false → plain fallback', () async {
      expect(await _h(_Backend(null), _Sink()).onPush(_push()), isFalse);
    });

    test('no-icon details: same conversation, zero icons (safe retry)', () {
      final m = buildMsgNotifModel(_pull([_msg(1, 'x')]),
          decrypt: (_) => 'x', hide: false, t: _t, lang: 'en');
      final d = msgNotificationDetails(m, _t, channelId: 'messages', useIcons: false).android!;
      final st = d.styleInformation as MessagingStyleInformation;
      expect(st.person.icon, isNull);
      expect(st.messages!.single.person!.icon, isNull);
      expect(d.largeIcon, isNull);
      expect(d.tag, 'c3chat:member:12');
      expect(d.importance, Importance.high);
      expect(d.actions!.map((a) => a.id), containsAll([kActionReply, kActionRead]));
    });
  });

  group('native safety net (mirror of MessageNotifier.kt)', () {
    test('preview allowed → sender name + "New message", reply on', () {
      final f = fallbackSpec({'sender_name': 'Amina', 'preview': '1', 'lang': 'en'});
      expect(f.title, 'Amina');
      expect(f.text, 'New message');
      expect(f.canReply, isTrue);
    });
    test('Bangla', () {
      expect(fallbackSpec({'sender_name': 'আমিনা', 'preview': '1', 'lang': 'bn'}).text, 'নতুন মেসেজ');
    });
    test('previews hidden / phone switch / locked chat → no name', () {
      expect(fallbackSpec({'sender_name': 'Amina', 'preview': '0'}).title, 'Assisto');
      expect(fallbackSpec({'sender_name': 'Amina', 'preview': '1'}, hideContent: true).title, 'Assisto');
      final l = fallbackSpec({'sender_name': 'Amina', 'preview': '1'}, locked: true);
      expect(l.title, 'Assisto');
      expect(l.canReply, isFalse);
      expect(fallbackSpec({'sender_name': '', 'preview': '1'}).title, 'Assisto');
    });
    test('notification id/tag identical to Dart (late Dart draw replaces it)', () {
      expect(notifIdFor('member', 12), _push().notificationId);
      expect(notifTag('member', 12), 'c3chat:member:12');
      expect(PushPayload.stableHash('chat-member-12'), notifIdFor('member', 12));
    });
    test('done marker: add keeps the last 30, no duplicates; contains', () async {
      var raw = '';
      for (var i = 0; i < 40; i++) {
        raw = MsgPushDone.add(raw, '$i');
      }
      raw = MsgPushDone.add(raw, '39');
      final ids = raw.split(',');
      expect(ids.length, MsgPushDone.keep);
      expect(ids.last, '39');
      expect(fallbackDoneContains(raw, '39'), isTrue);
      expect(fallbackDoneContains(raw, '3'), isFalse);
      expect(fallbackDoneContains(raw, ''), isFalse);
      await MsgPushDone.mark(_push().data);
      final p = await SharedPreferences.getInstance();
      expect(fallbackDoneContains(p.getString(MsgPushDone.key), '77'), isTrue);
      await MsgPushDone.mark({'kind': 'msg_sync', 'message_id': '78'});
      expect(fallbackDoneContains(p.getString(MsgPushDone.key), '78'), isFalse);
    });
  });

  test('every drawable named from Dart survives release resource shrinking', () {
    final keep = File('android_overlay/app/src/main/res/raw/assisto_keep.xml').readAsStringSync();
    final names = <String>{kAvatarDrawable, 'ic_stat_assisto'};
    final rx = RegExp(r"(?:DrawableResourceAndroid(?:Icon|Bitmap)\(\s*'|'@drawable/)(\w+)'");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      for (final m in rx.allMatches(f.readAsStringSync())) {
        names.add(m.group(1)!);
      }
    }
    for (final n in names) {
      expect(keep, contains('@drawable/$n'), reason: '$n must be in assisto_keep.xml');
    }
  });
}
