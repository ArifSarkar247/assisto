import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/chat_session_actions.dart';
import '../widgets/ladder_common.dart' show fmtInt;
import 'ai_chat_screen.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// Lets the Assisto AI chats page reach the HOME chat (the app's main chat)
/// even when it was opened from a generic route (the home "Assisto AI" quick
/// shortcut via ChatNav). [HomeScreen] registers itself while mounted.
class HomeChatLink {
  HomeChatLink._();
  static VoidCallback? newChat;
  static void Function(String sessionId)? openChat;

  static void register(
      {required VoidCallback onNew, required void Function(String) onOpen}) {
    newChat = onNew;
    openChat = onOpen;
  }

  static void unregister(VoidCallback onNew) {
    if (newChat == onNew) {
      // method tear-offs compare equal
      newChat = null;
      openChat = null;
    }
  }
}

/// "Assisto AI" — the ONE place for every saved chat (owner order after build
/// 146; replaces the sidebar chat list that kept growing).
///
/// * "New chat" at the top starts a fresh chat on HOME (home stays the main
///   chat). Without a home (e.g. elderly mode) it opens a new [AiChatScreen].
/// * Below: every previous chat — home-source and Assisto-AI-source — pinned
///   first, then newest. Search (title + server-side message text), and per
///   row rename / pin / delete.
/// * Tapping a home chat reopens it on home; an AI chat opens [AiChatScreen]
///   on that session.
class AssistoChatsScreen extends StatefulWidget {
  /// Explicit home hooks (the drawer passes them); otherwise [HomeChatLink].
  final VoidCallback? onNewHomeChat;
  final void Function(String sessionId)? onOpenHomeChat;
  const AssistoChatsScreen(
      {super.key, this.onNewHomeChat, this.onOpenHomeChat});

  @override
  State<AssistoChatsScreen> createState() => _AssistoChatsScreenState();
}

class _AssistoChatsScreenState extends State<AssistoChatsScreen> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  String _q = '';
  // Server-side search hits (message text) for [_hitsFor].
  Set<String> _hits = const {};
  String _hitsFor = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final rows = await context.read<AppState>().api.chatSessions();
      if (mounted) setState(() => _rows = ChatSessionActions.sort(rows));
    } catch (e) {
      if (mounted) setState(() {
        _failed = true;
        _failCause = e;
      });
    }
  }

  void _onSearch(String v) {
    setState(() => _q = v);
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final rows = await context.read<AppState>().api.chatSessions(query: q);
        if (!mounted || _q.trim() != q) return;
        setState(() {
          _hits = {for (final r in rows) '${r['id']}'};
          _hitsFor = q;
        });
      } catch (_) {/* best-effort: local title search still works */}
    });
  }

  VoidCallback? get _homeNew => widget.onNewHomeChat ?? HomeChatLink.newChat;
  void Function(String)? get _homeOpen =>
      widget.onOpenHomeChat ?? HomeChatLink.openChat;

  void _backToHome() => Navigator.of(context).popUntil((r) => r.isFirst);

  void _newChat() {
    final home = _homeNew;
    if (home != null) {
      _backToHome();
      home();
    } else {
      _pushAi(null);
    }
  }

  Future<void> _pushAi(Map<String, dynamic>? row) async {
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => AiChatScreen(initialSession: row)));
    if (mounted) _load(); // titles / new chats may have changed
  }

  void _open(Map<String, dynamic> row) {
    final open = _homeOpen;
    if (ChatSessionActions.source(row) == 'home' && open != null) {
      _backToHome();
      open('${row['id']}');
    } else {
      _pushAi(row);
    }
  }

  Future<void> _rename(Map<String, dynamic> row) async {
    final name =
        await ChatSessionActions.askRename(context, '${row['title'] ?? ''}');
    if (name == null || !mounted) return;
    try {
      await context
          .read<AppState>()
          .api
          .chatUpdateSession('${row['id']}', title: name);
      if (mounted) setState(() => row['title'] = name);
    } catch (_) {
      _failSnack();
    }
  }

  Future<void> _pin(Map<String, dynamic> row) async {
    final pinned = row['pinned'] != true;
    try {
      await context
          .read<AppState>()
          .api
          .chatUpdateSession('${row['id']}', pinned: pinned);
      if (!mounted) return;
      setState(() {
        row['pinned'] = pinned;
        ChatSessionActions.sort(_rows!);
      });
    } catch (_) {
      _failSnack();
    }
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    if (!await ChatSessionActions.confirmDelete(context) || !mounted) return;
    try {
      await context.read<AppState>().api.chatDeleteSession('${row['id']}');
      if (mounted) setState(() => _rows!.remove(row));
    } catch (_) {
      _failSnack();
    }
  }

  void _failSnack() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context).aichatLoadFailed)));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.auto_awesome, color: scheme.primary, size: 22),
          const SizedBox(width: Gap.sm),
          Flexible(
              child: Text(t.aichatTitle,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.sm),
          child: FilledButton.icon(
            key: const ValueKey('chats_new_chat'),
            onPressed: _newChat,
            icon: const Icon(Icons.add_comment_outlined, size: 20),
            label:
                Text(t.newChat, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Radii.md))),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.xs),
          child: TextField(
            key: const ValueKey('chats_search'),
            controller: _searchCtrl,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: t.aichatSearchHint,
              suffixIcon: _q.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t.aichatCancel,
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        _onSearch('');
                      },
                    ),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Radii.md)),
            ),
          ),
        ),
        Expanded(child: _body(t, scheme)),
      ]),
    );
  }

  Widget _body(AppLocalizations t, ColorScheme scheme) {
    if (_rows == null && !_failed) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(honestFailText(t, _failCause, otherwise: t.aichatLoadFailed), textAlign: TextAlign.center),
            const SizedBox(height: Gap.md),
            FilledButton.tonal(onPressed: _load, child: Text(t.aichatRetry)),
          ]),
        ),
      );
    }
    final q = _q.trim();
    final rows = _rows!
        .where((r) =>
            ChatSessionActions.matches(r, q) ||
            (q.isNotEmpty && q == _hitsFor && _hits.contains('${r['id']}')))
        .toList();
    if (rows.isEmpty) {
      final searching = q.isNotEmpty;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(searching ? Icons.search_off : Icons.chat_bubble_outline,
                size: 40, color: scheme.onSurfaceVariant),
            const SizedBox(height: Gap.md),
            Text(searching ? t.aichatNoSearchResults : t.aichatNoChats,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (!searching) ...[
              const SizedBox(height: Gap.xs),
              Text(t.aichatNoChatsBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ]),
        ),
      );
    }
    final pinned = rows.where((r) => r['pinned'] == true).toList();
    final rest = rows.where((r) => r['pinned'] != true).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).padding.bottom + Gap.lg),
        children: [
          if (pinned.isNotEmpty) ...[
            _header(t.p1ChatsPinned, scheme),
            for (final r in pinned) _row(t, scheme, r),
          ],
          if (rest.isNotEmpty) ...[
            if (pinned.isNotEmpty) _header(t.p1ChatsRecent, scheme),
            for (final r in rest) _row(t, scheme, r),
          ],
        ],
      ),
    );
  }

  Widget _header(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xs),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: scheme.onSurfaceVariant)),
      );

  Widget _row(AppLocalizations t, ColorScheme scheme, Map<String, dynamic> r) {
    final home = ChatSessionActions.source(r) == 'home';
    final title = (r['title'] ?? '').toString().trim();
    final pinned = r['pinned'] == true;
    final when = _relative('${r['updated'] ?? r['updated_at'] ?? ''}');
    final sub = [
      home ? t.p1ChatsSourceHome : t.aichatTitle,
      if (when.isNotEmpty) when,
    ].join(' · ');
    return ListTile(
      key: ValueKey('chat_row_${r['id']}'),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor:
            home ? scheme.secondaryContainer : scheme.primaryContainer,
        child: Icon(home ? Icons.chat_bubble_outline : Icons.auto_awesome,
            size: 18,
            color:
                home ? scheme.onSecondaryContainer : scheme.onPrimaryContainer),
      ),
      title: Text(title.isEmpty ? t.aichatUntitled : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _open(r),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (pinned) Icon(Icons.push_pin, size: 16, color: scheme.primary),
        PopupMenuButton<String>(
          key: ValueKey('chat_menu_${r['id']}'),
          tooltip: t.aichatHistory,
          icon: Icon(Icons.more_vert, color: scheme.onSurfaceVariant),
          onSelected: (v) {
            if (v == 'rename') _rename(r);
            if (v == 'pin') _pin(r);
            if (v == 'delete') _delete(r);
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'rename', child: Text(t.aichatRename)),
            PopupMenuItem(
                value: 'pin',
                child: Text(pinned ? t.aichatUnpin : t.aichatPin)),
            PopupMenuItem(value: 'delete', child: Text(t.aichatDelete)),
          ],
        ),
      ]),
    );
  }

  // Relative time ("5m ago" / "5 minutes ago" in Bangla), Bangla-digit aware.
  String _relative(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return '';
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return '';
    final t = AppLocalizations.of(context);
    if (diff.inHours < 1)
      return t.p1ChatsAgoMin(fmtInt(context, diff.inMinutes));
    if (diff.inDays < 1) return t.p1ChatsAgoHour(fmtInt(context, diff.inHours));
    return t.p1ChatsAgoDay(fmtInt(context, diff.inDays));
  }
}
