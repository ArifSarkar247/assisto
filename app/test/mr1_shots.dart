// mr1 gallery states for test/screenshots_test.dart: My Circle MESSAGE
// REQUESTS (the requests section with a decrypted preview, the read-only
// request conversation with Accept / Block / Report / Delete, the sender's
// waiting line + the pre-accept limit note) and the FULL last-seen header
// lines. Real ciphertext (throw-away identities from fake_c3_msg.dart).
import 'package:flutter/material.dart';

import 'package:assisto/l10n/app_localizations.dart';
import 'package:assisto/messaging/chat_header.dart';
import 'package:assisto/messaging/presence_label.dart';
import 'package:assisto/realtime/realtime_channel.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/widgets/m3_circle_widgets.dart';

import 'fake_c3_msg.dart';

bool fakeMr1On = false;

String _n(bool bn, String en, String b) => bn ? b : en;
String _ago(Duration d) =>
    DateTime.now().subtract(d).toUtc().toIso8601String();

Map<String, dynamic> _incomingMember(bool bn) => {
      'id': 61,
      'name': _n(bn, 'Sumon Ahmed', 'সুমন আহমেদ'),
      'photo': C3Fake.avatar,
      'state': 'pending',
      'direction': 'incoming',
      'public_key': C3Fake.pub(C3Fake.nadia),
      'request_phone': '',
    };

Map<String, dynamic> _outgoingMember(bool bn, {bool full = false}) => {
      'id': full ? 63 : 62,
      'name': _n(bn, 'Rafiq Islam', 'রফিক ইসলাম'),
      'state': 'pending',
      'direction': 'outgoing',
      'public_key': C3Fake.pub(C3Fake.karim),
      'request': {'limit': 5, 'sent': full ? 5 : 2, 'can_send': !full},
    };

Map<String, dynamic>? fakeMr1Get(String path, bool bn) {
  if (!fakeMr1On) return null;
  final p = path.split('?').first;
  if (p == '/circle/requests') {
    final last = C3Fake.env(
        _n(bn, 'Hi, is the room on Road 5 still for rent?',
            'আসসালামু আলাইকুম, ৫ নম্বর রোডের রুমটা কি এখনো ভাড়া হয়নি?'),
        C3Fake.nadia, C3Fake.me);
    final last2 = C3Fake.env(
        _n(bn, 'I found your number on the school group',
            'স্কুলের গ্রুপে আপনার নম্বর পেলাম'),
        C3Fake.rahim, C3Fake.me);
    return {
      'results': [
        {
          'id': 61, 'direction': 'incoming',
          'display_name': _n(bn, 'Sumon Ahmed', 'সুমন আহমেদ'),
          'photo': C3Fake.avatar, 'phone': '', 'not_in_contacts': true,
          'msg_count': 2, 'at': _ago(const Duration(minutes: 4)),
          'last': {'id': 7, 'mine': false, 'content_type': 'text',
                   'peer_public_key': C3Fake.pub(C3Fake.nadia), ...last},
          'member': _incomingMember(bn),
          'actions': ['accept', 'decline', 'block'],
        },
        {
          'id': 64, 'direction': 'incoming',
          'display_name': _n(bn, 'Farhana Akter', 'ফারহানা আক্তার'),
          'phone': '+8801711000002', 'not_in_contacts': true,
          'msg_count': 1, 'at': _ago(const Duration(hours: 3)),
          'last': {'id': 5, 'mine': false, 'content_type': 'text',
                   'peer_public_key': C3Fake.pub(C3Fake.rahim), ...last2},
          'member': {'id': 64, 'name': 'Farhana', 'state': 'pending',
                     'direction': 'incoming',
                     'public_key': C3Fake.pub(C3Fake.rahim)},
          'actions': ['accept', 'decline', 'block'],
        },
        {
          'id': 65, 'direction': 'incoming',
          'display_name': _n(bn, 'Karim Hossain', 'করিম হোসেন'),
          'relation_label': _n(bn, 'Friend', 'বন্ধু'),
          'actions': ['accept', 'decline', 'block'],
        },
      ],
    };
  }
  final t0 = DateTime.now().subtract(const Duration(minutes: 20));
  String at(int m) => t0.add(Duration(minutes: m)).toUtc().toIso8601String();
  if (p == '/circle/61/messages') {
    return {
      'results': [
        {'id': 6, 'sender_id': 50, 'mine': false, 'created_at': at(0),
         'content_type': 'text',
         ...C3Fake.env(_n(bn, 'Hi, is the room on Road 5 still for rent?',
             'আসসালামু আলাইকুম, ৫ নম্বর রোডের রুমটা কি এখনো ভাড়া হয়নি?'),
             C3Fake.nadia, C3Fake.me)},
        {'id': 7, 'sender_id': 50, 'mine': false, 'created_at': at(1),
         'content_type': 'text',
         ...C3Fake.env(_n(bn, 'I saw the To-Let sign. I can visit today.',
             'টু-লেট দেখে ফোন নম্বর পেলাম। আজকেই দেখতে আসতে পারি।'),
             C3Fake.nadia, C3Fake.me)},
      ],
      'edge': {'state': 'pending', 'direction': 'incoming'},
    };
  }
  if (p == '/circle/62/messages' || p == '/circle/63/messages') {
    final full = p.contains('63');
    final texts = full
        ? [
            _n(bn, 'Hello Rafiq bhai', 'রফিক ভাই, আসসালামু আলাইকুম'),
            _n(bn, 'This is Amina from the office', 'আমি অফিসের আমিনা'),
            _n(bn, 'About the tiffin order', 'টিফিনের অর্ডারের ব্যাপারে'),
            _n(bn, 'Can you call me?', 'একটু ফোন দেবেন?'),
            _n(bn, 'Thank you', 'ধন্যবাদ'),
          ]
        : [
            _n(bn, 'Hello Rafiq bhai', 'রফিক ভাই, আসসালামু আলাইকুম'),
            _n(bn, 'This is Amina from the office', 'আমি অফিসের আমিনা'),
          ];
    return {
      'results': [
        for (var i = 0; i < texts.length; i++)
          {'id': 20 + i, 'sender_id': 9, 'mine': true,
           'status': i == texts.length - 1 ? 'sent' : 'delivered',
           'created_at': at(i * 2), 'content_type': 'text',
           ...C3Fake.env(texts[i], C3Fake.me, C3Fake.karim)},
      ],
      'edge': {
        'state': 'pending', 'direction': 'outgoing',
        'request': {'limit': 5, 'sent': texts.length,
                    'can_send': texts.length < 5},
      },
    };
  }
  return null;
}

PreferredSizeWidget _bar(Widget title) => AppBar(
      titleSpacing: 0,
      title: title,
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.videocam_rounded)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.call_rounded)),
      ],
    );

Widget _headers(String l, {bool h24 = false}) => Builder(builder: (ctx) {
      final t = AppLocalizations.of(ctx);
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day);
      String? p(DateTime ls) => presenceLabel(t, RtChatState(lastSeen: ls),
          lang: l, now: now, use24h: h24);
      final bn = l == 'bn';
      final name = _n(bn, 'Shanto Rahman', 'শান্ত রহমান');
      final rows = <String?>[
        p(base.add(const Duration(hours: 9, minutes: 40))
            .isAfter(now) ? base.add(const Duration(minutes: 5)) :
            base.add(const Duration(hours: 9, minutes: 40))),
        p(base.subtract(const Duration(days: 1)).add(const Duration(hours: 21, minutes: 40))),
        p(base.subtract(const Duration(days: 1)).add(const Duration(hours: 8, minutes: 15))),
        p(base.subtract(const Duration(days: 3)).add(const Duration(hours: 13, minutes: 5))),
        p(base.subtract(const Duration(days: 4)).add(const Duration(hours: 16, minutes: 30))),
        p(base.subtract(const Duration(days: 5)).add(const Duration(hours: 18, minutes: 45))),
        p(base.subtract(const Duration(days: 20)).add(const Duration(hours: 21, minutes: 40))),
        p(DateTime(now.year - 1, 10, 18, 6, 10)),
        null, // hidden by privacy -> no line
      ];
      return Scaffold(
        body: ListView(children: [
          for (final r in rows)
            _bar(ChatHeaderTitle(
                name: name,
                status: r,
                avatar: HeaderInitialAvatar(name: name))),
        ]),
      );
    });

final Map<String, Widget Function(String)> mr1Shots = {
  'mr1_requests_list': (l) => Scaffold(
        appBar: AppBar(title: Text(l == 'bn' ? 'আমার সার্কেল' : 'My Circle')),
        body: ListView(children: [
          M3RequestsBanner(identity: C3Fake.me, onSeeAll: () {}),
        ]),
      ),
  'mr1_request_chat': (l) => CircleChatScreen(
      member: _incomingMember(l == 'bn'), identity: C3Fake.me),
  'mr1_sender_waiting': (l) => CircleChatScreen(
      member: _outgoingMember(l == 'bn'), identity: C3Fake.me),
  'mr1_sender_limit': (l) => CircleChatScreen(
      member: _outgoingMember(l == 'bn', full: true), identity: C3Fake.me),
  'mr1_last_seen_12h': (l) => _headers(l),
  'mr1_last_seen_24h': (l) => _headers(l, h24: true),
};
