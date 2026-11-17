// gap-aichat gallery state for test/screenshots_test.dart: Assisto AI with a
// long answer cut at its length limit — it ends at a full sentence, the
// honest "paused here, no credits" hint and the 48dp Continue under it.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:assisto/models.dart';
import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/state.dart';

import 'fake_api.dart';

class _CutApi extends FakeApi {
  _CutApi(String lang) : super(mode: FakeMode.data, lang: lang);
  bool get _b => lang == 'bn';

  @override
  Future<Map<String, dynamic>> chatStatus() async =>
      {'ai_available': true, 'reason': null, 'free': const []};

  @override
  Future<List<Map<String, dynamic>>> chatMessages(String sessionId) async => [
        {'id': 1, 'role': 'user', 'meta': {}, 'text': _b
            ? 'ঢাকায় ছোট চায়ের দোকান শুরু করার পুরো পরিকল্পনা লিখে দাও'
            : 'Write a full plan to start a small tea stall in Dhaka'},
        {'id': 2, 'role': 'assistant', 'text': _b
            ? '**সারাংশ:** প্রথম মাসে মোটামুটি ৳৩০,০০০ লাগে; জায়গা ঠিক হলে দোকান দিনে ৳১,৫০০–৳২,৫০০ বিক্রি করতে পারে।\n\n'
              '## ধাপগুলো\n১. **জায়গা বাছাই:** অফিস, স্কুল বা বাসস্ট্যান্ডের কাছে ভাড়া নিন।\n'
              '২. **ট্রেড লাইসেন্স:** সিটি কর্পোরেশনের অফিসে আবেদন করুন।'
            : '**Summary:** expect about 30,000 taka in the first month; a good spot can sell 1,500–2,500 taka a day.\n\n'
              '## Steps\n1. **Pick the spot:** rent near an office, a school or a bus stand.\n'
              '2. **Trade licence:** apply at the city corporation office.',
         'meta': {'source': 'ai', 'credits': 1, 'balance': 19, 'cut': true,
           'continue_free': true, 'level': 'normal', 'ai_generated': true}},
      ];
}

Widget _cut(String l) {
  final s = AppState();
  s.api = _CutApi(l);
  s.user = AppUser(id: 1, name: l == 'bn' ? 'রহিম' : 'Rahim', phone: '01712345678',
      email: '', autonomyLevel: 2, language: l);
  s.locale = Locale(l);
  s.loading = false;
  return ChangeNotifierProvider<AppState>.value(
    value: s,
    child: const Scaffold(
        body: AiChatScreen(initialSession: {'id': 41, 'title': 'Tea stall'})),
  );
}

final Map<String, Widget Function(String)> gapAichatShots = {
  'gap_aichat_cut_continue': _cut,
};
