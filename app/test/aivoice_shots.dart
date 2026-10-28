// aivoice gallery states for test/screenshots_test.dart: the AI chat with the
// honest no-key banner (welcome + thread), the voice-conversation bar while
// listening / speaking, and the "Turn on Bangla voice" help sheet.
import 'package:flutter/material.dart';

import 'package:assisto/screens/ai_chat_screen.dart';
import 'package:assisto/voice/voice_loop.dart';
import 'package:assisto/widgets/voice_help_sheet.dart';

const _s = {'id': 9, 'title': 'Spending'};

final Map<String, Widget Function(String)> aivoiceShots = {
  'aiv_welcome_nokey': (l) => const AiChatScreen(),
  'aiv_thread_nokey': (l) => const AiChatScreen(initialSession: _s),
  'aiv_conv_listening': (l) => const AiChatScreen(
      initialSession: _s, debugLoopPhase: LoopPhase.listening),
  'aiv_conv_speaking': (l) => const AiChatScreen(
      initialSession: _s, debugLoopPhase: LoopPhase.speaking),
  'aiv_voice_help': (l) => const Scaffold(body: VoiceHelpSheet()),
};
