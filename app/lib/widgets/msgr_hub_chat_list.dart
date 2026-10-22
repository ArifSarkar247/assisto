import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../messenger_hub_api.dart';
import '../state.dart';
import '../theme.dart';
import 'loading_gate.dart';
import '../screens/circle_chat_screen.dart';
import '../screens/circle_group_chat_screen.dart';
import '../messaging/c3_api.dart';
import '../messaging/chat_preview.dart';
import '../messaging/msg_notify.dart';
import '../messaging/msg_ticks.dart';
import '../messaging/presence_label.dart';
import '../messaging/receipt_bus.dart';
import '../messaging/unread_store.dart';
import '../realtime/realtime_channel.dart';
import 'msgr_avatar.dart';
import 'robo_id.dart';

/// MY CIRCLE HUB — the Chats tab (SPEC .phaseB/MESSENGER_UI_FULL.md §2).
///
/// Owns the hub's search bar ("Ask Assisto or search") and the filter-chip row
/// (All · Unread · Favourites · Groups + the user's own lists from the backend
/// list endpoint). Both narrow the chat list live. Tapping a row opens the
/// existing E2E 1:1 thread ([CircleChatScreen]) — we reuse the thread, never
/// duplicate it. ORIGINAL Assisto visuals: brand tokens + our own icons/wording
/// (never a WhatsApp/Meta copy).
///
/// The "Ask Assisto" intent: when the query starts with "ask assisto" we keep
/// the list filtered to the remaining text for now and hint the agent handoff
/// (the agent route lands later) — honest, never a dead action.
class MsgrHubChatList extends StatefulWidget {
  final IdentityKeyPair? identity;
  final List<Map<String, dynamic>> members;

  /// m3-circle: shown above the list (incoming My Circle requests).
  final Widget? header;

  /// m3-circle: bump to reload (e.g. after a request was accepted).
  final int refreshToken;

  /// m3-circle: the empty state offers "Add to My Circle".
  final VoidCallback? onAdd;
  const MsgrHubChatList(
      {super.key,
      required this.identity,
      required this.members,
      this.header,
      this.refreshToken = 0,
      this.onAdd});

  @override
  State<MsgrHubChatList> createState() => _MsgrHubChatListState();
}

class _MsgrHubChatListState extends State<MsgrHubChatList> {
  // Pin cap — mirrors msg_organise.PIN_CAP_PER_USER (server-enforced).
  static const int _pinCap = 5;

  bool _loading = true;
  String _query = '';

  /// Active filter: a built-in id ('all'|'unread'|'favourites'|'groups') or a
  /// custom list id prefixed 'list:'.
  String _filter = 'all';

  /// When true the list shows the ARCHIVED chats (an unarchive view) instead of
  /// the active list. Toggled from the "Archived (n)" banner.
  bool _showArchived = false;

  List<Map<String, dynamic>> _chats = [];
  bool _loadFailed = false;
  List<Map<String, dynamic>> _lists = [];

  /// c3-msg: decrypted previews, cached per (row id, last message id) so a
  /// reload never re-runs X25519 for an unchanged row.
  final Map<String, ChatPreview> _previews = {};
  final _e2e = SoftwareE2E();
  final _rt = RealtimeChannel.instance;

  @override
  void initState() {
    super.initState();
    _rt.acquire();
    _rt.states.addListener(_onRt);
    _load();
    // x2-ticks: my last message's tick updates live (no list reload); a
    // new message for me reloads the list at once.
    _rcptSub = ReceiptBus.instance.updates.listen(_onReceipt);
    _newSub = ReceiptBus.instance.newMessages.listen((_) {
      if (mounted) _load();
    });
  }

  StreamSubscription<ReceiptUpdate>? _rcptSub;
  StreamSubscription<String>? _newSub;

  void _onReceipt(ReceiptUpdate u) {
    if (!mounted) return;
    var changed = false;
    for (final c in _chats) {
      final last = c['last'];
      if (last is! Map || last['mine'] != true || _key(c) != u.chat) continue;
      final s = u.statuses['${last['id']}'];
      if (s == null) continue;
      final merged = mergeStatus('${last['status'] ?? 'sent'}', s);
      if (merged != '${last['status'] ?? 'sent'}') {
        try {
          last['status'] = merged;
          changed = true;
        } catch (_) {} // an unmodifiable (test) row
      }
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    _rcptSub?.cancel(); // x2-ticks
    _newSub?.cancel();
    _rt.states.removeListener(_onRt);
    _rt.release();
    super.dispose();
  }

  void _onRt() {
    if (mounted) setState(() {});
  }

  /// 'member:<edge id>' / 'group:<group id>' — the key shared with the
  /// realtime channel, the unread store and the notifications.
  String _key(Map<String, dynamic> c) => _isGroup(c)
      ? 'group:${c['group_id'] ?? (c['group'] as Map?)?['id'] ?? ''}'
      : 'member:${c['id']}';

  bool _isGroup(Map<String, dynamic> c) =>
      c['is_group'] == true || c['kind'] == 'group';

  int _groupId(Map<String, dynamic> c) =>
      int.tryParse('${c['group_id'] ?? (c['group'] as Map?)?['id'] ?? ''}') ?? 0;

  ChatPreview _preview(Map<String, dynamic> c) {
    final last = c['last'] as Map?;
    final ck = '${_key(c)}|${last?['id']}|${last?['status']}|${last?['deleted']}'
        '|${widget.identity?.keyId}';
    return _previews.putIfAbsent(
        ck, () => ChatPreview.fromRow(c, identity: widget.identity, e2e: _e2e));
  }

  void _publishUnread() {
    UnreadStore.instance.setAll({
      for (final c in _chats)
        if (!_isArchived(c) && ChatPreview.unreadOf(c) > 0)
          _key(c): ChatPreview.unreadOf(c),
    });
  }

  @override
  void didUpdateWidget(covariant MsgrHubChatList old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken) _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final r = await loadGuard(_api.getJson('/circle/chats'));
      _chats = ((r['results'] ?? r['chats'] ?? const []) as List)
          .cast<Map<String, dynamic>>();
      _loadFailed = false;
      _publishUnread();
    } catch (_) {
      // Honest error + retry (no synthesised rows posing as real chats).
      _loadFailed = true;
    }
    try {
      _lists = await loadGuard(_api.hubCustomLists());
    } catch (_) {
      _lists = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic> _memberOf(Map<String, dynamic> c) =>
      (c['member'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool _matchesFilter(Map<String, dynamic> c) {
    switch (_filter) {
      case 'all':
        return true;
      case 'unread':
        return ChatPreview.unreadOf(c) > 0;
      case 'favourites':
        return c['favourite'] == true || c['is_favourite'] == true;
      case 'groups':
        return c['is_group'] == true || c['group'] == true;
      default:
        if (_filter.startsWith('list:')) {
          final id = _filter.substring(5);
          final ids = (c['lists'] as List?)?.map((e) => '$e').toList() ??
              const <String>[];
          return ids.contains(id);
        }
        return true;
    }
  }

  bool _isArchived(Map<String, dynamic> c) => c['archived'] == true;
  bool _isPinned(Map<String, dynamic> c) => c['pinned'] == true;
  int _pinnedCount() => _chats.where(_isPinned).length;

  String _foldedQuery() {
    var q = _query.trim().toLowerCase();
    // "Ask Assisto" prefix → strip it; the remaining text filters the list
    // (the agent handoff lands later — we never dead-end the tap).
    if (q.startsWith('ask assisto')) q = q.substring('ask assisto'.length).trim();
    return q;
  }

  /// The chats visible in the CURRENT view (active vs archived), after the
  /// filter chip + the search query, ordered with pinned chats floated to the
  /// top (by pin time) then the rest by recent activity — mirrors
  /// msg_organise.order_chat_list.
  List<Map<String, dynamic>> get _visible {
    final q = _foldedQuery();
    var list = _chats
        .where((c) => _isArchived(c) == _showArchived)
        .where(_matchesFilter)
        .toList();
    if (q.isNotEmpty) {
      list = list.where((c) {
        final name = _nameOf(c).toLowerCase();
        final last = _preview(c).text.toLowerCase();
        return name.contains(q) || last.contains(q);
      }).toList();
    }

    int activityCmp(Map<String, dynamic> a, Map<String, dynamic> b) {
      final ta = DateTime.tryParse('${a['at'] ?? ''}');
      final tb = DateTime.tryParse('${b['at'] ?? ''}');
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    }

    // Pinning is disabled in the archived view (a chat can't be both).
    if (_showArchived) {
      list.sort(activityCmp);
      return list;
    }
    final pinned = list.where(_isPinned).toList()
      ..sort((a, b) {
        final pa = DateTime.tryParse('${a['pin_at'] ?? ''}');
        final pb = DateTime.tryParse('${b['pin_at'] ?? ''}');
        if (pa == null && pb == null) return 0;
        if (pa == null) return 1; // unknown pin time sinks below known ones
        if (pb == null) return -1;
        return pa.compareTo(pb); // earliest-pinned at the very top
      });
    final rest = list.where((c) => !_isPinned(c)).toList()..sort(activityCmp);
    return [...pinned, ...rest];
  }

  int get _archivedCount => _chats.where(_isArchived).length;

  /// True when the user is actively searching but nothing matched — drives a
  /// no-results state distinct from an empty list (mirrors the server
  /// msg_organise.search_chats 'no_results' state).
  bool get _isNoResults => _foldedQuery().isNotEmpty && _visible.isEmpty;

  String _nameOf(Map<String, dynamic> c) => _isGroup(c)
      ? '${(c['group'] as Map?)?['name'] ?? _memberOf(c)['name'] ?? ''}'
      : '${_memberOf(c)['name'] ?? ''}';

  /// UNREAD-BADGE FIX: opening a chat clears the row, the tab badge and the
  /// app-icon badge source in the SAME frame, cancels that chat's
  /// notification, and tells the server (receipts + read_by → other devices
  /// and the sender's blue ✓✓). The chat screen repeats the server call on
  /// open, so a failure here is healed there.
  void _clearUnreadLocal(Map<String, dynamic> c) {
    setState(() {
      c['unread'] = 0;
      c['marked_unread'] = false;
    });
    UnreadStore.instance.clear(_key(c));
    final kind = _isGroup(c) ? 'group' : 'member';
    final id = _isGroup(c) ? _groupId(c) : _chatId(c);
    if (id != null) unawaited(FlnMsgSink().cancel(kind, id));
  }

  Future<void> _openChat(Map<String, dynamic> c) async {
    // Never a silent no-op: if the hub has no identity yet, wait for the
    // vault (secure storage or its encrypted fallback; never null).
    final identity = widget.identity ?? await IdentityVault.instance.get();
    if (!mounted) return;
    _clearUnreadLocal(c);
    final Widget screen;
    if (_isGroup(c)) {
      final g = Map<String, dynamic>.from((c['group'] as Map?) ?? const {});
      g['id'] ??= _groupId(c);
      screen = CircleGroupChatScreen(
          group: g, identity: identity, circleMembers: widget.members);
    } else {
      screen = CircleChatScreen(member: _memberOf(c), identity: identity);
    }
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen))
        .then((_) => _load());
  }

  // -------------------------------------------------------------------------
  // Chat organise (#87): pin / archive / mute — per-row long-press sheet.
  // Every action updates optimistically then posts; a failure keeps the honest
  // local state and never crashes (offline-safe, like the rest of the hub).
  // -------------------------------------------------------------------------
  int? _chatId(Map<String, dynamic> c) =>
      (c['id'] is int) ? c['id'] as int : int.tryParse('${c['id'] ?? ''}');

  Future<void> _togglePin(Map<String, dynamic> c) async {
    final pinning = !_isPinned(c);
    if (pinning && _pinnedCount() >= _pinCap) {
      _toast(_t.msgrChatPinLimit);
      return;
    }
    setState(() {
      c['pinned'] = pinning;
      c['pin_at'] = pinning ? DateTime.now().toUtc().toIso8601String() : null;
    });
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/pin', {'pinned': pinning});
    } catch (_) {
      // m3-circle: never silent — undo the optimistic change and say so.
      if (mounted) {
        setState(() => c['pinned'] = !pinning);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _toggleArchive(Map<String, dynamic> c) async {
    final archiving = !_isArchived(c);
    setState(() {
      c['archived'] = archiving;
      if (archiving) {
        c['pinned'] = false; // a chat can't be both pinned-to-top and archived
        c['pin_at'] = null;
      }
    });
    _toast(archiving ? _t.msgrChatArchived : _t.msgrChatUnarchived);
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/archive', {'archived': archiving});
    } catch (_) {
      if (mounted) {
        setState(() => c['archived'] = !archiving);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _muteChat(Map<String, dynamic> c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final t = _t;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xs),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(t.msgrChatMute,
                      style: Theme.of(ctx).textTheme.titleMedium),
                ),
              ),
              ListTile(title: Text(t.msgrChatMute8h), onTap: () => Navigator.pop(ctx, '8h')),
              ListTile(title: Text(t.msgrChatMute1w), onTap: () => Navigator.pop(ctx, '1w')),
              ListTile(title: Text(t.msgrChatMuteAlways), onTap: () => Navigator.pop(ctx, 'always')),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    setState(() => c['muted'] = true);
    _toast(_t.msgrChatMuted);
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/mute', {'duration': choice});
    } catch (_) {
      if (mounted) {
        setState(() => c['muted'] = false);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _unmuteChat(Map<String, dynamic> c) async {
    setState(() => c['muted'] = false);
    _toast(_t.msgrChatUnmuted);
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/mute', {'duration': 'off'});
    } catch (_) {
      if (mounted) {
        setState(() => c['muted'] = true);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _markRead(Map<String, dynamic> c) async {
    _clearUnreadLocal(c);
    final kind = _isGroup(c) ? 'group' : 'member';
    final id = _isGroup(c) ? _groupId(c) : _chatId(c);
    if (id == null) return;
    try {
      await _api.c3MarkUnread(kind, id, false);
    } catch (_) {
      if (mounted) _toast(_t.grpActionFailed);
    }
  }

  /// WhatsApp "Mark as unread": the messages stay read for the sender; the
  /// row (and badges) show 1 until the chat is opened again.
  Future<void> _markUnread(Map<String, dynamic> c) async {
    setState(() => c['marked_unread'] = true);
    UnreadStore.instance.set(_key(c), ChatPreview.unreadOf(c));
    final kind = _isGroup(c) ? 'group' : 'member';
    final id = _isGroup(c) ? _groupId(c) : _chatId(c);
    if (id == null) return;
    try {
      await _api.c3MarkUnread(kind, id, true);
    } catch (_) {
      if (mounted) {
        setState(() => c['marked_unread'] = false);
        UnreadStore.instance.set(_key(c), ChatPreview.unreadOf(c));
        _toast(_t.grpActionFailed);
      }
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _organiseSheet(Map<String, dynamic> c) async {
    final t = _t;
    final muted = c['muted'] == true;
    final pinned = _isPinned(c);
    final archived = _isArchived(c);
    final unread = ChatPreview.unreadOf(c);
    final group = _isGroup(c);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!archived && !group)
              ListTile(
                leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(pinned ? t.msgrChatUnpin : t.msgrChatPin),
                onTap: () {
                  Navigator.pop(ctx);
                  _togglePin(c);
                },
              ),
            if (!archived && !group)
              ListTile(
                leading: Icon(muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined),
                title: Text(muted ? t.msgrChatUnmute : t.msgrChatMute),
                onTap: () {
                  Navigator.pop(ctx);
                  muted ? _unmuteChat(c) : _muteChat(c);
                },
              ),
            if (unread > 0)
              ListTile(
                key: const Key('c3-mark-read'),
                leading: const Icon(Icons.mark_chat_read_outlined),
                title: Text(t.msgrChatMarkRead),
                onTap: () {
                  Navigator.pop(ctx);
                  _markRead(c);
                },
              )
            else
              ListTile(
                key: const Key('c3-mark-unread'),
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: Text(t.c3MarkUnread),
                onTap: () {
                  Navigator.pop(ctx);
                  _markUnread(c);
                },
              ),
            if (!group)
            ListTile(
              leading: Icon(
                  archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(archived ? t.msgrChatUnarchive : t.msgrChatArchive),
              onTap: () {
                Navigator.pop(ctx);
                _toggleArchive(c);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadFailed && _chats.isEmpty) {
      return Column(children: [
        if (widget.header != null) widget.header!,
        Expanded(
          child: LoadErrorRetry(
            body: _t.msgLoadFailed,
            onRetry: () {
              setState(() => _loading = true);
              _load();
            },
          ),
        ),
      ]);
    }
    final visible = _visible;
    return Column(children: [
      if (widget.header != null) widget.header!,
      _searchBar(),
      if (!_showArchived) _chipsRow(),
      if (_showArchived) _archivedHeader(),
      if (!_showArchived && _foldedQuery().isEmpty && _archivedCount > 0)
        _archivedBanner(),
      Expanded(
        child: visible.isEmpty
            ? (_isNoResults ? _noResults() : _empty())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 76, endIndent: Gap.md),
                  itemBuilder: (_, i) => _row(visible[i]),
                ),
              ),
      ),
    ]);
  }

  /// The archived-view header: a back affordance + title (the user is inside
  /// the archived list, not the main one).
  Widget _archivedHeader() {
    final t = _t;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: ListTile(
        dense: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => setState(() => _showArchived = false),
        ),
        title: Text(t.msgrChatArchivedTitle,
            style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }

  /// The "Archived (n)" banner on the main list that opens the archived view.
  Widget _archivedBanner() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => setState(() => _showArchived = true),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 12),
        child: Row(children: [
          Icon(Icons.archive_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(_t.msgrChatArchived,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          _CountPill(count: _archivedCount),
        ]),
      ),
    );
  }

  Widget _noResults() {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    return ListView(children: [
      const SizedBox(height: 72),
      Icon(Icons.search_off_outlined,
          size: 56, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(height: Gap.md),
      Center(
        child: Text(t.msgrChatSearchNoResultsTitle,
            style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, 0),
        child: Text(t.msgrChatSearchNoResultsBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
    ]);
  }

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: _t.msgrHubSearchHint,
          ),
        ),
      );

  Widget _chipsRow() {
    final t = _t;
    final chips = <({String id, String label})>[
      (id: 'all', label: t.msgrChipAll),
      (id: 'unread', label: t.msgrChipUnread),
      (id: 'favourites', label: t.msgrChipFavourites),
      (id: 'groups', label: t.msgrChipGroups),
      for (final l in _lists)
        (id: 'list:${l['id']}', label: '${l['name'] ?? ''}'),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: Gap.sm),
        itemBuilder: (_, i) {
          final c = chips[i];
          return ChoiceChip(
            label: Text(c.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: _filter == c.id,
            onSelected: (_) => setState(() => _filter = c.id),
          );
        },
      ),
    );
  }

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    final archived = _showArchived;
    return ListView(children: [
      const SizedBox(height: 72),
      Icon(archived ? Icons.archive_outlined : Icons.forum_outlined,
          size: 56, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(height: Gap.md),
      Center(
        child: Text(
            archived ? t.msgrChatArchivedEmptyTitle : t.msgrChatsEmptyTitle,
            style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, 0),
        child: Text(
            archived ? t.msgrChatArchivedEmptyBody : t.msgrChatsEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ),
      if (!archived && widget.onAdd != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.lg, Gap.xl, 0),
          child: Center(
            child: FilledButton.icon(
              key: const Key('m3-empty-add'),
              onPressed: widget.onAdd,
              icon: const Icon(Icons.person_add_alt_1),
              label: Text(t.m3AddToCircle),
            ),
          ),
        ),
    ]);
  }

  Widget _row(Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    final m = _memberOf(c);
    final group = _isGroup(c);
    final name = _nameOf(c);
    final unread = ChatPreview.unreadOf(c);
    final pv = _preview(c);
    final pinned = _isPinned(c);
    final muted = c['muted'] == true;
    final lang = Localizations.localeOf(context).languageCode;
    final rt = _rt.states.value[_key(c)] ?? const RtChatState();
    final activity = activityLabel(t, rt, isGroup: group);

    // tl1: one shared identifier (Android resource-id) on every chat row, so a
    // Test Lab Robo script can pick a row by resource-id + its name text.
    return RoboId(id: 'tl_chat_row',
      child: InkWell(
      key: ValueKey('c3-row-${_key(c)}'),
      onTap: () => _openChat(c),
      onLongPress: () => _organiseSheet(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 10),
        child: Row(children: [
          group
              ? CircleAvatar(
                  radius: 24,
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(Icons.groups_2_outlined,
                      color: scheme.onSecondaryContainer))
              : MsgrAvatar(
                  name: name,
                  photoUrl: '${m['photo_link'] ?? m['photo'] ?? ''}',
                  photoV: '${m['photo_v'] ?? ''}'), // x2-ticks: cached
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(name.isEmpty ? '?' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight:
                                unread > 0 ? FontWeight.w800 : FontWeight.w700,
                            fontSize: 15)),
                  ),
                  if (pv.at != null)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: Text(chatListTime(t, pv.at!, lang),
                          key: const Key('c3-row-time'),
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: unread > 0
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: unread > 0
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant)),
                    ),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  Expanded(
                    child: activity != null
                        ? Text(activity,
                            key: const Key('c3-row-activity'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: typingGreen(context)))
                        : _previewLine(pv, scheme, t),
                  ),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: Icon(Icons.notifications_off,
                          size: 16, color: scheme.onSurfaceVariant),
                    ),
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xs),
                      child:
                          Icon(Icons.push_pin, size: 16, color: scheme.primary),
                    ),
                  if (unread > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: c['marked_unread'] == true &&
                              ((c['unread'] as int?) ?? 0) == 0
                          ? Container(
                              key: const Key('c3-unread-dot'),
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                  color: scheme.primary,
                                  shape: BoxShape.circle))
                          : _UnreadBadge(count: unread),
                    ),
                ]),
              ],
            ),
          ),
        ]),
      ),
      ),
    );
  }

  /// "✓✓ You: hi" / "Rahim: hello" / "🔒 Encrypted message" / media label —
  /// "No messages yet" ONLY when the chat really has no messages.
  Widget _previewLine(ChatPreview pv, ColorScheme scheme, AppLocalizations t) {
    final muted = scheme.onSurfaceVariant;
    String body;
    IconData? lead;
    var italic = false;
    switch (pv.kind) {
      case PreviewKind.empty:
        body = t.msgrNoMessagesYet;
        italic = true;
      case PreviewKind.deleted:
        body = t.circleDeletedPlaceholder;
        lead = Icons.block;
        italic = true;
      case PreviewKind.encrypted:
        body = t.c3PreviewEncrypted;
        lead = Icons.lock_outline;
        italic = true;
      case PreviewKind.media:
        // md2: a photo caption / the document name when decrypted here
        body = pv.text.isNotEmpty ? pv.text : mediaPreviewLabel(t, pv.contentType);
        lead = mediaPreviewIcon(pv.contentType);
      case PreviewKind.text:
        body = pv.text;
    }
    final prefix = pv.kind == PreviewKind.empty
        ? ''
        : (pv.mine
            ? (pv.isGroup ? '${t.c3You}: ' : '')
            : (pv.isGroup && pv.senderName.isNotEmpty
                ? '${pv.senderName}: '
                : ''));
    return Row(children: [
      if (pv.mine && pv.tick != null) ...[
        TickIcon(tick: pv.tick!, baseColor: muted, size: 16),
        const SizedBox(width: 3),
      ],
      if (lead != null) ...[
        Icon(lead, size: 14, color: muted),
        const SizedBox(width: 3),
      ],
      Expanded(
        child: Text('$prefix$body',
            key: const Key('c3-row-preview'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13,
                color: muted,
                fontStyle: italic ? FontStyle.italic : FontStyle.normal)),
      ),
    ]);
  }
}

/// WhatsApp-style chat-list time: today → 10:14, yesterday → "Yesterday",
/// this week → weekday, else a short date.
String chatListTime(AppLocalizations t, DateTime at, String lang,
    {DateTime? now}) {
  final n = now ?? DateTime.now();
  final loc = lang == 'bn' ? 'bn' : 'en';
  final d0 = DateTime(n.year, n.month, n.day);
  final d1 = DateTime(at.year, at.month, at.day);
  final diff = d0.difference(d1).inDays;
  if (diff <= 0) return DateFormat.Hm(loc).format(at);
  if (diff == 1) return t.c3Yesterday;
  if (diff < 7) return DateFormat.E(loc).format(at);
  return DateFormat.yMd(loc).format(at);
}

/// The live "typing…" green (readable in light + dark).
Color typingGreen(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF4ADE80)
        : const Color(0xFF15803D);

String mediaPreviewLabel(AppLocalizations t, String ct) {
  switch (ct) {
    case 'photo':
    case 'image':
      return t.circlePhoto;
    case 'video':
      return t.circleVideo;
    case 'voice':
    case 'audio':
      return t.msgrVoiceMessage; // md2: "Voice message"
    case 'document':
      return t.circleAttachDocument;
    case 'contact':
      return t.circleAttachContact;
    case 'location':
      return t.circleAttachLocation;
    default:
      return t.circleAttach;
  }
}

IconData mediaPreviewIcon(String ct) => const {
      'photo': Icons.photo_outlined,
      'image': Icons.photo_outlined,
      'video': Icons.videocam_outlined,
      'voice': Icons.mic_none_outlined,
      'audio': Icons.mic_none_outlined,
      'document': Icons.insert_drive_file_outlined,
      'contact': Icons.contact_page_outlined,
      'location': Icons.location_on_outlined,
    }[ct] ??
    Icons.attachment_outlined;

/// A neutral count pill (archived count) — brand-neutral surface, our own glyph.
class _CountPill extends StatelessWidget {
  final int count;
  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final label = _bn(count > 99 ? '99+' : '$count', bn);
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.pill)),
      alignment: Alignment.center,
      child: Text(label,
          style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w700)),
    );
  }

  String _bn(String ascii, bool bn) {
    if (!bn) return ascii;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final cu in ascii.codeUnits) {
      b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? bnZero + (cu - 0x30) : cu);
    }
    return b.toString();
  }
}

/// Unread count badge — our own glyph, brand primary (never a copied style).
class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final label = _bn(count > 99 ? '99+' : '$count', bn);
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(Radii.pill)),
      alignment: Alignment.center,
      child: Text(label,
          style: TextStyle(
              color: scheme.onPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700)),
    );
  }

  String _bn(String ascii, bool bn) {
    if (!bn) return ascii;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final cu in ascii.codeUnits) {
      b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? bnZero + (cu - 0x30) : cu);
    }
    return b.toString();
  }
}
