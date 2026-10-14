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
  bool _loading = true;
  String _query = '';

  /// Active filter: a built-in id ('all'|'unread'|'favourites'|'groups') or a
  /// custom list id prefixed 'list:'.
  String _filter = 'all';

  List<Map<String, dynamic>> _chats = [];
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
    } catch (_) {
      // Offline / not wired: synthesise a row per accepted member so the list
      // still works (empty previews) rather than a blank screen.
      _chats = widget.members
          .map((m) => <String, dynamic>{
                'id': '${m['id']}',
                'member': m,
                'last_text': '',
                'unread': 0,
                'at': null,
              })
          .toList();
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

  List<Map<String, dynamic>> get _visible {
    var q = _query.trim().toLowerCase();
    // "Ask Assisto" prefix → strip it; the remaining text filters the list
    // (the agent handoff lands later — we never dead-end the tap).
    if (q.startsWith('ask assisto')) q = q.substring('ask assisto'.length).trim();

    var list = _chats.where(_matchesFilter).toList();
    if (q.isNotEmpty) {
      list = list.where((c) {
        final name = '${_memberOf(c)['name'] ?? ''}'.toLowerCase();
        final last = '${c['last_text'] ?? ''}'.toLowerCase();
        return name.contains(q) || last.contains(q);
      }).toList();
    }
    list.sort((a, b) {
      final ta = DateTime.tryParse('${a['at'] ?? ''}');
      final tb = DateTime.tryParse('${b['at'] ?? ''}');
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    return list;
  }

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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final visible = _visible;
    return Column(children: [
      _searchBar(),
      _chipsRow(),
      Expanded(
        child: visible.isEmpty
            ? _empty()
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
    return ListView(children: [
      const SizedBox(height: 72),
      Icon(Icons.forum_outlined,
          size: 56, color: scheme.primary.withValues(alpha: 0.7)),
      const SizedBox(height: Gap.md),
      Center(
        child: Text(t.msgrChatsEmptyTitle,
            style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.xl, Gap.sm, Gap.xl, 0),
        child: Text(t.msgrChatsEmptyBody,
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

    return InkWell(
      onTap: () => _openChat(c),
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
