import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../agent_thread_screen.dart';
import '../assisto_chats_screen.dart';

/// home_v2: the Assisto AI chat moved from the home body to its own screen
/// (owner order). It is the SAME conversation engine the old home embedded
/// ([AgentThreadScreen]: the remembered home thread, suggestions in the empty
/// state, voice dictation in the input, photo questions, cards, credits) —
/// plus History (every saved chat, [AssistoChatsScreen]) and New chat.
///
/// Opening a saved home chat from History pops back to the home, which
/// re-opens this screen on that chat (HomeChatLink is registered by the home).
class AssistoChatScreen extends StatefulWidget {
  final String? sessionId;
  final bool fresh;
  final String? initialSend;
  const AssistoChatScreen(
      {super.key, this.sessionId, this.fresh = false, this.initialSend});

  static const routeName = 'assisto_chat';

  @override
  State<AssistoChatScreen> createState() => _AssistoChatScreenState();
}

class _AssistoChatScreenState extends State<AssistoChatScreen> {
  Key _threadKey = UniqueKey();
  late String? _sessionId = widget.sessionId;
  late bool _fresh = widget.fresh;
  late String? _send = widget.initialSend;

  void _newChat() => setState(() {
        _threadKey = UniqueKey();
        _sessionId = null;
        _fresh = true;
        _send = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(t.aichatTitle,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('hv2_chat_history'),
            tooltip: t.aichatHistory,
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AssistoChatsScreen(),
                    settings: const RouteSettings(name: 'ai_chat'))),
          ),
          IconButton(
            key: const ValueKey('hv2_chat_new'),
            tooltip: t.newChat,
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _newChat,
          ),
        ],
      ),
      body: AgentThreadScreen(
        key: _threadKey,
        sessionId: _sessionId,
        fresh: _fresh,
        initialSend: _send,
      ),
    );
  }
}
