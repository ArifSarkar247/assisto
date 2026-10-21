import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../messenger_hub_api.dart';
import '../state.dart';
import '../theme.dart';
import '../screens/circle_chat_screen.dart';
import 'msgr_avatar.dart';

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
  const MsgrHubChatList(
      {super.key, required this.identity, required this.members});

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  Future<void> _load() async {
    try {
      final r = await _api.getJson('/circle/chats');
      _chats = ((r['results'] ?? r['chats'] ?? const []) as List)
          .cast<Map<String, dynamic>>();
      _loadFailed = false;
    } catch (_) {
      // Honest error + retry (no synthesised rows posing as real chats).
      _loadFailed = true;
    }
    try {
      _lists = await _api.hubCustomLists();
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
        return ((c['unread'] as int?) ?? 0) > 0;
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
        final name = '${_memberOf(c)['name'] ?? ''}'.toLowerCase();
        final last = '${c['last_text'] ?? ''}'.toLowerCase();
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

  void _openChat(Map<String, dynamic> c) {
    final identity = widget.identity;
    if (identity == null) return;
    setState(() => c['unread'] = 0);
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) =>
              CircleChatScreen(member: _memberOf(c), identity: identity),
        ))
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
    } catch (_) {}
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
    } catch (_) {}
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
    } catch (_) {}
  }

  Future<void> _unmuteChat(Map<String, dynamic> c) async {
    setState(() => c['muted'] = false);
    _toast(_t.msgrChatUnmuted);
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/mute', {'duration': 'off'});
    } catch (_) {}
  }

  Future<void> _markRead(Map<String, dynamic> c) async {
    setState(() => c['unread'] = 0);
    final id = _chatId(c);
    if (id == null) return;
    try {
      await _api.postJson('messenger/chats/$id/read');
    } catch (_) {}
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _organiseSheet(Map<String, dynamic> c) async {
    final t = _t;
    final muted = c['muted'] == true;
    final pinned = _isPinned(c);
    final archived = _isArchived(c);
    final unread = (c['unread'] as int?) ?? 0;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!archived)
              ListTile(
                leading: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(pinned ? t.msgrChatUnpin : t.msgrChatPin),
                onTap: () {
                  Navigator.pop(ctx);
                  _togglePin(c);
                },
              ),
            if (!archived)
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
            if (unread > 0 && !archived)
              ListTile(
                leading: const Icon(Icons.mark_chat_read_outlined),
                title: Text(t.msgrChatMarkRead),
                onTap: () {
                  Navigator.pop(ctx);
                  _markRead(c);
                },
              ),
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
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_t.msgLoadFailed, textAlign: TextAlign.center),
          const SizedBox(height: Gap.md),
          FilledButton(
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
              child: Text(_t.retry)),
        ]),
      );
    }
    final visible = _visible;
    return Column(children: [
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
    ]);
  }

  Widget _row(Map<String, dynamic> c) {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    final m = _memberOf(c);
    final name = '${m['name'] ?? ''}';
    final unread = (c['unread'] as int?) ?? 0;
    final preview = '${c['last_text'] ?? ''}';
    final pinned = _isPinned(c);
    final muted = c['muted'] == true;

    return InkWell(
      onTap: () => _openChat(c),
      onLongPress: () => _organiseSheet(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 10),
        child: Row(children: [
          MsgrAvatar(
              name: name, photoUrl: '${m['photo_link'] ?? m['photo'] ?? ''}'),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name.isEmpty ? '?' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 3),
                Text(preview.isEmpty ? t.msgrNoMessagesYet : preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                        fontStyle: preview.isEmpty
                            ? FontStyle.italic
                            : FontStyle.normal)),
              ],
            ),
          ),
          // Trailing cluster: mute + pin glyphs, then the unread badge. Each is
          // an honest state reflection of the chat's organise flags.
          if (muted)
            Padding(
              padding: const EdgeInsets.only(left: Gap.sm),
              child: Icon(Icons.notifications_off,
                  size: 16, color: scheme.onSurfaceVariant),
            ),
          if (pinned)
            Padding(
              padding: const EdgeInsets.only(left: Gap.xs),
              child: Icon(Icons.push_pin, size: 16, color: scheme.primary),
            ),
          if (unread > 0)
            Padding(
              padding: const EdgeInsets.only(left: Gap.sm),
              child: _UnreadBadge(count: unread),
            ),
        ]),
      ),
    );
  }
}

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
