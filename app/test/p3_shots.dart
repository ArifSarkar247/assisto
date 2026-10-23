// P3 gallery states for test/screenshots_test.dart: @Assisto action sheet,
// Assisto cards inside a REAL E2E chat (summary, reminder-for-everyone,
// split, shared list), the on-device scam warning, safety cards, the story
// viewer, the story privacy sheet and profile notes on the Updates tab.
// Every chat message here is real ciphertext (C3Fake identities).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/crypto/e2e.dart';
import 'package:assisto/models.dart';
import 'package:assisto/p3/assisto_card.dart';
import 'package:assisto/p3/assisto_sheet.dart';
import 'package:assisto/p3/story_crypto.dart';
import 'package:assisto/p3/story_privacy_sheet.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/screens/circle_status_screen.dart';
import 'package:assisto/screens/circle_status_viewer_screen.dart';
import 'package:assisto/state.dart';

import 'fake_c3_msg.dart';

String _n(bool bn, String en, String b) => bn ? b : en;
DateTime get _base => DateTime.now().subtract(const Duration(hours: 2));
String _at(int min) => _base.add(Duration(minutes: min)).toUtc().toIso8601String();

int _id = 500;
Map<String, dynamic> _in(String text, int min) => {
      'id': _id++,
      'sender_id': 2,
      'mine': false,
      'content_type': 'text',
      'created_at': _at(min),
      ...C3Fake.env(text, C3Fake.rahim, C3Fake.me),
    };
Map<String, dynamic> _out(String text, int min) => {
      'id': _id++,
      'sender_id': 1,
      'mine': true,
      'status': 'read',
      'content_type': 'text',
      'created_at': _at(min),
      ...C3Fake.env(text, C3Fake.me, C3Fake.rahim),
    };

class _P3Api extends ApiClient {
  _P3Api(this.bn, this.msgs) {
    token = 'shot';
  }
  final bool bn;
  final List<Map<String, dynamic>> Function() msgs;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.split('?').first;
    if (p == '/circle/71/messages') return {'results': msgs()};
    if (p == '/circle/keys/peer/71') {
      return {'public_key': C3Fake.pub(C3Fake.rahim), 'history': const []};
    }
    if (p == '/circle/assisto/quote') {
      return {
        'actions': {
          'summarize': {'credits': 1},
          'translate': {'credits': 1},
          'ask': {'credits': 1},
        },
        'balance': 42,
        'ai_available': true,
      };
    }
    if (p == '/circle/status') return _tray();
    if (p == '/circle/notes') return _notes(bn);
    if (p == '/circle/status/privacy') return {'status': {'mode': 'everyone'}};
    return {};
  }

  @override
  Future<Map<String, dynamic>> postJson(String path,
          [Map<String, dynamic> body = const {}]) async =>
      {'ok': true};

  @override
  Future<List<Map<String, dynamic>>> listItems(String path) async => const [];
}

Widget _withApi(String l, List<Map<String, dynamic>> Function() msgs, Widget child) {
  final s = AppState();
  s.api = _P3Api(l == 'bn', msgs);
  s.user = AppUser(
      id: 1, name: l == 'bn' ? 'আরিফ' : 'Arif', phone: '01712345678', email: '',
      autonomyLevel: 2, language: l);
  s.locale = Locale(l);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(value: s, child: child);
}

Widget _chat(String l, List<Map<String, dynamic>> Function(bool bn) msgs) => _withApi(
    l,
    () => msgs(l == 'bn'),
    CircleChatScreen(member: {
      'id': 71,
      'name': l == 'bn' ? 'রহিম' : 'Rahim',
      'relation': 'brother',
      'state': 'accepted',
      'public_key': C3Fake.pub(C3Fake.rahim),
    }, identity: C3Fake.me));

AssistoChatPort _port(bool bn) => AssistoChatPort(
      isGroup: true,
      chatName: _n(bn, 'Family', 'পরিবার'),
      myName: _n(bn, 'Arif', 'আরিফ'),
      memberNames: [_n(bn, 'Rahim', 'রহিম'), _n(bn, 'Nadia', 'নাদিয়া')],
      unread: () => List.generate(12, (i) => {'from': 'R', 'text': 'x'}),
      recent: () => const [],
      draft: () => '',
      setDraft: (_) {},
      lastIncoming: () => '',
      send: (_) async => true,
    );

// ---------------------------------------------------------------- stories
final _e2e = SoftwareE2E();

Map<String, dynamic> _tray() => {
      'entries': [
        {'author_id': 2, 'name': 'Rahim', 'count': 2, 'has_unseen': true, 'latest_at': _at(80)},
        {'author_id': 3, 'name': 'Nadia', 'count': 1, 'has_unseen': false, 'latest_at': _at(20)},
      ],
      'mine': {'count': 1, 'viewer_count': 3},
      'muted': const [],
    };

List<Map<String, dynamic>> _members(bool bn) => [
      {'id': 71, 'name': _n(bn, 'Rahim', 'রহিম'), 'peer_user_id': 2, 'public_key': C3Fake.pub(C3Fake.rahim)},
      {'id': 72, 'name': _n(bn, 'Nadia', 'নাদিয়া'), 'peer_user_id': 3, 'public_key': C3Fake.pub(C3Fake.nadia)},
      {'id': 73, 'name': _n(bn, 'Karim', 'করিম'), 'peer_user_id': 4, 'public_key': C3Fake.pub(C3Fake.karim)},
      {'id': 74, 'name': _n(bn, 'Ammu', 'আম্মু'), 'peer_user_id': 5, 'public_key': C3Fake.pub(C3Fake.rahim)},
    ];

Map<String, dynamic> _sealed(String text, IdentityKeyPair from, IdentityKeyPair to) {
  final ct = _e2e.encrypt(self: from, recipientPublicKey: to.publicKey, plaintext: text);
  return {'ciphertext': ct.ciphertextB64, 'nonce': ct.nonceB64, 'scheme': ct.scheme, 'sender_key_id': ct.senderKeyId};
}

Map<String, dynamic> _notes(bool bn) => {
      'mine': {
        ..._sealed(_n(bn, 'Exam week, wish me luck!', 'পরীক্ষার সপ্তাহ, দোয়া করো!'), C3Fake.me, C3Fake.me),
        'visibility': {'mode': 'everyone'},
      },
      'notes': [
        {'author_id': 2, 'name': 'Rahim', ..._sealed(_n(bn, 'At Cox\'s Bazar', 'কক্সবাজারে আছি'), C3Fake.rahim, C3Fake.me)},
        {'author_id': 3, 'name': 'Nadia', ..._sealed(_n(bn, 'Biryani tonight?', 'আজ রাতে বিরিয়ানি?'), C3Fake.nadia, C3Fake.me)},
        {'author_id': 4, 'name': 'Karim', ..._sealed(_n(bn, 'Back in Dhaka on Friday', 'শুক্রবার ঢাকায় ফিরছি'), C3Fake.karim, C3Fake.me)},
      ],
    };

final Map<String, Widget Function(String)> p3Shots = {
  'p3_assisto_sheet': (l) => _withApi(
      l,
      () => const [],
      Scaffold(
        appBar: AppBar(title: Text(l == 'bn' ? 'পরিবার' : 'Family')),
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: AssistoMenuSheet(port: _port(l == 'bn')),
          ),
        ),
      )),
  'p3_chat_summary': (l) => _chat(l, (bn) => [
        _in(_n(bn, 'Electricity bill is due on Sunday', 'রবিবার বিদ্যুৎ বিল দেওয়ার শেষ দিন'), 0),
        _in(_n(bn, 'I will bring rice and oil', 'আমি চাল আর তেল আনব'), 2),
        _in(_n(bn, 'Ammu’s check-up is at 5 pm', 'আম্মুর চেকআপ বিকেল ৫টায়'), 3),
        _out(
            encodeCard(
                const AssistoCard(CardType.summary, 's1', {
                  'n': 3,
                  'text': '',
                }).withText(bn
                    ? '• রবিবার বিদ্যুৎ বিলের শেষ দিন\n• রহিম চাল ও তেল আনবে\n• আম্মুর চেকআপ বিকেল ৫টায়'
                    : '• Electricity bill due Sunday\n• Rahim brings rice and oil\n• Ammu’s check-up at 5 pm'),
                _n(bn, 'Assisto summary', 'অ্যাসিস্টোর সারাংশ')),
            5),
      ]),
  'p3_chat_reminder': (l) => _chat(l, (bn) {
        final rem = AssistoCard(CardType.reminder, 'r1', {
          'title': _n(bn, 'Pay electricity bill', 'বিদ্যুৎ বিল দিতে হবে'),
          'at': DateTime.now().add(const Duration(days: 1)).copyWith(hour: 9, minute: 0).toUtc().toIso8601String(),
          'scope': 'all',
          'by': _n(bn, 'Rahim', 'রহিম'),
        });
        return [
          _in(encodeCard(rem, 'Reminder'), 0),
          _in(encodeCard(ackCard('r1', _n(bn, 'Nadia', 'নাদিয়া')), 'ack'), 1),
        ];
      }),
  'p3_chat_split': (l) => _chat(l, (bn) => [
        _in(_n(bn, 'Dinner was great!', 'ডিনার দারুণ ছিল!'), 0),
        _out(
            encodeCard(
                splitCard(
                    title: _n(bn, 'Dinner at Kacchi Bhai', 'কাচ্চি ভাইয়ে ডিনার'),
                    totalPoisha: 245000,
                    payer: _n(bn, 'Arif', 'আরিফ'),
                    names: [_n(bn, 'Arif', 'আরিফ'), _n(bn, 'Rahim', 'রহিম'), _n(bn, 'Nadia', 'নাদিয়া')]),
                'split'),
            3),
      ]),
  'p3_chat_list': (l) => _chat(l, (bn) {
        final list = AssistoCard(CardType.list, 'l1', {
          'title': _n(bn, 'Bazar for Friday', 'শুক্রবারের বাজার'),
          'items': bn ? ['চাল ৫ কেজি', 'সয়াবিন তেল', 'ডিম ১২টা', 'পেঁয়াজ'] : ['Rice 5 kg', 'Soybean oil', 'Eggs (12)', 'Onions'],
        });
        return [
          _out(encodeCard(list, 'list'), 0),
          _in(encodeCard(tickCard('l1', 0, true, _n(bn, 'Rahim', 'রহিম')), 't'), 2),
          _in(encodeCard(tickCard('l1', 2, true, _n(bn, 'Rahim', 'রহিম')), 't'), 3),
        ];
      }),
  'p3_chat_scam': (l) => _chat(l, (bn) => [
        _in(_n(bn, 'Hi, this is bKash customer care. Money went to your number by mistake, please send it back.',
            'আমি বিকাশ কাস্টমার কেয়ার থেকে বলছি। ভুল করে আপনার নম্বরে টাকা গেছে, ফেরত দিন।'), 0),
        _in(_n(bn, 'A code just came to your phone — tell me the OTP now', 'আপনার ফোনে একটা কোড গেছে, ওটিপি টা দিন এখনই'), 1),
      ]),
  'p3_chat_safety': (l) => _chat(l, (bn) => [
        _in(encodeCard(AssistoCard(CardType.arrived, 'a1', {
          'place': _n(bn, 'Sylhet bus stand', 'সিলেট বাসস্ট্যান্ড'),
          'at': _at(0),
        }), 'arrived'), 0),
        _in(encodeCard(AssistoCard(CardType.med, 'm1', {
          'missed': [{'name': 'Seclo 20', 'slot': '09:00'}],
          'taken': [{'name': 'Napa', 'slot': '08:00'}],
          'at': _at(30),
        }), 'med'), 30),
      ]),
  'p3_story_viewer': (l) {
    final bn = l == 'bn';
    final ct = _sealed(StoryContent.encodeText(_n(bn, 'Reached Sylhet safely! Tea gardens are beautiful', 'নিরাপদে সিলেট পৌঁছেছি! চা-বাগান খুব সুন্দর'), 1), C3Fake.rahim, C3Fake.me);
    return _withApi(
        l,
        () => const [],
        CircleStatusViewerScreen(
          identity: C3Fake.me,
          authorId: 2,
          authorName: _n(bn, 'Rahim', 'রহিম'),
          authorKey: C3Fake.rahim.publicKey,
          preloaded: [
            {'id': 1, ...ct, 'kind': 'text', 'created_at': _at(60)},
            {'id': 2, ...ct, 'kind': 'text', 'created_at': _at(70)},
          ],
        ));
  },
  'p3_story_privacy': (l) => _withApi(
      l,
      () => const [],
      Scaffold(
        appBar: AppBar(title: Text(l == 'bn' ? 'স্ট্যাটাস' : 'Status')),
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            elevation: 8,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: Builder(builder: (ctx) => StoryPrivacySheet(
              members: _members(l == 'bn'),
              initial: const StoryPrivacy(StoryPrivacy.except, exclude: [4]),
              title: l == 'bn' ? 'স্টোরির প্রাইভেসি' : 'Story privacy',
            )),
          ),
        ),
      )),
  'p3_updates_notes': (l) => _withApi(
      l, () => const [], CircleStatusScreen(identity: C3Fake.me, members: _members(l == 'bn'))),
};

extension on AssistoCard {
  AssistoCard withText(String t) => AssistoCard(type, id, {...data, 'text': t});
}
