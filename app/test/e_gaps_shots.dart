// e-gaps (owner order E) gallery states for test/screenshots_test.dart:
// a 1:1 chat with the disappearing-timer line + view-once photos (received
// unopened / sent / opened) + a voice note playing at 1.5x, the photo preview
// with the "1" view-once toggle on, the chat list with the "Locked chats"
// folder + a pinned group, a locked chat opened from outside, and the
// message search opened from the chat list.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/messaging/chat_decor/chat_control.dart';
import 'package:assisto/messaging/chat_lock.dart';
import 'package:assisto/messaging/media/media_descriptor.dart';
import 'package:assisto/messaging/media/media_prep.dart';
import 'package:assisto/messaging/media/media_send.dart';
import 'package:assisto/messaging/media/voice_bubble.dart';
import 'package:assisto/messaging/media/voice_player.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_search_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';

import 'fake_c3_msg.dart';
import 'md1_shots.dart' show scenePng;

String _n(bool bn, String en, String b) => bn ? b : en;
DateTime get _base => DateTime.now().subtract(const Duration(hours: 1));

String _ref(int i) => '$i'.padLeft(32, 'e');

String _voDesc(String ref) => markViewOnce(MediaDescriptor(
        kind: 'photo', ref: ref, key: Uint8List(32)..[0] = 1, nonce: Uint8List(12),
        sha256: 'f' * 64, size: 4000, plainSize: 3968, mime: 'image/jpeg', width: 640, height: 480)
    .encode());

List<Map<String, dynamic>> _msgs(bool bn) {
  var i = 0;
  Map<String, dynamic> m(String text,
      {required bool mine, String ct = 'text', Map<String, dynamic> extra = const {}}) {
    i++;
    return {
      'id': 900 + i,
      'sender_id': mine ? 1 : 2,
      'mine': mine,
      if (mine) 'status': 'read',
      'content_type': ct,
      'created_at': _base.add(Duration(minutes: i * 3)).toUtc().toIso8601String(),
      ...C3Fake.env(text, mine ? C3Fake.me : C3Fake.rahim, mine ? C3Fake.rahim : C3Fake.me),
      ...extra,
    };
  }

  final rahim = _n(bn, 'Rahim', 'রহিম');
  return [
    m(_n(bn, 'Sending the flat photos now', 'ফ্ল্যাটের ছবিগুলো পাঠাচ্ছি'), mine: false),
    m(encodeControl(ChatControl.timer(86400, at: 1000), '$rahim turned on disappearing messages'),
        mine: false),
    m(_voDesc(_ref(1)), mine: false, ct: 'photo', extra: {'view_once': true, 'blob_ref': _ref(1)}),
    m('', mine: true, ct: 'photo', extra: {
      'view_once': true, 'view_once_opened': true, 'ciphertext': '', 'nonce': '', 'blob_ref': ''
    }),
    m('', mine: false, ct: 'photo', extra: {
      'view_once': true, 'view_once_opened': true, 'ciphertext': '', 'nonce': '', 'blob_ref': ''
    }),
    m(_n(bn, 'Got it, thanks!', 'পেয়েছি, ধন্যবাদ!'), mine: true),
  ];
}

class _EApi extends ApiClient {
  _EApi(this.bn) {
    token = 'shot';
  }
  final bool bn;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.split('?').first;
    if (p == '/circle/91/messages') return {'results': _msgs(bn), 'has_more': false};
    if (p == '/circle/1/messages') {
      return {
        'results': [
          {
            'id': 70, 'sender_id': 2, 'content_type': 'text', 'deleted': '',
            'created_at': DateTime(2026, 10, 18, 20).toUtc().toIso8601String(),
            ...C3Fake.env(_n(bn, 'Dinner at 8 on Friday?', 'শুক্রবার ৮টায় রাতের খাবার?'),
                C3Fake.rahim, C3Fake.me),
          },
          {
            'id': 71, 'sender_id': 1, 'content_type': 'text', 'deleted': '',
            'created_at': DateTime(2026, 10, 18, 21).toUtc().toIso8601String(),
            ...C3Fake.env(_n(bn, 'Yes, dinner is on me', 'হ্যাঁ, রাতের খাবার আমার পক্ষ থেকে'),
                C3Fake.me, C3Fake.rahim),
          },
        ]
      };
    }
    if (p == '/circle/keys/peer/91' || p == '/circle/keys/peer/1') {
      return {'public_key': C3Fake.pub(C3Fake.rahim), 'history': const []};
    }
    if (p == '/circle/91/settings') {
      return {
        'disappearing_sec': 86400,
        'disappearing_since': _base.toUtc().toIso8601String(),
      };
    }
    if (p == '/circle/chats') return {'results': _rows(bn)};
    if (p.contains('/messages')) return {'results': const []};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

List<Map<String, dynamic>> _rows(bool bn) {
  Map<String, dynamic> one(int id, String name, String text, int hours) => {
        'id': '$id',
        'kind': 'member',
        'member': {'id': id, 'name': name, 'public_key': C3Fake.pub(C3Fake.rahim)},
        'unread': 0,
        'at': DateTime.now().subtract(Duration(hours: hours)).toUtc().toIso8601String(),
        'last': {
          'id': 100 + id, 'mine': false, 'content_type': 'text',
          'peer_public_key': C3Fake.pub(C3Fake.rahim),
          ...C3Fake.env(text, C3Fake.rahim, C3Fake.me),
        },
      };
  return [
    one(1, _n(bn, 'Rahim', 'রহিম'), _n(bn, 'See you at 8', '৮টায় দেখা হবে'), 1),
    one(52, _n(bn, 'Nadia', 'নাদিয়া'), _n(bn, 'Private: the surprise plan', 'গোপন: সারপ্রাইজের পরিকল্পনা'), 2),
    one(3, _n(bn, 'Karim', 'করিম'), _n(bn, 'Sent the invoice', 'ইনভয়েস পাঠিয়েছি'), 5),
    {
      'id': 'g7', 'kind': 'group', 'is_group': true, 'group_id': 7,
      'group': {'id': 7, 'name': _n(bn, 'Family', 'পরিবার'), 'my_member_id': 3},
      'member': {'id': null, 'name': _n(bn, 'Family', 'পরিবার')},
      'unread': 0, 'pinned': true,
      'pin_at': DateTime(2026, 10, 20).toUtc().toIso8601String(),
      'at': DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String(),
      'last': null,
    },
  ];
}

Widget _withApi(String l, Widget child) {
  final s = AppState();
  s.api = _EApi(l == 'bn');
  s.user = AppUser(
      id: 1, name: l == 'bn' ? 'আরিফ' : 'Arif', phone: '01712345678', email: '',
      autonomyLevel: 2, language: l);
  s.locale = Locale(l);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(value: s, child: child);
}

Map<String, dynamic> _member(bool bn) => {
      'id': 91,
      'name': bn ? 'রহিম' : 'Rahim',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': C3Fake.pub(C3Fake.rahim),
    };

Directory? _dir;
String _photoPath() {
  final d = _dir ??= Directory.systemTemp.createTempSync('e_gallery');
  final f = File('${d.path}/vo.png');
  if (!f.existsSync()) f.writeAsBytesSync(scenePng(240, 300, sunX: 0.3));
  return f.path;
}

final Map<String, Widget Function(String)> eGapsShots = {
  'e_chat_disappearing_viewonce': (l) =>
      _withApi(l, CircleChatScreen(member: _member(l == 'bn'), identity: C3Fake.me)),
  'e_photo_preview_viewonce': (l) => _PreviewOn(path: _photoPath()),
  'e_voice_speed': (l) {
    VoicePlayer.instance.state.value =
        const VoiceState(path: '/x/voice.m4a', playing: true, positionMs: 4000, durationMs: 12000);
    VoicePlayer.instance.rate.value = 1.5;
    return const _VoiceDemo();
  },
  'e_hub_locked_pinned_group': (l) {
    // a code exists whenever a chat is locked (tapping the folder asks it);
    // ids unique to this shot so no other gallery screen sees the lock
    ChatLockStore.instance.setCode('1357').then((_) => ChatLockStore.instance.lock('member:52'));
    return _withApi(l, Scaffold(body: MsgrHubChatList(identity: C3Fake.me, members: const [])));
  },
  'e_lock_gate': (l) {
    // opened from outside the folder: the gate + the code prompt
    ChatLockAuth.biometric = (_) async => false;
    ChatLockStore.instance.setCode('1357').then((_) => ChatLockStore.instance.lock('member:91'));
    return _withApi(l, CircleChatScreen(member: _member(l == 'bn'), identity: C3Fake.me));
  },
  'e_message_search': (l) => _withApi(
      l,
      CircleSearchScreen(members: [
        {'id': 1, 'name': l == 'bn' ? 'রহিম' : 'Rahim', 'public_key': C3Fake.pub(C3Fake.rahim)},
      ], identity: C3Fake.me, initialQuery: l == 'bn' ? 'রাতের খাবার' : 'dinner')),
};

/// The photo preview with the view-once toggle already ON.
class _PreviewOn extends StatelessWidget {
  final String path;
  const _PreviewOn({required this.path});
  @override
  Widget build(BuildContext context) => PhotoSendPreview(
      allowViewOnce: true,
      initialViewOnce: true,
      draft: MediaDraft(kind: 'photo', path: path, name: 'IMG-3.png', mime: 'image/png', size: 2000));
}

class _VoiceDemo extends StatelessWidget {
  const _VoiceDemo();
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(16)),
          child: const _Voice(),
        ),
      ),
    );
  }
}

class _Voice extends StatelessWidget {
  const _Voice();
  @override
  Widget build(BuildContext context) => VoiceNoteBody(
      path: '/x/voice.m4a',
      durationMs: 12000,
      wave: const [4, 9, 14, 22, 28, 19, 11, 6, 13, 24, 31, 26, 17, 9, 5, 12, 20, 27, 21, 14],
      fg: Theme.of(context).colorScheme.onSurface);
}
