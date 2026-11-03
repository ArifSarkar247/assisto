import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../crypto/e2e.dart';
import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'package:intl/intl.dart';

import '../messaging/chat_decor/chat_control.dart' show isControlText;
import '../messaging/chat_decor/decor_store.dart';
import '../messaging/chat_lock.dart';
import '../p3/assisto_card.dart' show cardFallback;
import '../widgets/circle_people_filter.dart' show peopleTextMatches;
import '../widgets/notif_models.dart' show notifLocalizeDigits;
import 'circle_chat_screen.dart';

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
  const _CircleSearchHit(this.member, this.text, this.at);
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
    _total = todo.length;
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final member = todo[next++];
        final hits = await _indexOne(api, member, me);
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
                      : Center(child: Text(_t.circleSearchNoResults, style: TextStyle(color: scheme.onSurfaceVariant))))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final h = results[i];
                        // cde-chat nickname first, like the chat list
                        final name = DecorStore.instance.peerName(
                            'member:${h.member['id']}', '${h.member['name'] ?? ''}');
                        return ListTile(
                          key: Key('e-msg-hit-$i'),
                          leading: CircleAvatar(
                              child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase())),
                          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(cardFallback(h.text),
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                          trailing: Text(
                              notifLocalizeDigits(context,
                                  DateFormat('d/M/yy').format(h.at)),
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                          onTap: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                            builder: (_) => CircleChatScreen(member: h.member, identity: widget.identity),
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
              Icon(Icons.search_rounded, size: 48, color: scheme.primary.withValues(alpha: 0.6)),
              const SizedBox(height: Gap.md),
              Text(_t.circleSearchHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
            ],
          ),
        ),
      );
}
