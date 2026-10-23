// cde-chat (owner order 6 C/D/E) gallery states for test/screenshots_test.dart:
// themed 1:1 chats (real E2E ciphertext, the theme + nickname arrive as
// control messages and show as system lines), the theme picker (Free with
// locks / Premium with the AI entry), the Nicknames sheet, and the video call
// stage (normal / swapped / full screen).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/api.dart';
import 'package:assisto/calls/call_controller.dart';
import 'package:assisto/messaging/chat_decor/chat_control.dart';
import 'package:assisto/messaging/chat_decor/decor_sheets.dart';
import 'package:assisto/models.dart';
import 'package:assisto/screens/circle_call_screen.dart';
import 'package:assisto/screens/circle_chat_screen.dart';
import 'package:assisto/state.dart';

import 'c2_calls_fakes.dart';
import 'fake_c3_msg.dart';

String _n(bool bn, String en, String b) => bn ? b : en;

class _CdeApi extends ApiClient {
  _CdeApi(this.bn, this.id, this.theme) {
    token = 'shot';
  }
  final bool bn;
  final int id;
  final String theme;

  @override
  Future<Map<String, dynamic>> getJson(String path) async {
    final p = path.split('?').first;
    if (p == '/circle/$id/messages') return {'results': _msgs(bn, theme), 'has_more': false};
    if (p == '/circle/keys/peer/$id') {
      return {'public_key': C3Fake.pub(C3Fake.rahim), 'history': const []};
    }
    if (p == '/circle/decor/member/$id') {
      return {
        'theme': {'id': theme, 'at_ms': 1000 + id, 'by_me': false},
        'nick_peer': _n(bn, 'Bhaiya', 'ভাইয়া'),
        'nick_me': '',
        'nick_at': {'peer': 900, 'me': 0},
        'premium': true,
      };
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

DateTime get _base => DateTime.now().subtract(const Duration(hours: 1));

List<Map<String, dynamic>> _msgs(bool bn, String theme) {
  var i = 0;
  Map<String, dynamic> m(String text, {required bool mine, String status = 'read'}) {
    i++;
    return {
      'id': 600 + i,
      'sender_id': mine ? 1 : 2,
      'mine': mine,
      if (mine) 'status': status,
      'content_type': 'text',
      'created_at': _base.add(Duration(minutes: i * 3)).toUtc().toIso8601String(),
      ...C3Fake.env(text, mine ? C3Fake.me : C3Fake.rahim, mine ? C3Fake.rahim : C3Fake.me),
    };
  }

  final rahim = _n(bn, 'Rahim', 'রহিম');
  return [
    m(_n(bn, 'Happy anniversary to both of you!', 'তোমাদের দুজনকে বিবাহবার্ষিকীর শুভেচ্ছা!'), mine: false),
    m(encodeControl(ChatControl.theme(theme, at: 1000), '$rahim changed the theme'), mine: false),
    m(encodeControl(ChatControl.nick(who: 'sender', name: _n(bn, 'Bhaiya', 'ভাইয়া'), at: 900),
        '$rahim set their nickname'), mine: false),
    m(_n(bn, 'Thank you! The new theme looks lovely', 'ধন্যবাদ! নতুন থিমটা দারুণ লাগছে'), mine: true),
    m(_n(bn, 'Dinner at our place on Friday?', 'শুক্রবার আমাদের বাসায় রাতের খাবার?'), mine: false),
    m(_n(bn, 'Yes, we will come at 8', 'হ্যাঁ, ৮টায় আসব'), mine: true, status: 'delivered'),
  ];
}

Widget _withApi(String l, _CdeApi api, Widget child) {
  final s = AppState();
  s.api = api;
  s.user = AppUser(
      id: 1, name: l == 'bn' ? 'আরিফ' : 'Arif', phone: '01712345678', email: '',
      autonomyLevel: 2, language: l);
  s.locale = Locale(l);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(value: s, child: child);
}

Widget _chat(String l, int id, String theme) => _withApi(
    l,
    _CdeApi(l == 'bn', id, theme),
    CircleChatScreen(member: {
      'id': id,
      'name': l == 'bn' ? 'রহিম' : 'Rahim',
      'relation': 'friend',
      'state': 'accepted',
      'public_key': C3Fake.pub(C3Fake.rahim),
    }, identity: C3Fake.me));

Widget _sheet(Widget child) => Scaffold(
      backgroundColor: const Color(0xFF5A5F66),
      body: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          elevation: 8,
          clipBehavior: Clip.antiAlias,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: Padding(padding: const EdgeInsets.only(top: 24), child: child),
        ),
      ),
    );

Widget _call(String l, {bool swapped = false, bool full = false, bool remoteCamera = true}) {
  final c = previewController(
      video: true, outgoing: true, phase: CallPhase.connected, remoteCamera: remoteCamera);
  return CircleCallScreen(
    member: {
      'id': 1,
      'name': l == 'bn' ? 'নাদিয়া রহমান' : 'Nadia Rahman',
      'nickname': l == 'bn' ? 'নাদু' : 'Nadu',
    },
    kind: 'video',
    controller: c,
    surface: FakeSurface(),
    previewSwapped: swapped,
    previewFullscreen: full,
  );
}

final Map<String, Widget Function(String)> cdeShots = {
  'cde_chat_love': (l) => _chat(l, 81, 'love'),
  'cde_chat_moonlight': (l) => _chat(l, 82, 'moonlight'),
  'cde_chat_eid': (l) => _chat(l, 83, 'eid'),
  'cde_chat_birthday': (l) => _chat(l, 84, 'birthday'),
  'cde_chat_anniversary': (l) => _chat(l, 85, 'anniversary'),
  'cde_chat_calm': (l) => _chat(l, 86, 'calm'),
  'cde_theme_sheet_free': (l) => _sheet(const ChatThemeSheet(currentId: 'love', premium: false)),
  'cde_theme_sheet_premium': (l) => _sheet(ChatThemeSheet(
      currentId: 'eid', premium: true, aiAvailable: true, aiCredits: l == 'bn' ? '২০' : '20')),
  'cde_nick_sheet': (l) => _sheet(NicknamesSheet(rows: [
        NickRow(
            slot: 'peer',
            realName: l == 'bn' ? 'রহিম উদ্দিন' : 'Rahim Uddin',
            nick: l == 'bn' ? 'ভাইয়া' : 'Bhaiya'),
        NickRow(slot: 'me', realName: l == 'bn' ? 'আরিফ' : 'Arif', nick: '', isMe: true),
      ])),
  'cde_call_video': (l) => _call(l),
  'cde_call_swapped': (l) => _call(l, swapped: true),
  'cde_call_full': (l) => _call(l, full: true),
  'cde_call_their_camera_off': (l) => _call(l, remoteCamera: false),
};
