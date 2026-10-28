import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import 'dart:convert';
import 'dart:typed_data';

import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../crypto/key_service.dart' show PeerKeyBook;
import '../messaging/chat_list_dedupe.dart';
import '../messaging/preview_cache.dart';
import 'm3_circle_widgets.dart' show m3Invite, M3InviteVia;
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
import '../messaging/chat_decor/decor_store.dart'; // cde-chat
import '../messaging/chat_lock.dart'; // e-gaps
import '../messenger_chat_api.dart'; // e-gaps: clear (forgot lock code)
import '../messenger_group_api.dart';
import '../screens/circle_search_screen.dart'; // e-gaps: message search
import '../messaging/chat_decor/system_line.dart';
import '../messaging/chat_actions.dart'; // chat-actions
import '../screens/circle_group_info_screen.dart';
import '../screens/messenger/contact_info_screen.dart';
import 'chat_menu_pickers.dart' show showChatReportPicker;
import 'package:assisto/widgets/app_sheet.dart';

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
/// e-gaps: "Forgot the lock code" clears this person's view of a locked chat.
Future<void> clearChatForLock(ApiClient api, String chatKey) async {
  final i = chatKey.indexOf(':');
  final id = chatKey.substring(i + 1);
  if (chatKey.startsWith('group:')) {
    await api.groupClear(id);
  } else {
    await api.clearChat(int.parse(id));
  }
}

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

  /// e-gaps: the "Locked chats" folder (opened after biometric / code).
  bool _showLocked = false;

  /// chat-actions: multi-select mode (long-press ▸ Select chats) — the keys
  /// of the selected rows ('member:12' / 'group:5').
  bool _selecting = false;
  final Set<String> _sel = {};
  AppLifecycleListener? _life;

  List<Map<String, dynamic>> _chats = [];
  bool _loadFailed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)
  List<Map<String, dynamic>> _lists = [];

  /// c3-msg: decrypted previews, cached per (row id, last message id) so a
  /// reload never re-runs X25519 for an unchanged row.
  final Map<String, ChatPreview> _previews = {};

  /// a1-circle: every EARLIER key this phone saw for each 1:1 peer
  /// (PeerKeyBook), so a last message sent before the peer's key change
  /// still decrypts here.
  final Map<String, List<Uint8List>> _peerHist = {};
  final _e2e = SoftwareE2E();
  final _rt = RealtimeChannel.instance;

  @override
  void initState() {
    super.initState();
    _rt.acquire();
    _rt.states.addListener(_onRt);
    // cde-chat: nicknames from this phone's store (and the server rows)
    DecorStore.instance.revision.addListener(_onRt);
    unawaited(DecorStore.instance.loadAll());
    // e-gaps: locked chats leave this list (folder at the top)
    ChatLockStore.instance.revision.addListener(_onRt);
    unawaited(ChatLockStore.instance.warm().then((_) => _onRt()));
    final api = _api;
    ChatLockAuth.clearChat = (k) => clearChatForLock(api, k);
    _life = AppLifecycleListener(onPause: () {
      ChatLockSession.end(); // the locked folder closes when the app leaves
      if (mounted && _showLocked) setState(() => _showLocked = false);
    });
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
    DecorStore.instance.revision.removeListener(_onRt); // cde-chat
    ChatLockStore.instance.revision.removeListener(_onRt); // e-gaps
    _life?.dispose();
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
        ck,
        () => ChatPreview.fromRow(c,
            identity: widget.identity,
            e2e: _e2e,
            extraPeerKeys: _peerHist[_key(c)] ?? const [],
            cachedText: last == null
                ? null
                : PreviewCache.instance.peek(_key(c), '${last['id']}')));
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
      // a1-circle: one row per person, always.
      _chats = dedupeChatRows(((r['results'] ?? r['chats'] ?? const []) as List)
          .cast<Map<String, dynamic>>());
      _loadFailed = false;
      // cde-chat: the server's nickname for every 1:1 row (reinstall-safe)
      for (final c in _chats) {
        if (!_isGroup(c)) {
          unawaited(DecorStore.instance.adoptMemberPayload(_key(c), _memberOf(c)));
        }
      }
      await _loadPeerKeys(_chats);
      _previews.clear();
      _publishUnread();
    } catch (e) {
      // Honest error + retry (no synthesised rows posing as real chats).
      _loadFailed = true;
      _failCause = e;
    }
    try {
      _lists = await loadGuard(_api.hubCustomLists());
    } catch (_) {
      _lists = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  /// a1-circle: record each peer's CURRENT key (so a later change keeps the
  /// old one in the history) and load the earlier ones + cached previews.
  Future<void> _loadPeerKeys(List<Map<String, dynamic>> rows) async {
    try {
      await PreviewCache.instance.warm();
      for (final c in rows) {
        if (_isGroup(c)) continue;
        final k = _key(c);
        final cur = '${_memberOf(c)['public_key'] ?? ''}';
        if (cur.isNotEmpty) await PeerKeyBook.instance.observe(k, cur);
        final hist = await PeerKeyBook.instance.history(k);
        _peerHist[k] = [
          for (final h in hist.reversed) // newest first
            if (h != cur) ...[
              () {
                try {
                  return Uint8List.fromList(base64Decode(h));
                } catch (_) {
                  return Uint8List(0);
                }
              }()
            ]
        ].where((x) => x.isNotEmpty).toList();
      }
    } catch (_) {
      // never blocks the list: the current key still decrypts
    }
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
  bool _isLocked(Map<String, dynamic> c) =>
      ChatLockStore.instance.isLockedSync(_key(c));
  int get _lockedCount => _chats.where(_isLocked).length;
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
    var list = _showLocked
        ? _chats.where(_isLocked).toList()
        : _chats
            .where((c) => !_isLocked(c)) // e-gaps: only in the locked folder
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

  int get _archivedCount =>
      _chats.where((c) => _isArchived(c) && !_isLocked(c)).length;

  /// True when the user is actively searching but nothing matched — drives a
  /// no-results state distinct from an empty list (mirrors the server
  /// msg_organise.search_chats 'no_results' state).
  bool get _isNoResults => _foldedQuery().isNotEmpty && _visible.isEmpty;

  String _nameOf(Map<String, dynamic> c) => _isGroup(c)
      ? '${(c['group'] as Map?)?['name'] ?? _memberOf(c)['name'] ?? ''}'
      // cde-chat: the nickname first (the real name stays in contact info)
      : DecorStore.instance.peerName(_key(c), '${_memberOf(c)['name'] ?? ''}');

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
    if (id == null && !_isGroup(c)) return;
    try {
      if (_isGroup(c)) {
        await _api.postJson('/circle/groups/${_groupId(c)}/organise', {'pinned': pinning});
      } else {
        await _api.postJson('messenger/chats/$id/pin', {'pinned': pinning});
      }
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
    if (id == null && !_isGroup(c)) return;
    try {
      if (_isGroup(c)) {
        await _api.postJson(
            '/circle/groups/${_groupId(c)}/organise', {'archived': archiving});
      } else {
        await _api.postJson('messenger/chats/$id/archive', {'archived': archiving});
      }
    } catch (_) {
      if (mounted) {
        setState(() => c['archived'] = !archiving);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _muteChat(Map<String, dynamic> c) async {
    final choice = await _pickMute();
    if (choice == null || !mounted) return;
    await _applyMute(c, choice);
    if (mounted) _toast(_t.msgrChatMuted);
  }

  Future<String?> _pickMute() => showAppSheet<String>(
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

  Future<void> _applyMute(Map<String, dynamic> c, String choice) async {
    setState(() => c['muted'] = true);
    try {
      if (_isGroup(c)) {
        await _api.postJson('/circle/groups/${_groupId(c)}/mute', {'duration': choice});
        return;
      }
      final id = _chatId(c);
      if (id == null) return;
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
    if (id == null && !_isGroup(c)) return;
    try {
      if (_isGroup(c)) {
        await _api.postJson('/circle/groups/${_groupId(c)}/mute', {'duration': 'off'});
        return;
      }
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

  bool _isFavourite(Map<String, dynamic> c) =>
      c['favourite'] == true || c['is_favourite'] == true;

  Future<void> _organiseSheet(Map<String, dynamic> c) async {
    final t = _t;
    final muted = c['muted'] == true;
    final pinned = _isPinned(c);
    final archived = _isArchived(c);
    final unread = ChatPreview.unreadOf(c);
    final group = _isGroup(c);
    final fav = _isFavourite(c);
    final blocked = _memberOf(c)['blocked'] == true;
    final danger = Theme.of(context).colorScheme.error;
    void go(BuildContext ctx, void Function() f) {
      Navigator.pop(ctx);
      f();
    }

    await showAppSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: ListView(
            shrinkWrap: true,
            children: [
              // chat-actions: View contact / Group info first (WhatsApp)
              ListTile(
                key: const Key('ca-view-contact'),
                leading: Icon(group ? Icons.info_outline_rounded : Icons.person_outline_rounded),
                title: Text(group ? t.caGroupInfo : t.caViewContact),
                onTap: () => go(ctx, () => _viewContact(c)),
              ),
              if (!archived)
                ListTile(
                  key: const Key('e-org-pin'),
                  leading: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
                  title: Text(pinned ? t.msgrChatUnpin : t.msgrChatPin),
                  onTap: () => go(ctx, () => _togglePin(c)),
                ),
              if (!archived)
                ListTile(
                  key: const Key('ca-mute'),
                  leading: Icon(muted
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded),
                  title: Text(muted ? t.msgrChatUnmute : t.msgrChatMute),
                  onTap: () => go(ctx, () => muted ? _unmuteChat(c) : _muteChat(c)),
                ),
              if (unread > 0)
                ListTile(
                  key: const Key('c3-mark-read'),
                  leading: const Icon(Icons.mark_chat_read_rounded),
                  title: Text(t.msgrChatMarkRead),
                  onTap: () => go(ctx, () => _markRead(c)),
                )
              else
                ListTile(
                  key: const Key('c3-mark-unread'),
                  leading: const Icon(Icons.mark_chat_unread_rounded),
                  title: Text(t.c3MarkUnread),
                  onTap: () => go(ctx, () => _markUnread(c)),
                ),
              ListTile(
                key: const Key('ca-favourite'),
                leading: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                title: Text(fav ? t.msgrChatRemoveFavourite : t.msgrChatAddFavourite),
                onTap: () => go(ctx, () => _toggleFavourite(c)),
              ),
              ListTile(
                key: const Key('e-org-archive'),
                leading: Icon(
                    archived ? Icons.unarchive_rounded : Icons.archive_rounded),
                title: Text(archived ? t.msgrChatUnarchive : t.msgrChatArchive),
                onTap: () => go(ctx, () => _toggleArchive(c)),
              ),
              // e-gaps: chat lock (fingerprint / face or this phone's code)
              ListTile(
                key: const Key('e-org-lock'),
                leading: Icon(_isLocked(c) ? Icons.lock_open_rounded : Icons.lock_outline_rounded),
                title: Text(_isLocked(c) ? t.eLockUnlockChat : t.eLockLockChat),
                onTap: () => go(ctx, () => unawaited(toggleChatLock(context, _key(c)))),
              ),
              ListTile(
                key: const Key('ca-select'),
                leading: const Icon(Icons.checklist_rounded),
                title: Text(t.caSelectChats),
                onTap: () => go(ctx, () => setState(() {
                      _selecting = true;
                      _sel
                        ..clear()
                        ..add(_key(c));
                    })),
              ),
              const Divider(height: Gap.sm),
              ListTile(
                key: const Key('ca-clear'),
                leading: const Icon(Icons.cleaning_services_rounded),
                title: Text(t.caClearChat),
                onTap: () => go(ctx, () => _clearChat(c)),
              ),
              ListTile(
                key: const Key('ca-delete'),
                leading: Icon(Icons.delete_outline_rounded, color: danger),
                title: Text(t.caDeleteChat, style: TextStyle(color: danger)),
                onTap: () => go(ctx, () => _deleteChats([c])),
              ),
              if (!group && !blocked)
                ListTile(
                  key: const Key('ca-block'),
                  leading: Icon(Icons.block_rounded, color: danger),
                  title: Text(t.circleBlock, style: TextStyle(color: danger)),
                  onTap: () => go(ctx, () => _block(c)),
                ),
              ListTile(
                key: const Key('ca-report'),
                leading: Icon(Icons.flag_outlined, color: danger),
                title: Text(t.circleReport, style: TextStyle(color: danger)),
                onTap: () => go(ctx, () => _report(c)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- chat-actions --------------------------------------------------------

  Future<void> _viewContact(Map<String, dynamic> c) async {
    final Widget screen;
    if (_isGroup(c)) {
      final identity = widget.identity ?? await IdentityVault.instance.get();
      if (!mounted) return;
      final g = Map<String, dynamic>.from((c['group'] as Map?) ?? const {});
      g['id'] ??= _groupId(c);
      screen = CircleGroupInfoScreen(
          group: g, identity: identity, circleMembers: widget.members);
    } else {
      screen = ContactInfoScreen(member: _memberOf(c));
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) unawaited(_load());
  }

  Future<void> _toggleFavourite(Map<String, dynamic> c) async {
    final on = !_isFavourite(c);
    setState(() => c['favourite'] = on);
    try {
      if (_isGroup(c)) {
        await _api.groupSetFavourite('${_groupId(c)}', on);
      } else {
        final id = _chatId(c);
        if (id == null) return;
        await _api.setFavourite(id, on);
      }
    } catch (_) {
      if (mounted) {
        setState(() => c['favourite'] = !on);
        _toast(_t.grpActionFailed);
      }
    }
  }

  Future<void> _clearChat(Map<String, dynamic> c) async {
    final keep = await showClearChatDialog(context);
    if (keep == null || !mounted) return;
    try {
      await _api.clearChatFor(_key(c), keepStarred: keep);
      await wipeChatLocally(_key(c));
      if (!mounted) return;
      _toast(_t.caChatCleared);
      unawaited(_load());
    } catch (_) {
      if (mounted) _toast(_t.grpActionFailed);
    }
  }

  /// Delete one or many chats (per-user hide; nobody leaves My Circle or a
  /// group). The rows go at once; a failure puts them back honestly.
  Future<void> _deleteChats(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final media = await showDeleteChatDialog(context,
        name: _nameOf(rows.first), group: _isGroup(rows.first), count: rows.length);
    if (media == null || !mounted) return;
    final keys = rows.map(_key).toSet();
    setState(() {
      _chats.removeWhere((c) => keys.contains(_key(c)));
      _selecting = false;
      _sel.clear();
    });
    var failed = false;
    for (final c in rows) {
      try {
        final r = await _api.deleteChatFor(_key(c), deleteMedia: media);
        await wipeChatLocally(_key(c),
            mediaRefs: mediaRefsOf(r), deleteMedia: media);
      } catch (_) {
        failed = true;
      }
    }
    if (!mounted) return;
    _publishUnread();
    _toast(failed ? _t.grpActionFailed : _t.caChatDeleted);
    if (failed) unawaited(_load());
  }

  Future<void> _block(Map<String, dynamic> c) async {
    final id = _chatId(c);
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ca-block-dialog'),
        title: Text(_t.caBlockTitle(_nameOf(c))),
        content: Text(_t.msgrChatBlockConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(_t.cancel)),
          FilledButton(
              key: const Key('ca-block-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_t.circleBlock)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.blockContact(id, on: true);
      if (mounted) _toast(_t.msgrChatBlocked);
      unawaited(_load());
    } catch (_) {
      if (mounted) _toast(_t.grpActionFailed);
    }
  }

  Future<void> _report(Map<String, dynamic> c) async {
    final res = await showChatReportPicker(context);
    if (res == null || !mounted) return;
    try {
      if (_isGroup(c)) {
        await _api.postJson(
            '/circle/groups/${_groupId(c)}/report', {'reason': res.reason});
      } else {
        final id = _chatId(c);
        if (id == null) return;
        // From the list we only hold what this phone already decrypted for
        // the preview — nothing else leaves the device.
        final pv = _preview(c);
        await _api.reportLast5(
          peerId: id,
          reason: res.reason,
          decryptedLastFive: [
            if (pv.kind == PreviewKind.text && pv.text.isNotEmpty)
              {'text': pv.text, 'from_me': pv.mine,
               'at': pv.at?.toUtc().toIso8601String()},
          ],
        );
        if (res.alsoBlock) await _api.blockContact(id, on: true);
      }
      if (mounted) _toast(_t.msgrChatReportSent);
    } catch (_) {
      if (mounted) _toast(_t.grpActionFailed);
    }
  }

  // ---- multi-select ---------------------------------------------------------

  List<Map<String, dynamic>> get _selectedRows =>
      _chats.where((c) => _sel.contains(_key(c))).toList();

  void _toggleSel(Map<String, dynamic> c) {
    setState(() {
      final k = _key(c);
      if (!_sel.remove(k)) _sel.add(k);
      if (_sel.isEmpty) _selecting = false;
    });
  }

  void _endSelect() => setState(() {
        _selecting = false;
        _sel.clear();
      });

  Future<void> _bulkPin() async {
    final rows = _selectedRows;
    final pinAll = rows.any((c) => !_isPinned(c));
    _endSelect();
    for (final c in rows) {
      if (_isPinned(c) == pinAll || _isArchived(c)) continue;
      if (pinAll && _pinnedCount() >= _pinCap) {
        _toast(_t.msgrChatPinLimit);
        break;
      }
      await _togglePin(c);
    }
  }

  Future<void> _bulkMute() async {
    final rows = _selectedRows;
    final choice = await _pickMute();
    if (choice == null || !mounted) return;
    _endSelect();
    for (final c in rows) {
      await _applyMute(c, choice);
    }
    if (mounted) _toast(_t.msgrChatMuted);
  }

  Future<void> _bulkArchive() async {
    final rows = _selectedRows;
    final archive = !_showArchived;
    _endSelect();
    for (final c in rows) {
      if (_isArchived(c) != archive) await _toggleArchive(c);
    }
  }

  Future<void> _bulkMarkRead() async {
    final rows = _selectedRows;
    _endSelect();
    for (final c in rows) {
      if (ChatPreview.unreadOf(c) > 0) await _markRead(c);
    }
  }

  Widget _selectionBar() {
    final t = _t;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final scheme = Theme.of(context).colorScheme;
    Widget act(Key k, IconData i, String tip, VoidCallback f, {Color? color}) =>
        IconButton(key: k, tooltip: tip, icon: Icon(i, color: color), onPressed: f);
    return Material(
      key: const Key('ca-selection-bar'),
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            act(const Key('ca-sel-close'), Icons.close_rounded, t.caExitSelection, _endSelect),
            Expanded(
              child: Text(t.caSelectedCount(_bnIf('${_sel.length}', bn)),
                  key: const Key('ca-sel-count'),
                  maxLines: 2,
                  style: AType.titleMedium.copyWith(color: scheme.onSecondaryContainer)),
            ),
          ]),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          if (!_showArchived)
            act(const Key('ca-bulk-pin'), Icons.push_pin_outlined, t.msgrChatPin, _bulkPin),
          act(const Key('ca-bulk-mute'), Icons.notifications_off_outlined, t.msgrChatMute, _bulkMute),
          act(const Key('ca-bulk-archive'),
              _showArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
              _showArchived ? t.msgrChatUnarchive : t.msgrChatArchive, _bulkArchive),
          act(const Key('ca-bulk-read'), Icons.mark_chat_read_outlined, t.msgrChatMarkRead,
              _bulkMarkRead),
          act(const Key('ca-bulk-delete'), Icons.delete_outline_rounded, t.caDeleteChat,
              () => _deleteChats(_selectedRows),
              color: scheme.error),
          ]),
        ]),
      ),
    );
  }

  static String _bnIf(String s, bool bn) => bn ? _bnDigits(s) : s;

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadFailed && _chats.isEmpty) {
      return Column(children: [
        if (widget.header != null) widget.header!,
        Expanded(
          child: LoadErrorRetry(
            error: _failCause,
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
    // chat-actions: Back first closes the selection (like WhatsApp)
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) _endSelect();
      },
      child: Column(children: [
      if (widget.header != null) widget.header!,
      if (_selecting) _selectionBar() else _searchBar(),
      if (_showLocked)
        _lockedHeader()
      else ...[
        if (!_showArchived) _chipsRow(),
        if (_showArchived) _archivedHeader(),
        // e-gaps: the locked folder, then the archive banner
        if (!_showArchived && _foldedQuery().isEmpty && _lockedCount > 0)
          _lockedBanner(),
        if (!_showArchived && _foldedQuery().isEmpty && _archivedCount > 0)
          _archivedBanner(),
      ],
      // e-gaps: search inside the messages too (decrypted on this phone)
      if (_foldedQuery().isNotEmpty && widget.identity != null) _searchMessagesRow(),
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
    ]),
    );
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
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => setState(() => _showArchived = false),
        ),
        title: Text(t.msgrChatArchivedTitle,
            style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }

  // ---- e-gaps: locked chats + message search -----------------------------

  Future<void> _openLocked() async {
    if (!ChatLockSession.isOpen && !await ChatLockAuth.authenticate(context)) return;
    if (mounted) setState(() => _showLocked = true);
  }

  Widget _lockedBanner() {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const Key('e-locked-banner'),
      onTap: _openLocked,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: 12),
        child: Row(children: [
          Icon(Icons.lock_outline_rounded, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(_t.eLockFolder, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          _CountPill(count: _lockedCount),
        ]),
      ),
    );
  }

  Widget _lockedHeader() => Material(
        color: Theme.of(context).colorScheme.surface,
        child: ListTile(
          dense: true,
          leading: IconButton(
            key: const Key('e-locked-back'),
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: () {
              ChatLockSession.end(); // leaving the folder locks it again
              setState(() => _showLocked = false);
            },
          ),
          title: Text(_t.eLockFolder, style: Theme.of(context).textTheme.titleMedium),
        ),
      );

  Widget _searchMessagesRow() {
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim();
    return ListTile(
      key: const Key('e-search-messages'),
      dense: true,
      leading: Icon(Icons.manage_search_rounded, color: scheme.primary),
      title: Text(_t.eSearchMessagesFor(q), maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () {
        final id = widget.identity;
        if (id == null) return;
        Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CircleSearchScreen(
                members: widget.members, identity: id, initialQuery: q)));
      },
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
          Icon(Icons.archive_rounded, size: 20, color: scheme.onSurfaceVariant),
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
      const SizedBox(height: Gap.xxxl + Gap.xl),
      Icon(Icons.search_off_rounded,
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
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
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
    // f3: the row takes the chips' own height (48 dp tap targets; at 200 %
    // text a fixed 44 dp row clipped the labels).
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      child: Row(children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(width: Gap.sm),
          ChoiceChip(
            label: Text(chips[i].label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            selected: _filter == chips[i].id,
            onSelected: (_) => setState(() => _filter = chips[i].id),
          ),
        ],
      ]),
    );
  }

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    final archived = _showArchived;
    return ListView(children: [
      const SizedBox(height: Gap.xxxl + Gap.xl),
      Icon(archived ? Icons.archive_rounded : Icons.forum_rounded,
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
              icon: const Icon(Icons.person_add_alt_1_rounded),
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
    final hint = sameNameHint(c, _dupNames,
        digits: lang == 'bn' ? _bnDigits : null);
    // a1-circle: a contact who never opened Assisto: honest hint + Invite
    // (instead of a bare "No messages yet").
    final notOnApp =
        !group && pv.kind == PreviewKind.empty && c['peer_has_app'] == false;

    // tl1: one shared identifier (Android resource-id) on every chat row, so a
    // Test Lab Robo script can pick a row by resource-id + its name text.
    return RoboId(id: 'tl_chat_row',
      child: InkWell(
      key: ValueKey('c3-row-${_key(c)}'),
      // chat-actions: in select mode a tap / long-press toggles the row
      onTap: () => _selecting ? _toggleSel(c) : _openChat(c),
      onLongPress: () => _selecting ? _toggleSel(c) : _organiseSheet(c),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
          group
              ? CircleAvatar(
                  radius: 24,
                  backgroundColor: scheme.secondaryContainer,
                  child: Icon(Icons.groups_2_rounded,
                      color: scheme.onSecondaryContainer))
              : MsgrAvatar(
                  name: name,
                  photoUrl: '${m['photo_link'] ?? m['photo'] ?? ''}',
                  photoV: '${m['photo_v'] ?? ''}'), // x2-ticks: cached
            if (_selecting && _sel.contains(_key(c)))
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  key: const Key('ca-row-selected'),
                  decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 2)),
                  child: Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary),
                ),
              ),
          ]),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(name.isEmpty ? '?' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AType.titleMedium.copyWith(
                            fontWeight:
                                unread > 0 ? FontWeight.w800 : FontWeight.w700)),
                  ),
                  // a1-circle: two DIFFERENT people with the same name get a
                  // subtle second identifier (label / "...888"), like WhatsApp.
                  if (hint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: Text(hint,
                          key: const Key('a1-same-name-hint'),
                          maxLines: 1,
                          style: AType.bodySmall
                              .copyWith(color: scheme.onSurfaceVariant)),
                    ),
                  const Spacer(),
                  if (pv.at != null)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: Text(chatListTime(t, pv.at!, lang),
                          key: const Key('c3-row-time'),
                          style: AType.labelMedium.copyWith(
                              fontFeatures: AFonts.tabular,
                              fontWeight: unread > 0
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: unread > 0
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant)),
                    ),
                ]),
                const SizedBox(height: Gap.xxs),
                Row(children: [
                  Expanded(
                    child: activity != null
                        ? Text(activity,
                            key: const Key('c3-row-activity'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AType.bodyMedium.copyWith(
                                fontWeight: FontWeight.w600,
                                color: typingGreen(context)))
                        : notOnApp
                            ? _notOnAppLine(scheme, t)
                            : _previewLine(pv, scheme, t),
                  ),
                  // chat-actions: disappearing messages are on
                  if (((c['disappearing_sec'] as num?)?.toInt() ?? 0) > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: ChatTimerIcon(
                          seconds: (c['disappearing_sec'] as num).toInt()),
                    ),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: Icon(Icons.notifications_off_rounded,
                          size: 16, color: scheme.onSurfaceVariant),
                    ),
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xs),
                      child:
                          Icon(Icons.push_pin_rounded, size: 16, color: scheme.primary),
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

  /// a1-circle: "Hasn't opened Assisto yet - Invite"; Invite opens the real
  /// share sheet (m3Invite), never a dead tap.
  Widget _notOnAppLine(ColorScheme scheme, AppLocalizations t) {
    return Row(children: [
      Flexible(
        child: Text(t.a1NotOnAssistoYet,
            key: const Key('a1-not-on-app'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AType.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
                fontStyle: FontStyle.italic)),
      ),
      const SizedBox(width: Gap.xs),
      InkWell(
        key: const Key('a1-invite'),
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: () => m3Invite(context, M3InviteVia.share),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Gap.xs, vertical: Gap.xxs),
          child: Text(t.a1Invite,
              style: AType.bodyMedium.copyWith(
                  fontWeight: FontWeight.w700, color: scheme.primary)),
        ),
      ),
    ]);
  }

  Set<String> get _dupNames => sameNameKeys(_chats);

  static String _bnDigits(String ascii) {
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final cu in ascii.codeUnits) {
      b.writeCharCode(cu >= 0x30 && cu <= 0x39 ? bnZero + (cu - 0x30) : cu);
    }
    return b.toString();
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
        lead = Icons.block_rounded;
        italic = true;
      case PreviewKind.encrypted:
        body = t.c3PreviewEncrypted;
        lead = Icons.lock_outline_rounded;
        italic = true;
      case PreviewKind.media:
        // md2: a photo caption / the document name when decrypted here
        body = pv.text.isNotEmpty ? pv.text : mediaPreviewLabel(t, pv.contentType);
        lead = mediaPreviewIcon(pv.contentType);
      case PreviewKind.text:
        body = pv.text;
    }
    // cde-chat: a theme / nickname change reads as a localised system line
    final cc = pv.control;
    var ctrlLine = false;
    if (cc != null && (cc.isTheme || cc.uid == null)) {
      ctrlLine = true;
      body = describeControl(t, cc,
          mine: pv.mine,
          actor: pv.senderName,
          peerName: pv.senderName);
      lead = cc.isTheme ? Icons.palette_rounded : Icons.badge_rounded;
    }
    final prefix = pv.kind == PreviewKind.empty || ctrlLine
        ? ''
        : (pv.mine
            ? (pv.isGroup ? '${t.c3You}: ' : '')
            : (pv.isGroup && pv.senderName.isNotEmpty
                ? '${pv.senderName}: '
                : ''));
    return Row(children: [
      if (pv.mine && pv.tick != null) ...[
        TickIcon(tick: pv.tick!, baseColor: muted, size: 16),
        const SizedBox(width: Gap.xs),
      ],
      if (lead != null) ...[
        Icon(lead, size: 14, color: muted),
        const SizedBox(width: Gap.xs),
      ],
      Expanded(
        child: Text('$prefix$body',
            key: const Key('c3-row-preview'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AType.bodyMedium.copyWith(
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
Color typingGreen(BuildContext context) => AssistoTokens.of(context).success;

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
      'photo': Icons.photo_rounded,
      'image': Icons.photo_rounded,
      'video': Icons.videocam_rounded,
      'voice': Icons.mic_none_rounded,
      'audio': Icons.mic_none_rounded,
      'document': Icons.insert_drive_file_rounded,
      'contact': Icons.contact_page_rounded,
      'location': Icons.location_on_rounded,
    }[ct] ??
    Icons.attachment_rounded;

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
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm - Gap.xxs),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(Radii.pill)),
      alignment: Alignment.center,
      child: Text(label,
          style: AFonts.figures(AType.labelSmall)!.copyWith(
              height: 1.2,
              color: scheme.onSurfaceVariant,
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
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm - Gap.xxs),
      decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(Radii.pill)),
      alignment: Alignment.center,
      child: Text(label,
          style: AFonts.figures(AType.labelSmall)!.copyWith(
              height: 1.2,
              color: scheme.onPrimary,
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
