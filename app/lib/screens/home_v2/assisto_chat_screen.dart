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
  // aifinal (owner AI chat history order 4 Nov 00:33): opening Assisto AI
  // (cold start, or coming back from any other screen) = a NEW empty chat;
  // only an explicitly chosen chat (History / side panel) is reopened.
  late bool _fresh = widget.fresh || widget.sessionId == null;
  late String? _send = widget.initialSend;
  final _scaffold = GlobalKey<ScaffoldState>();

  // Rule (b): another app screen was pushed OVER this chat and the user came
  // back -> new chat. A short trip outside the app (call, copying text) does
  // not touch the route stack, so the same chat stays (the exception);
  // sheets / dialogs do not cover the page either.
  Animation<double>? _cover;
  bool _covered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final a = ModalRoute.of(context)?.secondaryAnimation;
    if (a != _cover) {
      _cover?.removeStatusListener(_onCover);
      _cover = a;
      _cover?.addStatusListener(_onCover);
    }
  }

  void _onCover(AnimationStatus st) {
    if (st == AnimationStatus.completed) {
      _covered = true;
    } else if (st == AnimationStatus.dismissed && _covered) {
      _covered = false;
      if (mounted) _newChat();
    }
  }

  @override
  void dispose() {
    _cover?.removeStatusListener(_onCover);
    super.dispose();
  }

  void _newChat() => setState(() {
        _threadKey = UniqueKey();
        _sessionId = null;
        _fresh = true;
        _send = null;
      });

  void _openChat(String id) => setState(() {
        _threadKey = UniqueKey();
        _sessionId = id;
        _fresh = false;
        _send = null;
      });

  List<String> _starters(AppLocalizations t) =>
      [t.aiStarter1, t.aiStarter2, t.aiStarter3, t.aiStarter4];

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      key: _scaffold,
      resizeToAvoidBottomInset: true,
      // the side panel: labelled New chat, Search, chats newest first,
      // pinned on top, long-press / menu pin / rename / delete
      drawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.86,
        child: AssistoChatsScreen(
          inPanel: true,
          onNewHomeChat: () {
            _scaffold.currentState?.closeDrawer();
            _newChat();
          },
          onOpenHomeChat: (id) {
            _scaffold.currentState?.closeDrawer();
            _openChat(id);
          },
        ),
      ),
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('hv2_chat_history'),
          tooltip: t.aiChatsPanel,
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => _scaffold.currentState?.openDrawer(),
        ),
        title: Text(t.aichatTitle,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            key: const ValueKey('hv2_chat_new'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.add_comment_outlined),
            label: Text(t.newChat, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: _newChat,
          ),
        ],
      ),
      body: AgentThreadScreen(
        key: _threadKey,
        sessionId: _sessionId,
        fresh: _fresh,
        initialSend: _send,
        starters: _starters(t),
        showLevels: true,
      ),
    );
  }
}
