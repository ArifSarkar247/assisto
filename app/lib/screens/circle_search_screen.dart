import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import '../ds/ds.dart';
import 'package:intl/intl.dart';

import '../messaging/chat_decor/chat_control.dart' show isControlText;
import '../messaging/chat_decor/decor_store.dart';
import '../messaging/chat_lock.dart';
import '../p3/assisto_card.dart' show cardFallback;
import '../widgets/circle_people_filter.dart' show peopleTextMatches;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'circle_chat_screen.dart';
import 'circle_group_chat_screen.dart'; // gap-circle
import '../crypto/group_decrypt.dart'; // gap-circle

/// Search ACROSS all circle chats. Because the server stores ciphertext only,
/// search is done ON-DEVICE: we pull each accepted member's messages, decrypt
/// them locally (crypto/e2e.dart), and match the query over the decrypted text.
/// The server never sees the query term matched against content.
///
/// Matching mirrors core/logic/circle_messaging.match_message (token-AND over
/// case-folded text). Deleted messages are skipped.
class CircleSearchScreen extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  final IdentityKeyPair identity;

  /// e-gaps: the text typed in the chat-list search (opened from there).
  final String initialQuery;
  const CircleSearchScreen(
      {super.key, required this.members, required this.identity, this.initialQuery = ''});

  @override
  State<CircleSearchScreen> createState() => _CircleSearchScreenState();
}

class _CircleSearchHit {
  final Map<String, dynamic> member;
  final String text;
  final DateTime at;
  final Map<String, dynamic>? group; // gap-circle: a group message hit
  const _CircleSearchHit(this.member, this.text, this.at, {this.group});
}

class _CircleSearchScreenState extends State<CircleSearchScreen> {
  final _e2e = SoftwareE2E();
  final _index = <_CircleSearchHit>[];
  bool _loading = true;
  String _query = '';
  late final TextEditingController _box =
      TextEditingController(text: widget.initialQuery);

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery;
    _buildIndex();
  }

  @override
  void dispose() {
    _box.dispose();
    super.dispose();
  }

  ApiClient get _api => context.read<AppState>().api;
  AppLocalizations get _t => AppLocalizations.of(context);

  /// circlefam (2 GB phones): newest [kPerChat] messages per chat (the
  /// server's page cap), [kParallel] chats at a time, results shown as they
  /// arrive, the decrypted index kept in memory for [kCacheFor] so opening
  /// search again is instant. Nothing typed here is ever sent anywhere.
  static const int kPerChat = 200;
  static const int kParallel = 3;
  static const int kMaxShown = 200;
  static const Duration kCacheFor = Duration(minutes: 10);
  static final Map<String, (DateTime, List<_CircleSearchHit>)> _cache = {};

  int _done = 0;
  int _total = 0;

  /// Pull + decrypt each accepted member's chat once, into a local index.
  Future<void> _buildIndex() async {
    final api = _api;
    final me = context.read<AppState>().user?.id;
    await ChatLockStore.instance.warm();
    final todo = <Map<String, dynamic>>[];
    for (final member in widget.members) {
      final id = member['id'];
      // e-gaps: a locked chat is searched only while the lock is open
      if (ChatLockStore.instance.isLockedSync('member:$id') && !ChatLockSession.isOpen) {
        continue;
      }
      if (_peerPub(member) == null) continue;
      todo.add(member);
    }
    // gap-circle: group messages too (opened on this phone, like 1:1)
    final groups = <Map<String, dynamic>>[];
    try {
      final g = await api.getJson('/circle/groups');
      for (final row in ((g['results'] ?? g['groups'] ?? []) as List).whereType<Map>()) {
        final m = row.cast<String, dynamic>();
        if (ChatLockStore.instance.isLockedSync('group:${m['id']}') && !ChatLockSession.isOpen) {
          continue;
        }
        groups.add(m);
      }
    } catch (_) {}
    if (!mounted) return;
    final jobs = <Future<List<_CircleSearchHit>> Function()>[
      for (final member in todo) () => _indexOne(api, member, me),
      for (final g in groups) () => _indexGroup(api, g, me),
    ];
    _total = jobs.length;
    var next = 0;
    Future<void> worker() async {
      while (next < jobs.length) {
        final job = jobs[next++];
        final hits = await job();
        if (!mounted) return;
        setState(() {
          _index.addAll(hits);
          _done++;
        });
      }
    }

    await Future.wait([for (var i = 0; i < kParallel; i++) worker()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<List<_CircleSearchHit>> _indexOne(
      ApiClient api, Map<String, dynamic> member, int? me) async {
    final id = member['id'];
    final ck = '${identityHashCode(api)}|$me|$id|${widget.identity.keyId}';
    final hit = _cache[ck];
    if (hit != null && DateTime.now().difference(hit.$1) < kCacheFor) return hit.$2;
    final peer = _peerPub(member)!;
    final out = <_CircleSearchHit>[];
    try {
      final r = await api.getJson('/circle/$id/messages?limit=$kPerChat');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List).cast<Map<String, dynamic>>();
      for (final env in raw) {
        if ('${env['deleted'] ?? ''}' == 'everyone') continue;
        if ('${env['content_type'] ?? 'text'}' != 'text') continue;
        final text = _decrypt(env, peer, me);
        // e-gaps: theme / timer / nickname lines are not messages
        if (text == null || text.isEmpty || isControlText(text)) continue;
        final at = DateTime.tryParse('${env['created_at'] ?? ''}')?.toLocal() ?? DateTime.now();
        out.add(_CircleSearchHit(member, text, at));
      }
      _cache[ck] = (DateTime.now(), out);
    } catch (_) {}
    return out;
  }

  /// gap-circle: newest [kPerChat] messages of one group, opened with my key
  /// (my entry of the per-member fan-out; my own messages via any member).
  Future<List<_CircleSearchHit>> _indexGroup(
      ApiClient api, Map<String, dynamic> group, int? me) async {
    final gid = group['id'];
    final ck = 'g|${identityHashCode(api)}|$me|$gid|${widget.identity.keyId}';
    final hit = _cache[ck];
    if (hit != null && DateTime.now().difference(hit.$1) < kCacheFor) return hit.$2;
    final out = <_CircleSearchHit>[];
    try {
      final ros = await api.getJson('/circle/groups/$gid/members');
      final roster = ((ros['results'] ?? ros['members'] ?? []) as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      var myMid = '${group['my_member_id'] ?? ''}';
      if (myMid.isEmpty || myMid == 'null') {
        for (final r in roster) {
          if (r['is_self'] == true) myMid = '${r['member_id'] ?? r['id'] ?? ''}';
        }
      }
      final r = await api.getJson('/circle/groups/$gid/messages?limit=$kPerChat');
      final raw = ((r['results'] ?? r['messages'] ?? []) as List).whereType<Map>();
      for (final e in raw) {
        final env = e.cast<String, dynamic>();
        if ('${env['deleted'] ?? ''}' == 'everyone' || env['view_once'] == true) continue;
        if ('${env['content_type'] ?? 'text'}' != 'text') continue;
        final text = GroupDecrypt.open(env,
            ring: [widget.identity],
            myMemberId: myMid,
            myUserId: me == null ? '' : '$me',
            roster: roster);
        if (text == null || text.isEmpty || isControlText(text)) continue;
        final at = DateTime.tryParse('${env['created_at'] ?? ''}')?.toLocal() ?? DateTime.now();
        out.add(_CircleSearchHit(const {}, text, at, group: group));
      }
      _cache[ck] = (DateTime.now(), out);
    } catch (_) {}
    return out;
  }

  Uint8List? _peerPub(Map<String, dynamic> member) {
    final b64 = member['public_key'] as String?;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  String? _decrypt(Map<String, dynamic> env, Uint8List peer, int? me) {
    try {
      final ct = Ciphertext(
        scheme: '${env['scheme'] ?? _e2e.scheme}',
        ciphertextB64: '${env['ciphertext'] ?? ''}',
        nonceB64: '${env['nonce'] ?? ''}',
        senderKeyId: '${env['sender_key_id'] ?? ''}',
      );
      return _e2e.decrypt(self: widget.identity, senderPublicKey: peer, ct: ct);
    } catch (_) {
      return null;
    }
  }

  List<_CircleSearchHit> get _results {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final terms = q.split(RegExp(r'\s+'));
    // circlefam: Bangla and English digits match each other
    final hits = _index
        .where((h) => terms.every((tk) => peopleTextMatches(h.text, tk)))
        .toList();
    hits.sort((a, b) => b.at.compareTo(a.at));
    return hits.length > kMaxShown ? hits.sublist(0, kMaxShown) : hits;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final results = _results;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('e-msg-search-box'),
          controller: _box,
          autofocus: widget.initialQuery.isEmpty,
          decoration: InputDecoration(hintText: _t.circleSearchAll, border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
        ),
      ),
      // circlefam: results appear while the other chats are still loading
      // (a thin progress line on top), never a long blank spinner.
      body: Column(children: [
        if (_loading)
          LinearProgressIndicator(
              key: const Key('cf-search-progress'),
              value: _total == 0 ? null : _done / _total),
        Expanded(child: _query.trim().isEmpty
              ? _hint(scheme)
              : results.isEmpty
                  ? (_loading
                      ? const Center(child: CircularProgressIndicator())
                      : Center(child: Text(_t.circleSearchNoResults, style: TextStyle(color: DsTokens.of(context).muted))))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final h = results[i];
                        // cde-chat nickname first, like the chat list
                        final g = h.group; // gap-circle
                        final name = g != null
                            ? '${g['name'] ?? ''}'
                            : DecorStore.instance.peerName(
                                'member:${h.member['id']}', '${h.member['name'] ?? ''}');
                        return ListTile(
                          key: Key('e-msg-hit-$i'),
                          leading: g != null
                              ? CircleAvatar(child: Icon(Icons.groups_rounded,
                                  semanticLabel: name))
                              : DsAvatar(name: name.isEmpty ? '?' : name),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(cardFallback(h.text),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(
                              notifLocalizeDigits(context,
                                  DateFormat('d/M/yy').format(h.at)),
                              style: TextStyle(fontSize: 12, color: DsTokens.of(context).muted)),
                          onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => g != null
                                ? CircleGroupChatScreen(group: g, identity: widget.identity)
                                : CircleChatScreen(member: h.member, identity: widget.identity),
                          )),
                        );
                      },
                    )),
      ]),
    );
  }

  Widget _hint(ColorScheme scheme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const DsIllustration(icon: Icons.search_rounded),
              const SizedBox(height: Gap.md),
              Text(_t.circleSearchHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: DsTokens.of(context).muted, height: 1.4)),
            ],
          ),
        ),
      );
}
