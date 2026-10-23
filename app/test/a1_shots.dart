// a1-circle gallery states for test/screenshots_test.dart (owner bug report
// on build 202): chat headers at 360 dp with a long name + the longest
// last-seen lines (never cut), the chat list with two DIFFERENT people of
// the same name ("…200" / "…888") + "Hasn't opened Assisto yet · Invite",
// and call events inside a 1:1 chat. Real ciphertext (fake_c3_msg ids).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_header.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/models.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';
import 'package:assisto/widgets/msgr_hub_chat_list.dart';

import 'fake_c3_msg.dart';

String _n(bool bn, String en, String b) => bn ? b : en;
String _ago(Duration d) => DateTime.now().subtract(d).toUtc().toIso8601String();

class _A1Api extends ApiClient {
  _A1Api(this.bn) {
    token = 'shot';
  }
  final bool bn;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.split('?').first;
    if (p == '/circle/chats') return {'results': _rows(bn)};
    if (p == '/circle/calls') return _calls();
    if (p == '/circle/71/messages') return {'results': _msgs(bn)};
    if (p == '/circle/keys/peer/71') {
      return {'public_key': C3Fake.pub(C3Fake.rahim), 'history': const []};
    }
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
  final kashem = _n(bn, 'Abul Kashem', 'আবুল কাশেম');
  return [
    {
      'id': '71',
      'kind': 'member',
      'member': {
        'id': 71,
        'name': kashem,
        'peer_user_id': 18,
        'public_key': C3Fake.pub(C3Fake.rahim),
        'same_name': true,
        'phone_tail': '200',
      },
      'last': {
        'id': 54,
        'mine': false,
        'content_type': 'text',
        'peer_public_key': C3Fake.pub(C3Fake.rahim),
        ...C3Fake.env(_n(bn, 'Reached home, call me later', 'বাসায় পৌঁছেছি, পরে ফোন দিও'),
            C3Fake.rahim, C3Fake.me),
      },
      'unread': 1,
      'at': _ago(const Duration(minutes: 3)),
      'peer_has_app': true,
    },
    {
      'id': '72',
      'kind': 'member',
      'member': {
        'id': 72,
        'name': kashem,
        'peer_user_id': 23,
        'public_key': '',
        'same_name': true,
        'phone_tail': '888',
      },
      'last': null,
      'unread': 0,
      'at': null,
      'peer_has_app': false,
    },
    {
      'id': '73',
      'kind': 'member',
      'member': {
        'id': 73,
        'name': _n(bn, 'Nadia', 'নাদিয়া'),
        'peer_user_id': 30,
        'public_key': C3Fake.pub(C3Fake.nadia),
      },
      'last': {
        'id': 40,
        'mine': true,
        'status': 'read',
        'content_type': 'text',
        'peer_public_key': C3Fake.pub(C3Fake.nadia),
        ...C3Fake.env(_n(bn, 'Okay, see you', 'ঠিক আছে, দেখা হবে'), C3Fake.me, C3Fake.nadia),
      },
      'unread': 0,
      'at': _ago(const Duration(hours: 5)),
      'peer_has_app': true,
    },
  ];
}

DateTime get _base => DateTime.now().subtract(const Duration(hours: 2));

List<Map<String, dynamic>> _msgs(bool bn) => [
      {
        'id': 50,
        'sender_id': 2,
        'mine': false,
        'content_type': 'text',
        'created_at': _base.toUtc().toIso8601String(),
        ...C3Fake.env(_n(bn, 'Are you free to talk?', 'কথা বলার সময় আছে?'),
            C3Fake.rahim, C3Fake.me),
      },
      {
        'id': 51,
        'sender_id': 1,
        'mine': true,
        'status': 'read',
        'content_type': 'text',
        'created_at': _base.add(const Duration(minutes: 30)).toUtc().toIso8601String(),
        ...C3Fake.env(_n(bn, 'Sorry, missed it. Calling now', 'দুঃখিত, ধরতে পারিনি। এখন ফোন দিচ্ছি'),
            C3Fake.me, C3Fake.rahim),
      },
    ];

Map<String, dynamic> _calls() {
  Map<String, dynamic> ev(int id, String kind, bool out, String cat, int dur, int min) => {
        'id': id,
        'kind': kind,
        'outgoing': out,
        'category': cat,
        'duration_sec': dur,
        'started_at': _base.add(Duration(minutes: min)).toUtc().toIso8601String(),
      };
  return {
    'member_id': 71,
    'events': [
      ev(1, 'voice', false, 'missed', 0, 5),
      ev(2, 'voice', true, 'answered', 192, 31),
      ev(3, 'video', true, 'no_answer', 0, 50),
      ev(4, 'video', false, 'answered', 754, 70),
    ],
  };
}

Widget _withApi(String l, Widget child) {
  final s = AppState();
  s.api = _A1Api(l == 'bn');
  s.user = AppUser(
      id: 1, name: 'Arif', phone: '01712345678', email: '', autonomyLevel: 2, language: l);
  s.locale = Locale(l);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(value: s, child: child);
}

PreferredSizeWidget _bar(Widget title) => AppBar(
      // the real chat has a back arrow: the narrowest title (360 dp)
      leading: IconButton(onPressed: () {}, icon: const Icon(Icons.arrow_back)),
      titleSpacing: 0,
      title: title,
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.videocam_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.call_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
      ],
    );

Widget _headers(String l) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      final bn = l == 'bn';
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day);
      String? p(DateTime ls) =>
          presenceLabel(t, RtChatState(lastSeen: ls), lang: l, now: now);
      final names = [
        _n(bn, 'Abul Kashem', 'আবুল কাশেম'),
        _n(bn, 'Mohammad Abdullah Al Mamun Chowdhury', 'মোহাম্মদ আব্দুল্লাহ আল মামুন চৌধুরী'),
      ];
      final lines = <String?>[
        p(base.add(const Duration(minutes: 5))), // today at 12:05 am
        p(base.subtract(const Duration(days: 1)).add(const Duration(hours: 22, minutes: 5))),
        p(DateTime(now.year - 1, 12, 28, 22, 45)), // the longest: full date
      ];
      return Scaffold(
        body: ListView(children: [
          for (final n in names)
            for (final s in lines)
              _bar(ChatHeaderTitle(
                  name: n, status: s, avatar: HeaderInitialAvatar(name: n))),
        ]),
      );
    });

final Map<String, Widget Function(String)> a1Shots = {
  'a1_header_last_seen': (l) => _headers(l),
  'a1_chat_list_same_name': (l) => _withApi(
      l,
      Scaffold(
          appBar: AppBar(title: Text(l == 'bn' ? 'আমার সার্কেল' : 'My Circle')),
          body: MsgrHubChatList(identity: C3Fake.me, members: const []))),
  'a1_chat_call_events': (l) => _withApi(
      l,
      CircleChatScreen(member: {
        'id': 71,
        'name': l == 'bn' ? 'আবুল কাশেম' : 'Abul Kashem',
        'relation': 'friend',
        'state': 'accepted',
        'public_key': C3Fake.pub(C3Fake.rahim),
      }, identity: C3Fake.me)),
};
