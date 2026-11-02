// aibar gallery states for test/screenshots_test.dart: the home chat thread
// with a keyed-AI answer showing the credits it really took + the balance
// after, and a turn that did not go out (text kept + "Send again").
import 'package:flutter/material.dart';

import 'package:assisto/screens/agent_thread_screen.dart';

List<Map<String, dynamic>> _seed(String l) {
  final bn = l == 'bn';
  return [
    {'user': true, 'text': bn ? 'ফ্রান্সের রাজধানী কোনটা?' : 'What is the capital of France?'},
    {'user': false, 'id': 70,
     'text': bn ? 'ফ্রান্সের রাজধানী প্যারিস।' : 'The capital of France is Paris.',
     'meta': {'source': 'ai', 'credits': 2, 'balance': 148}},
    {'user': true, 'failed': true,
     'text': bn ? 'আর জাপানের রাজধানী?' : 'And the capital of Japan?'},
  ];
}

final Map<String, Widget Function(String)> aibarShots = {
  'aibar_home_credit_failed': (l) =>
      Scaffold(body: AgentThreadScreen(debugSeed: _seed(l))),
};
