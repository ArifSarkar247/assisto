import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../crypto/identity_vault.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../screens/circle_chat_screen.dart';
import 'msgr_avatar.dart';
import '../services/error_kind.dart' show honestFailText; // qa2

/// The Chats tab — a fast, familiar chat list (avatar, name, last-message
/// preview, time, unread badge, delivery ticks) with long-press actions
/// (mute / pin / mark-read / delete). Tapping a row opens the circle E2E 1:1
/// thread ([CircleChatScreen]) — we reuse the existing thread rather than
/// duplicate it. ORIGINAL visuals: Assisto tokens + our own icons/wording.
class MsgrChatList extends StatefulWidget {
  final IdentityKeyPair? identity;
  final List<Map<String, dynamic>> members;
  const MsgrChatList({super.key, required this.identity, required this.members});

  @override
  State<MsgrChatList> createState() => _MsgrChatListState();
}

class _MsgrChatListState extends State<MsgrChatList> {
  bool _loading = true;
  String _query = '';
  List<Map<String, dynamic>> _chats = [];
  bool _loadFailed = false;
  Object? _failCause; // qa2: why it failed (5xx = our server, not the internet)

  // Local UI overlays keyed by chat id (optimistic; backend persists the real
  // state). Keeps the list snappy on long-press actions.
  final Set<String> _muted = {};
  final Set<String> _pinned = {};
  final Set<String> _hidden = {};

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
      _chats = ((r['results'] ?? r['chats'] ?? []) as List)
          .cast<Map<String, dynamic>>();
      _loadFailed = false;
    } catch (e) {
      // Honest error + retry (no synthesised rows posing as real chats).
      _loadFailed = true;
      _failCause = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> get _visible {
    final q = _query.trim().toLowerCase();
    var list = _chats.where((c) => !_hidden.contains('${c['id']}')).toList();
    if (q.isNotEmpty) {
      list = list.where((c) {
        final name = '${_memberOf(c)['name'] ?? ''}'.toLowerCase();
        final last = '${c['last_text'] ?? ''}'.toLowerCase();
        return name.contains(q) || last.contains(q);
      }).toList();
    }
    // Pinned first, then by recency (newest first; undated last).
    list.sort((a, b) {
      final pa = _pinned.contains('${a['id']}') ? 0 : 1;
      final pb = _pinned.contains('${b['id']}') ? 0 : 1;
      if (pa != pb) return pa - pb;
      final ta = DateTime.tryParse('${a['at'] ?? ''}');
      final tb = DateTime.tryParse('${b['at'] ?? ''}');
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return tb.compareTo(ta);
    });
    return list;
  }

  Map<String, dynamic> _memberOf(Map<String, dynamic> c) =>
      (c['member'] as Map?)?.cast<String, dynamic>() ?? const {};

  Future<void> _openChat(Map<String, dynamic> c) async {
    final member = _memberOf(c);
    // Never a silent no-op (see IdentityVault).
    final identity = widget.identity ?? await IdentityVault.instance.get();
    if (!mounted) return;
    // Opening a chat clears its unread badge locally.
    setState(() => c['unread'] = 0);
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => CircleChatScreen(member: member, identity: identity),
        ))
        .then((_) => _load());
  }

  Future<void> _onLongPress(Map<String, dynamic> c) async {
    final id = '${c['id']}';
    final t = _t;
    final isMuted = _muted.contains(id);
    final isPinned = _pinned.contains(id);
    final hasUnread = ((c['unread'] as int?) ?? 0) > 0;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(isPinned
                ? Icons.push_pin_outlined
                : Icons.push_pin_rounded),
            title: Text(isPinned ? t.msgrActionUnpin : t.msgrActionPin),
            onTap: () => Navigator.pop(ctx, 'pin'),
          ),
          ListTile(
            leading: Icon(isMuted
                ? Icons.notifications_active_rounded
                : Icons.notifications_off_rounded),
            title: Text(isMuted ? t.msgrActionUnmute : t.msgrActionMute),
            onTap: () => Navigator.pop(ctx, 'mute'),
          ),
          ListTile(
            leading: Icon(hasUnread
                ? Icons.mark_chat_read_rounded
                : Icons.mark_chat_unread_rounded),
            title: Text(
                hasUnread ? t.msgrActionMarkRead : t.msgrActionMarkUnread),
            onTap: () => Navigator.pop(ctx, 'read'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded,
                color: Theme.of(ctx).colorScheme.error),
            title: Text(t.msgrActionDelete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        setState(() =>
            isPinned ? _pinned.remove(id) : _pinned.add(id));
        _fire('/circle/$id/pin', {'pinned': !isPinned});
        break;
      case 'mute':
        setState(() => isMuted ? _muted.remove(id) : _muted.add(id));
        _fire('/circle/$id/mute', {'muted': !isMuted});
        break;
      case 'read':
        setState(() => c['unread'] = hasUnread ? 0 : 1);
        _fire('/circle/$id/read', {'read': hasUnread});
        break;
      case 'delete':
        await _confirmDelete(c);
        break;
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> c) async {
    final t = _t;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.msgrDeleteConfirmTitle),
        content: Text(t.msgrDeleteConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.msgrCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.msgrActionDelete),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _hidden.add('${c['id']}'));
      _fire('/circle/${c['id']}/chat/delete', {});
    }
  }

  void _fire(String path, Map<String, dynamic> body) {
    _api.postJson(path, body).catchError((_) => <String, dynamic>{});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadFailed && _chats.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(honestFailText(_t, _failCause, otherwise: _t.msgLoadFailed), textAlign: TextAlign.center),
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
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            hintText: _t.msgrSearchHint,
          ),
        ),
      ),
      Expanded(
        child: visible.isEmpty
            ? _empty()
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, indent: 76, endIndent: Gap.md),
                  itemBuilder: (_, i) => _row(visible[i]),
                ),
              ),
      ),
    ]);
  }

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    final t = _t;
    return ListView(children: [
      const SizedBox(height: 80),
      Icon(Icons.forum_rounded,
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
    final id = '${c['id']}';
    final name = '${m['name'] ?? ''}';
    final unread = (c['unread'] as int?) ?? 0;
    final muted = _muted.contains(id);
    final pinned = _pinned.contains(id);
    final mine = c['last_mine'] == true;
    final preview = _preview(c);

    return InkWell(
      onTap: () => _openChat(c),
      onLongPress: () => _onLongPress(c),
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
                Row(children: [
                  Expanded(
                    child: Text(name.isEmpty ? '?' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                  const SizedBox(width: Gap.sm),
                  Text(_timeLabel(c),
                      style: TextStyle(
                          fontSize: 11,
                          color: unread > 0
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          fontWeight:
                              unread > 0 ? FontWeight.w700 : FontWeight.w400)),
                ]),
                const SizedBox(height: 3),
                Row(children: [
                  if (mine) ...[
                    _Ticks(status: '${c['status'] ?? 'sent'}', scheme: scheme),
                    const SizedBox(width: 3),
                  ],
                  Expanded(
                    child: Text(
                      preview.isEmpty ? t.msgrNoMessagesYet : preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurfaceVariant,
                          fontStyle: preview.isEmpty
                              ? FontStyle.italic
                              : FontStyle.normal),
                    ),
                  ),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xs),
                      child: Icon(Icons.notifications_off_rounded,
                          size: 15, color: scheme.onSurfaceVariant),
                    ),
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.xs),
                      child: Icon(Icons.push_pin_rounded,
                          size: 14, color: scheme.onSurfaceVariant),
                    ),
                  if (unread > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: Gap.sm),
                      child: _UnreadBadge(count: unread, muted: muted),
                    ),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  String _preview(Map<String, dynamic> c) {
    final ct = '${c['last_content_type'] ?? 'text'}';
    final t = _t;
    final body = switch (ct) {
      'image' => t.msgrPhoto,
      'voice' => t.msgrVoiceMessage,
      'file' => t.msgrDocument,
      'location' => t.msgrLocation,
      _ => '${c['last_text'] ?? ''}',
    };
    if (body.isEmpty) return '';
    return c['last_mine'] == true ? '${t.msgrYouPrefix}$body' : body;
  }

  /// Short, locale-digit time label. Bn digits are produced via codepoints (no
  /// Bangla literal lives here — only placeholder-free numerals).
  String _timeLabel(Map<String, dynamic> c) {
    final at = DateTime.tryParse('${c['at'] ?? ''}');
    if (at == null) return '';
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final now = DateTime.now();
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    final s = sameDay
        ? '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'
        : '${at.day}/${at.month}';
    return _bnDigits(s, bn);
  }

  String _bnDigits(String ascii, bool bn) {
    if (!bn) return ascii;
    const bnZero = 0x09E6;
    final b = StringBuffer();
    for (final cu in ascii.codeUnits) {
      if (cu >= 0x30 && cu <= 0x39) {
        b.writeCharCode(bnZero + (cu - 0x30));
      } else {
        b.writeCharCode(cu);
      }
    }
    return b.toString();
  }
}

/// Delivery ticks — our own glyphs (sent → delivered → read). Read is tinted
/// with the brand primary; never a copied colour/shape.
class _Ticks extends StatelessWidget {
  final String status;
  final ColorScheme scheme;
  const _Ticks({required this.status, required this.scheme});

  @override
  Widget build(BuildContext context) {
    final read = status == 'read' || status == 'seen';
    final delivered = read || status == 'delivered';
    final icon = delivered ? Icons.done_all_rounded : Icons.done_rounded;
    final color = read ? scheme.primary : scheme.onSurfaceVariant;
    return Icon(icon, size: 15, color: color);
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool muted;
  const _UnreadBadge({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = muted ? scheme.outline : scheme.primary;
    final bn = Localizations.localeOf(context).languageCode == 'bn';
    final label = _bn(count > 99 ? '99+' : '$count', bn);
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
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
      if (cu >= 0x30 && cu <= 0x39) {
        b.writeCharCode(bnZero + (cu - 0x30));
      } else {
        b.writeCharCode(cu);
      }
    }
    return b.toString();
  }
}
